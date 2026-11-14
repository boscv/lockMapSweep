# lockMapSweep plugin
# by @boscv. aka @billabong93

package lockMapSweep;

use strict;
use warnings;
use Plugins;
use Commands;
use Globals qw(%config $field $char);
use Log qw(message warning error debug);
use AI qw(ai_route);
use Field;
use Utils qw(actorFinishedMovement);
use Utils::PathFinding;
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use Storable qw(dclone);

Plugins::register('lockMapSweep', 'Smart lockMap block sweep randomWalk override', \&on_unload, \&on_unload);

my $hooks = Plugins::addHooks(
	['postloadfiles', \&on_postloadfiles],
	['post_configModify', \&on_config_modify],
	['post_bulkConfigModify', \&on_config_modify],
	['ai_processRandomWalk', \&on_ai_process_random_walk],
	['AI/lockMap', \&on_ai_lock_map],
	['route', \&on_route],
	['Network::Receive::map_changed', \&on_map_changed],
);

my $cmd_hooks = Commands::register(
	['lockMapSweep', 'Manage lockMapSweep state (status|rebuild|clearstate)', \&on_command_lock_map_sweep],
);

my %state = (
	ready => 0,
	last_lock_map => '',
	width => 0,
	height => 0,
	blocks_x => 0,
	blocks_y => 0,
	block_count => 0,
	cells_per_block => 0,
	current_block => 0,
	visits_in_block => 0,
	bounds => [],
	last_target => undef,
	state_file => undef,
	reachable_lookup => {},
	used_targets_by_block => {},
	visited_blocks_in_cycle => {},
	walk_min_x => 0,
	walk_max_x => 0,
	walk_min_y => 0,
	walk_max_y => 0,
	last_block => undef,
	block_index_lookup => {},
	destination_lookup => {},
	geometry_signature => '',
		restriction_signature => '',
	pending_target => undef,
	failed_targets_by_block => {},
	failed_config_signature => undef,
);

sub on_unload {
	Plugins::delHooks($hooks);
	Commands::unregister($cmd_hooks);
	message "[lockMapSweep] Plugin unloading/reloading.\n", 'success';
}

sub on_postloadfiles {
	initialize_or_reload();
}

sub on_config_modify {
	my (undef, $args) = @_;
	return unless $args;

	my %watched = map { $_ => 1 } qw(
		lockMap
		lockMapSweep_enabled
		lockMapSweep_blocksX
		lockMapSweep_blocksY
		lockMapSweep_cellsPerBlock
		lockMapSweep_useStateFile
		lockMapSweep_stateDir
		lockMap_x
		lockMap_y
		lockMap_randX
		lockMap_randY
	);

	if (ref($args->{keys}) eq 'HASH') {
		return unless grep { $watched{$_} } keys %{$args->{keys}};
	} else {
		return unless $watched{$args->{key}};
		return if $args->{bulk};
	}

	# A live plan change can make the current random-walk destination invalid.
	# Stop only the route owned by this plugin before rebuilding its constraints;
	# otherwise the old OpenKore route can keep executing under the new config.
	my $pending = $state{pending_target};
	my $route_index = AI::findAction('route');
	$route_index = AI::findAction('mapRoute') unless defined $route_index;
	my $route_invalidated = 0;
	if ($pending && defined $route_index) {
		my $route_args = AI::args($route_index);
		my $dest = $route_args->{dest} && $route_args->{dest}{pos}
			? $route_args->{dest}{pos} : undef;
		if ($route_args->{isRandomWalk} && $dest
			&& $dest->{x} == $pending->{x} && $dest->{y} == $pending->{y}) {
			AI::clear(qw(move route mapRoute));
			$state{pending_target} = undef;
			persist_state() if $state{ready};
			message sprintf(
				"[lockMapSweep] Invalidated pending route to %d, %d after config change to %s.\n",
				$pending->{x}, $pending->{y}, $args->{key}
			), 'route';
			$route_invalidated = 1;
		}
	}

	my $rebuilt = initialize_or_reload();
	$state{failed_config_signature} = undef if $rebuilt;
	if (!$rebuilt && $state{ready} && !is_state_compatible()) {
		# initialize_or_reload preserves a previous valid plan on load errors. A
		# previous plan is not valid when the live navigation config has changed.
		# Fail closed so neither the plugin nor default randomWalk uses stale data.
		$state{ready} = 0;
		$state{pending_target} = undef;
		$state{failed_config_signature} = live_config_signature();
		warning "[lockMapSweep] New config has no valid plan; navigation paused until it is corrected.\n", 'system';
	}
	$state{failed_config_signature} = live_config_signature() unless $rebuilt;
	if ($route_invalidated && $rebuilt) {
		# Queue the replacement immediately. Waiting for the next CoreLogic idle
		# randomWalk tick leaves the server's already accepted movement running
		# toward the destination that the config change just invalidated.
		my %random_walk_args = (return => 0);
		on_ai_process_random_walk(undef, \%random_walk_args);
	}
}

sub on_ai_process_random_walk {
	my (undef, $args) = @_;
	return unless $args;
	return unless is_enabled();
	return unless $char;
	return unless $field;
	return unless $config{lockMap};
	return unless $field->baseName eq $config{lockMap};
	if (!$state{ready} && defined $state{failed_config_signature}
		&& $state{failed_config_signature} eq live_config_signature()) {
		$args->{return} = 1;
		return;
	}

	if (!is_state_compatible()) {
		unless (initialize_or_reload()) {
			$state{failed_config_signature} = live_config_signature();
			$args->{return} = 1;
			return;
		}
	}
	my $origin = $char->{pos};
	if ($origin && defined $origin->{x} && defined $origin->{y}
		&& !is_cell_reachable($origin->{x}, $origin->{y})) {
		initialize_or_reload(undef, $origin);
	}

	if (!$state{ready}) {
		warning "[lockMapSweep] State is not ready, falling back to default randomWalk.\n", 'system';
		return;
	}

	if ($state{pending_target}) {
		if (character_at_pending_target()) {
			complete_pending_target();
		} elsif (character_moving_to_pending_target()) {
			$args->{return} = 1;
			return;
		} else {
			reject_pending_target('route ended without reaching its destination');
		}
	}

	my $target = pick_target_in_current_plan();
	if (!$target) {
		warning "[lockMapSweep] Unable to find a valid target in planned blocks, falling back to default randomWalk.\n", 'system';
		return;
	}

	my $attack_auto = Misc::getAttackAutoMode();
	my $attack_on_route = (!defined $attack_auto || $attack_auto < 0) ? 0 : ($attack_auto >= 2 ? 2 : 1);
	$state{pending_target} = {
		block_idx => $target->{block_idx},
		x => $target->{x},
		y => $target->{y},
		from_x => $target->{from_x},
		from_y => $target->{from_y},
	};
	message sprintf("[lockMapSweep] Calculating sweep route to block %d: %d, %d\n", $target->{block_idx} + 1, $target->{x}, $target->{y}), 'route';
	my $queued = eval {
		ai_route(
			$field->baseName,
			$target->{x},
			$target->{y},
			maxRouteTime => $config{route_randomWalk_maxRouteTime},
			attackOnRoute => $attack_on_route,
			noMapRoute => ($config{route_randomWalk} == 2 ? 1 : 0),
			isRandomWalk => 1
		);
		1;
	};
	if (!$queued) {
		my $error_text = $@ || 'unknown route creation error';
		reject_pending_target("could not queue route: $error_text");
		return;
	}
	persist_state();
	$args->{return} = 1;
}

sub on_ai_lock_map {
	my (undef, $args) = @_;
	return unless $args && is_enabled() && $field && $config{lockMap};
	return unless $field->baseName eq $config{lockMap};

	# CoreLogic's fallback clears lockMap when its own coordinate check finds no
	# eligible tile. While this plugin owns randomWalk, that would discard the
	# user's map context and prevent a later live constraint correction from
	# rebuilding the plan. The randomWalk hook already fails closed when unready.
	$args->{return} = 1;
}

sub on_route {
	my (undef, $args) = @_;
	return unless $state{pending_target};
	return unless AI::is('route');

	my $task = AI::args();
	return unless $task && $task->{isRandomWalk};
	my $pending = $state{pending_target};
	my $dest = $task->{dest} && $task->{dest}{pos} ? $task->{dest}{pos} : undef;
	if (!$dest || $dest->{x} != $pending->{x} || $dest->{y} != $pending->{y}) {
		reject_pending_target('randomWalk route destination changed before completion');
		return;
	}

	my $status = $args && $args->{status} ? $args->{status} : '';
	if ($status eq 'success') {
		if (character_at_pending_target()) {
			complete_pending_target();
		} elsif (character_moving_to_pending_target()) {
			# Route completion can precede the end of the server-reported movement.
			# Keep the target pending until actorFinishedMovement confirms arrival.
		} else {
			reject_pending_target('OpenKore reported route success before the server-confirmed position matched');
		}
	} elsif ($status eq 'stuck') {
		reject_pending_target('OpenKore reported a stuck route');
	}
}

sub on_map_changed {
	if ($state{pending_target} && (!$field || $field->baseName ne $state{last_lock_map})) {
		reject_pending_target('map changed before route completion');
	}
	$state{last_target} = undef;
	$state{last_block} = undef;
	if ($field && $config{lockMap} && $field->baseName eq $config{lockMap}) {
		initialize_or_reload(undef, $char && $char->{pos} ? $char->{pos} : undef);
	} else {
		persist_state() if $state{ready};
	}
}

sub character_at_pending_target {
	my $pending = $state{pending_target};
	return 0 unless $pending && $char && $field;
	return 0 unless $field->baseName eq $state{last_lock_map};
	my $pos = $char->{pos_to} || $char->{pos};
	return 0 unless $pos && defined $pos->{x} && defined $pos->{y};
	return 0 unless $pos->{x} == $pending->{x} && $pos->{y} == $pending->{y};
	return actorFinishedMovement($char, $field, 0, 1) ? 1 : 0;
}

sub character_moving_to_pending_target {
	my $pending = $state{pending_target};
	return 0 unless $pending && $char && $field;
	return 0 unless $field->baseName eq $state{last_lock_map};
	my $pos = $char->{pos_to};
	return $pos && defined $pos->{x} && defined $pos->{y}
		&& $pos->{x} == $pending->{x} && $pos->{y} == $pending->{y};
}

sub complete_pending_target {
	my $pending = delete $state{pending_target} or return 0;
	my $block_idx = $pending->{block_idx};
	my $block = $state{bounds}->[$block_idx];
	unless ($block && $block_idx == $state{current_block}) {
		warning "[lockMapSweep] Ignoring arrival for a stale block plan.\n", 'system';
		return 0;
	}

	my $key = block_key($block);
	$state{used_targets_by_block}{$key} ||= {};
	$state{used_targets_by_block}{$key}{"$pending->{x},$pending->{y}"} = 1;
	$state{last_target} = { x => $pending->{x}, y => $pending->{y} };
	$state{last_block} = $block_idx;
	advance_plan();
	persist_state();
	return 1;
}

sub reject_pending_target {
	my ($reason) = @_;
	my $pending = delete $state{pending_target} or return 0;
	my $block = $state{bounds}->[$pending->{block_idx}];
	my $key = $block ? block_key($block) : $pending->{block_idx};
	$state{failed_targets_by_block}{$key} ||= {};
	$state{failed_targets_by_block}{$key}{"$pending->{x},$pending->{y}"} = 1;
	persist_state() if $state{ready};
	warning sprintf("[lockMapSweep] Route to %d, %d did not complete (%s); progress was not advanced.\n",
		$pending->{x}, $pending->{y}, $reason || 'unknown route failure'), 'route';
	return 1;
}

sub is_enabled {
	return ($config{lockMapSweep_enabled} && $config{lockMapSweep_enabled} =~ /^1$/) ? 1 : 0;
}

sub live_config_signature {
	return join "\x1f", map { defined $config{$_} ? $config{$_} : '' }
		qw(lockMap lockMap_x lockMap_y lockMap_randX lockMap_randY
			lockMapSweep_enabled lockMapSweep_blocksX lockMapSweep_blocksY
			lockMapSweep_cellsPerBlock lockMapSweep_useStateFile lockMapSweep_stateDir);
}

sub initialize_or_reload {
	my ($force_rebuild, $origin_override) = @_;
	my $previous = dclone(\%state);
	%state = (
		ready => 0,
		last_lock_map => '',
		width => 0,
		height => 0,
		blocks_x => 0,
		blocks_y => 0,
		block_count => 0,
		cells_per_block => 0,
		current_block => 0,
		visits_in_block => 0,
		bounds => [],
		last_target => undef,
		state_file => undef,
		reachable_lookup => {},
		used_targets_by_block => {},
		visited_blocks_in_cycle => {},
		walk_min_x => 0,
		walk_max_x => 0,
		walk_min_y => 0,
		walk_max_y => 0,
		last_block => undef,
		block_index_lookup => {},
		destination_lookup => {},
		geometry_signature => '',
		restriction_signature => '',
		pending_target => undef,
		failed_targets_by_block => {},
		failed_config_signature => undef,
	);
	my $restore_previous = sub {
		%state = %$previous if $previous->{ready};
		return 0;
	};

	unless (is_enabled()) {
		debug "[lockMapSweep] Disabled by config.\n", 'plugin';
		return;
	}

	my $lock_map = $config{lockMap};
	if (!$lock_map) {
		warning "[lockMapSweep] lockMap is empty; plugin will stay idle.\n", 'system';
		return;
	}

	my $blocks_x = positive_int_or_default($config{lockMapSweep_blocksX}, 2);
	my $blocks_y = positive_int_or_default($config{lockMapSweep_blocksY}, 2);
	my $cells_per_block = positive_int_or_default($config{lockMapSweep_cellsPerBlock}, 3);

	$state{last_lock_map} = $lock_map;
	$state{blocks_x} = $blocks_x;
	$state{blocks_y} = $blocks_y;
	$state{block_count} = $blocks_x * $blocks_y;
	$state{cells_per_block} = $cells_per_block;
	$state{state_file} = build_state_file_path($lock_map, $blocks_x, $blocks_y);

	my $lock_field = load_lock_field($lock_map);
	unless ($lock_field) {
		error "[lockMapSweep] Could not load lockMap field data (.fld2).\n";
		return $restore_previous->();
	}

	$state{width} = $lock_field->width;
	$state{height} = $lock_field->height;
	if ($blocks_x > $state{width} || $blocks_y > $state{height} || $blocks_x * $blocks_y > 4096) {
		error "[lockMapSweep] Block dimensions exceed supported map limits.\n";
		return $restore_previous->();
	}
	my $origin = $origin_override;
	if (!$origin && $char && $field && $field->baseName eq $lock_map) {
		my $position = $char->{pos};
		$origin = { x => $position->{x}, y => $position->{y} }
			if $position && defined $position->{x} && defined $position->{y};
	}
	$state{reachable_lookup} = build_reachable_lookup($lock_field, $origin);
	if (!%{$state{reachable_lookup}}) {
		error "[lockMapSweep] No reachable walkable cells found on lockMap.\n";
		return $restore_previous->();
	}
	$state{restriction_signature} = lock_restriction_signature();
	$state{destination_lookup} = build_destination_lookup($lock_field);
	if (!%{$state{destination_lookup}}) {
		error "[lockMapSweep] No reachable cells satisfy lockMap coordinate restrictions.\n";
		return $restore_previous->();
	}
	$state{geometry_signature} = map_geometry_signature($lock_field);

	set_walkable_bounds_from_lookup();

	my $loaded_state = !$force_rebuild && load_state_from_file();
	if ($loaded_state) {
		$state{ready} = 1;
		build_block_index_lookup();
		align_current_block_to_origin($origin);
		persist_state();
		message "[lockMapSweep] Loaded block plan from state file.\n", 'success';
		return 1;
	}

	unless (build_block_plan($lock_field)) {
		error "[lockMapSweep] Failed to build lockMap block plan.\n";
		return $restore_previous->();
	}

	$state{ready} = 1;
	$state{used_targets_by_block} = {};
	$state{visited_blocks_in_cycle} = {};
	build_block_index_lookup();
	align_current_block_to_origin($origin);
	persist_state();
	message sprintf("[lockMapSweep] Built lockMap plan for %s (%dx%d blocks, %d cells per block).\n", $lock_map, $blocks_x, $blocks_y, $cells_per_block), 'success';
	return 1;
}

sub is_state_compatible {
	return 0 unless $state{ready};
	return 0 unless $state{last_lock_map} && $config{lockMap} && $state{last_lock_map} eq $config{lockMap};
	return 0 unless $state{blocks_x} == positive_int_or_default($config{lockMapSweep_blocksX}, 2);
	return 0 unless $state{blocks_y} == positive_int_or_default($config{lockMapSweep_blocksY}, 2);
	return 0 unless $state{cells_per_block} == positive_int_or_default($config{lockMapSweep_cellsPerBlock}, 3);
	return 0 unless $state{restriction_signature} eq lock_restriction_signature();
	return 1;
}

sub load_lock_field {
	my ($map) = @_;
	my $lock_field;
	eval {
		$lock_field = new Field(name => $map, loadWeightMap => 0);
	};
	return undef if ($@ || !$lock_field);
	return $lock_field;
}

sub build_block_plan {
	my ($lock_field) = @_;
	return 0 unless $lock_field;

	$state{bounds} = [];

	my $walk_width = ($state{walk_max_x} - $state{walk_min_x} + 1);
	my $walk_height = ($state{walk_max_y} - $state{walk_min_y} + 1);
	return 0 if $walk_width <= 0 || $walk_height <= 0;

	for my $by (0 .. $state{blocks_y} - 1) {
		for my $bx (0 .. $state{blocks_x} - 1) {
			my $min_x = $state{walk_min_x} + int(($bx * $walk_width) / $state{blocks_x});
			my $max_x = $state{walk_min_x} + int((($bx + 1) * $walk_width) / $state{blocks_x}) - 1;
			my $min_y = $state{walk_min_y} + int(($by * $walk_height) / $state{blocks_y});
			my $max_y = $state{walk_min_y} + int((($by + 1) * $walk_height) / $state{blocks_y}) - 1;

			$max_x = $state{walk_max_x} if $bx == $state{blocks_x} - 1;
			$max_y = $state{walk_max_y} if $by == $state{blocks_y} - 1;

			my @target_cells;
			for my $y ($min_y .. $max_y) {
				for my $x ($min_x .. $max_x) {
					next unless is_cell_eligible($x, $y);
					push @target_cells, { x => $x, y => $y };
				}
			}

			push @{ $state{bounds} }, {
				min_x => $min_x,
				max_x => $max_x,
				min_y => $min_y,
				max_y => $max_y,
				walkable_count => scalar @target_cells,
				target_cells => \@target_cells,
			};
		}
	}

	$state{current_block} = first_non_empty_block();
	$state{visits_in_block} = 0;
	$state{used_targets_by_block} = {};
	$state{visited_blocks_in_cycle} = {};
	$state{last_block} = undef;
	build_block_index_lookup();
	return 1;
}

sub set_walkable_bounds_from_lookup {
	# Partition the whole reachable component, not only legal destination cells.
	# lockMap coordinate restrictions constrain targets; the character may need
	# to cross unrestricted walkable cells to reach those targets.
	my @keys = keys %{$state{reachable_lookup}};
	return 0 unless @keys;

	my ($min_x, $min_y) = (1_000_000, 1_000_000);
	my ($max_x, $max_y) = (-1, -1);
	for my $k (@keys) {
		my ($x, $y) = split(/,/, $k, 2);
		next unless defined $x && defined $y;
		$min_x = $x if $x < $min_x;
		$max_x = $x if $x > $max_x;
		$min_y = $y if $y < $min_y;
		$max_y = $y if $y > $max_y;
	}

	$state{walk_min_x} = $min_x;
	$state{walk_max_x} = $max_x;
	$state{walk_min_y} = $min_y;
	$state{walk_max_y} = $max_y;
	return 1;
}

sub first_non_empty_block {
	for my $idx (0 .. $state{block_count} - 1) {
		my $b = $state{bounds}->[$idx];
		return $idx if $b && $b->{walkable_count} > 0;
	}
	return 0;
}

sub build_block_index_lookup {
	$state{block_index_lookup} = {};
	for my $idx (0 .. $#{$state{bounds}}) {
		my $b = $state{bounds}->[$idx];
		next unless $b;
		for my $y ($b->{min_y} .. $b->{max_y}) {
			for my $x ($b->{min_x} .. $b->{max_x}) {
				next unless is_cell_reachable($x, $y);
				$state{block_index_lookup}{"$x,$y"} = $idx;
			}
		}
	}
}

sub align_current_block_to_origin {
	my ($origin) = @_;
	return unless $origin && !$state{pending_target};
	my $block_idx = coord_to_block_index($origin->{x}, $origin->{y});
	return unless defined $block_idx && $state{bounds}->[$block_idx]
		&& $state{bounds}->[$block_idx]{walkable_count} > 0;
	return if $block_idx == $state{current_block};
	$state{current_block} = $block_idx;
	$state{visits_in_block} = 0;
	$state{last_block} = undef;
	$state{last_target} = undef;
}

sub build_reachable_lookup {
	my ($lock_field, $origin) = @_;
	my %visited;
	my %best_component;
	my $best_size = 0;

	for my $y (1 .. $lock_field->height - 1) {
		for my $x (1 .. $lock_field->width - 1) {
			my $k = "$x,$y";
			next if $visited{$k};
			next unless $lock_field->isWalkable($x, $y);

			my @queue = ({ x => $x, y => $y });
			my $head = 0;
			my %component;
			$visited{$k} = 1;
			$component{$k} = 1;

			while ($head < @queue) {
				my $p = $queue[$head++];
				for my $d (
					[-1,  0], [1,  0], [0, -1], [0, 1],
					[-1, -1], [1, -1], [-1, 1], [1, 1],
				) {
					my $nx = $p->{x} + $d->[0];
					my $ny = $p->{y} + $d->[1];
					next if $nx <= 0 || $ny <= 0;
					next if $nx >= $lock_field->width || $ny >= $lock_field->height;
					my $nk = "$nx,$ny";
					next if $visited{$nk};
					next unless $lock_field->isWalkable($nx, $ny);
					next unless $lock_field->canMove($p, { x => $nx, y => $ny });
					$visited{$nk} = 1;
					$component{$nk} = 1;
					push @queue, { x => $nx, y => $ny };
				}
			}

			my $size = scalar keys %component;
			return \%component if $origin && $component{"$origin->{x},$origin->{y}"};
			if ($size > $best_size) {
				$best_size = $size;
				%best_component = %component;
			}
		}
	}

	return \%best_component;
}

sub build_destination_lookup {
	my ($lock_field) = @_;
	my %excluded;
	my %hook_args = (cells => \%excluded, field => $lock_field, caller => 'get_lockMap_cell');
	Plugins::callHook('add_dropDestinationCells', \%hook_args);
	my $field_width = $state{width};
	my $field_height = $state{height};
	my $lock_x = defined($config{lockMap_x}) && $config{lockMap_x} ne '' ? $config{lockMap_x} : undef;
	my $lock_y = defined($config{lockMap_y}) && $config{lockMap_y} ne '' ? $config{lockMap_y} : undef;
	my $rand_x = positive_int_or_default($config{lockMap_randX}, 0);
	my $rand_y = positive_int_or_default($config{lockMap_randY}, 0);
	return {} if defined($lock_x) && $lock_x !~ /^-?\d+$/;
	return {} if defined($lock_y) && $lock_y !~ /^-?\d+$/;
	my %eligible;
	for my $key (keys %{$state{reachable_lookup}}) {
		my ($x, $y) = split(/,/, $key, 2);
		next if $x <= 0 || $y <= 0 || $x >= $field_width || $y >= $field_height;
		next if defined($lock_x) && ($rand_x ? ($x < $lock_x - $rand_x || $x >= $lock_x + $rand_x) : $x != $lock_x);
		next if defined($lock_y) && ($rand_y ? ($y < $lock_y - $rand_y || $y >= $lock_y + $rand_y) : $y != $lock_y);
		next if $excluded{$x} && $excluded{$x}{$y};
		$eligible{$key} = 1;
	}
	return \%eligible;
}

sub map_geometry_signature {
	my ($lock_field) = @_;
	my $sha = Digest::SHA->new(256);
	$sha->add($lock_field->width . 'x' . $lock_field->height . ':');
	$sha->add($lock_field->{rawMap} || '');
	$sha->add(':' . lock_restriction_signature() . ':');
	$sha->add(join(';', sort keys %{$state{destination_lookup}}));
	return $sha->hexdigest;
}

sub lock_restriction_signature {
	return join(':', map { defined $config{$_} ? $config{$_} : '' }
		qw(lockMap lockMap_x lockMap_y lockMap_randX lockMap_randY));
}

sub block_key {
	my ($block) = @_;
	return sprintf('%d:%d:%d:%d', @{$block}{qw(min_x max_x min_y max_y)});
}

sub is_cell_reachable {
	my ($x, $y) = @_;
	return 0 unless defined $x && defined $y;
	return exists $state{reachable_lookup}{"$x,$y"} ? 1 : 0;
}

sub is_cell_eligible {
	my ($x, $y) = @_;
	return 0 unless defined $x && defined $y;
	return exists $state{destination_lookup}{"$x,$y"} ? 1 : 0;
}

sub pick_target_in_current_plan {
	return undef unless $state{block_count} && $char && $field;
	my $from = $char->{pos};
	return undef unless $from && defined $from->{x} && defined $from->{y};
	my %origin = (x => $from->{x}, y => $from->{y});
	my $from_block = coord_to_block_index($origin{x}, $origin{y});
	return undef unless defined $from_block;

	for (1 .. $state{block_count}) {
		my $block_idx = $state{current_block};
		my $block = $state{bounds}->[$block_idx];
		if ($block && $block->{walkable_count} > 0) {
			my $target = pick_random_walkable_in_block($block_idx, $block, \%origin, $from_block);
			return $target if $target;
		}
		complete_empty_block($block_idx);
		persist_state();
	}
	return undef;
}

sub pick_random_walkable_in_block {
	my ($block_idx, $block, $from, $from_block_idx) = @_;
	return undef unless $block && $from;
	my $block_key = block_key($block);
	$state{used_targets_by_block}{$block_key} ||= {};
	$state{failed_targets_by_block}{$block_key} ||= {};
	my $used = $state{used_targets_by_block}{$block_key};
	my $failed = $state{failed_targets_by_block}{$block_key};
	my @candidates = grep {
		my $key = "$_->{x},$_->{y}";
		!$used->{$key} && !$failed->{$key}
			&& !($_->{x} == $from->{x} && $_->{y} == $from->{y})
	} @{$block->{target_cells} || []};
	return undef unless @candidates;

	my $must_stay_in_block = $block_idx == $from_block_idx ? 1 : 0;
	if ($must_stay_in_block) {
		@candidates = reachable_targets_within_block($from, $block, \@candidates);
	} else {
		return undef unless defined $from_block_idx;
		@candidates = pick_transition_targets_in_block($from, $from_block_idx, $block_idx, $block, \@candidates);
	}
	return undef unless @candidates;

	my $target = $candidates[int(rand(@candidates))];
	return {
		block_idx => $block_idx,
		x => $target->{x},
		y => $target->{y},
		from_x => $from->{x},
		from_y => $from->{y},
	};
}

sub pick_transition_targets_in_block {
	my ($from, $from_block_idx, $to_block_idx, $to_block, $candidates) = @_;
	return () unless $from && $to_block && $candidates && @$candidates;
	my %allowed = ($from_block_idx => 1, $to_block_idx => 1);
	my %candidate = map { ("$_->{x},$_->{y}" => $_) } @$candidates;
	my @queue = ({ x => $from->{x}, y => $from->{y} });
	my $head = 0;
	my %visited = ("$from->{x},$from->{y}" => 1);
	my @reachable_targets;

	while ($head < @queue) {
		my $p = $queue[$head++];
		my $key = "$p->{x},$p->{y}";
		push @reachable_targets, $candidate{$key} if $candidate{$key};
		for my $d ([-1,0], [1,0], [0,-1], [0,1], [-1,-1], [1,-1], [-1,1], [1,1]) {
			my $nx = $p->{x} + $d->[0];
			my $ny = $p->{y} + $d->[1];
			next if $nx <= 0 || $ny <= 0 || $nx >= $state{width} || $ny >= $state{height};
			next unless is_cell_reachable($nx, $ny) && $field->isWalkable($nx, $ny);
			my $nidx = coord_to_block_index($nx, $ny);
			next unless defined $nidx && $allowed{$nidx};
			next unless $field->canMove($p, { x => $nx, y => $ny });
			my $next_key = "$nx,$ny";
			next if $visited{$next_key}++;
			push @queue, { x => $nx, y => $ny };
		}
	}
	return @reachable_targets;
}

sub reachable_targets_within_block {
	my ($from, $block, $candidates) = @_;
	return () unless $from && $block && $candidates && @$candidates;
	my %candidate = map { ("$_->{x},$_->{y}" => $_) } @$candidates;
	my @queue = ({ x => $from->{x}, y => $from->{y} });
	my $head = 0;
	my %visited = ("$from->{x},$from->{y}" => 1);
	my @reachable_targets;
	while ($head < @queue) {
		my $p = $queue[$head++];
		my $key = "$p->{x},$p->{y}";
		push @reachable_targets, $candidate{$key} if $candidate{$key};
		for my $d ([-1,0], [1,0], [0,-1], [0,1], [-1,-1], [1,-1], [-1,1], [1,1]) {
			my $nx = $p->{x} + $d->[0];
			my $ny = $p->{y} + $d->[1];
			next unless within_block({ x => $nx, y => $ny }, $block);
			next unless is_cell_reachable($nx, $ny) && $field->isWalkable($nx, $ny);
			next unless $field->canMove($p, { x => $nx, y => $ny });
			my $next_key = "$nx,$ny";
			next if $visited{$next_key}++;
			push @queue, { x => $nx, y => $ny };
		}
	}
	return @reachable_targets;
}

sub complete_empty_block {
	my ($block_idx) = @_;
	my $block = $state{bounds}->[$block_idx];
	if ($block) {
		$state{visited_blocks_in_cycle}{$block_idx} = 1;
		delete $state{used_targets_by_block}{block_key($block)};
		delete $state{failed_targets_by_block}{block_key($block)};
	}
	$state{last_block} = $block_idx;
	$state{visits_in_block} = 0;
	$state{current_block} = pick_next_block($block_idx);
}

sub path_exists_with_allowed_blocks {
	my ($from, $to, $allowed_blocks) = @_;
	return 0 unless $from && $to && $allowed_blocks;
	my $from_idx = coord_to_block_index($from->{x}, $from->{y});
	my $to_idx = coord_to_block_index($to->{x}, $to->{y});
	return 0 unless defined $from_idx && defined $to_idx;
	return 0 unless $allowed_blocks->{$from_idx} && $allowed_blocks->{$to_idx};

	my @queue = ({ x => $from->{x}, y => $from->{y} });
	my $head = 0;
	my %visited = ("$from->{x},$from->{y}" => 1);
	while ($head < @queue) {
		my $p = $queue[$head++];
		return 1 if $p->{x} == $to->{x} && $p->{y} == $to->{y};
		for my $d ([-1,0], [1,0], [0,-1], [0,1], [-1,-1], [1,-1], [-1,1], [1,1]) {
			my $nx = $p->{x} + $d->[0];
			my $ny = $p->{y} + $d->[1];
			next if $nx <= 0 || $ny <= 0 || $nx >= $state{width} || $ny >= $state{height};
			next unless is_cell_reachable($nx, $ny) && $field->isWalkable($nx, $ny);
			my $idx = coord_to_block_index($nx, $ny);
			next unless defined $idx && $allowed_blocks->{$idx};
			next unless $field->canMove($p, { x => $nx, y => $ny });
			my $key = "$nx,$ny";
			next if $visited{$key}++;
			push @queue, { x => $nx, y => $ny };
		}
	}
	return 0;
}

sub path_exists_within_block {
	my ($from, $to, $block) = @_;
	return 0 unless $from && $to && $block;
	return 0 unless within_block($from, $block) && within_block($to, $block);

	my $pathfinding = new PathFinding;
	$pathfinding->reset(
		start => $from,
		dest => $to,
		field => $field,
		min_x => $block->{min_x},
		max_x => $block->{max_x},
		min_y => $block->{min_y},
		max_y => $block->{max_y},
		avoidWalls => 1,
		randomFactor => 0,
		useManhattan => 0
	);
	my $dist = $pathfinding->runcount;
	return ($dist && $dist > 0) ? 1 : 0;
}

sub within_block {
	my ($pos, $block) = @_;
	return 0 unless $pos && $block;
	return 0 if $pos->{x} < $block->{min_x};
	return 0 if $pos->{x} > $block->{max_x};
	return 0 if $pos->{y} < $block->{min_y};
	return 0 if $pos->{y} > $block->{max_y};
	return 1;
}

sub advance_plan {
	my $current_block = $state{current_block};
	$state{visits_in_block}++;
	my $block = $state{bounds}->[$current_block];
	my $quota = $block ? scalar(@{$block->{target_cells} || []}) : 0;
	$quota = $state{cells_per_block} if $quota > $state{cells_per_block};
	$state{last_block} = $current_block;
	complete_empty_block($current_block) if !$quota || $state{visits_in_block} >= $quota;
}

sub pick_next_block {
	my ($current_idx) = @_;
	return 0 unless $state{block_count};
	$current_idx = 0 if !defined $current_idx || $current_idx < 0 || $current_idx >= $state{block_count};

	my @active_unvisited = grep {
		my $b = $state{bounds}->[$_];
		$b && $b->{walkable_count} > 0 && !$state{visited_blocks_in_cycle}{$_};
	} (0 .. $state{block_count} - 1);

	if (!@active_unvisited) {
		$state{visited_blocks_in_cycle} = {};
		@active_unvisited = grep {
			my $b = $state{bounds}->[$_];
			$b && $b->{walkable_count} > 0;
		} (0 .. $state{block_count} - 1);
		return $current_idx unless @active_unvisited;
	}

	my @neighbors = get_neighbor_block_indexes($current_idx);
	my @neighbor_unvisited = grep {
		my $b = $state{bounds}->[$_];
		$b && $b->{walkable_count} > 0 && !$state{visited_blocks_in_cycle}{$_} && neighbor_connection_score($current_idx, $_) > 0;
	} @neighbors;

	if (@neighbor_unvisited) {
		my $best_score;
		my @best;
		for my $n (@neighbor_unvisited) {
			my $score = neighbor_connection_score($current_idx, $n);
			if (!defined $best_score || $score > $best_score) {
				$best_score = $score;
				@best = ($n);
			} elsif ($score == $best_score) {
				push @best, $n;
			}
		}
		return $best[int(rand(@best))];
	}

	my ($cx, $cy) = block_index_to_grid($current_idx);
	my $best_dist;
	my @best;
	for my $idx (@active_unvisited) {
		my ($x, $y) = block_index_to_grid($idx);
		my $d = abs($x - $cx) + abs($y - $cy);
		if (!defined $best_dist || $d < $best_dist) {
			$best_dist = $d;
			@best = ($idx);
		} elsif ($d == $best_dist) {
			push @best, $idx;
		}
	}

	return @best ? $best[int(rand(@best))] : $current_idx;
}

sub get_neighbor_block_indexes {
	my ($idx) = @_;
	my ($x, $y) = block_index_to_grid($idx);
	my @neighbors;
	for my $d ([1,0], [0,1], [-1,0], [0,-1]) {
		my $nx = $x + $d->[0];
		my $ny = $y + $d->[1];
		next if $nx < 0 || $ny < 0;
		next if $nx >= $state{blocks_x} || $ny >= $state{blocks_y};
		push @neighbors, block_grid_to_index($nx, $ny);
	}
	return @neighbors;
}

sub block_index_to_grid {
	my ($idx) = @_;
	my $x = $idx % $state{blocks_x};
	my $y = int($idx / $state{blocks_x});
	return ($x, $y);
}

sub block_grid_to_index {
	my ($x, $y) = @_;
	return $y * $state{blocks_x} + $x;
}

sub coord_to_block_index {
	my ($x, $y) = @_;
	return undef unless defined $x && defined $y;
	return $state{block_index_lookup}{"$x,$y"};
}

sub neighbor_connection_score {
	my ($from_idx, $to_idx) = @_;
	my $from = $state{bounds}->[$from_idx];
	my $to = $state{bounds}->[$to_idx];
	return 0 unless $from && $to;

	my $count = 0;
	my $min_x = $from->{min_x} < $to->{min_x} ? $from->{min_x} : $to->{min_x};
	my $max_x = $from->{max_x} > $to->{max_x} ? $from->{max_x} : $to->{max_x};
	my $min_y = $from->{min_y} < $to->{min_y} ? $from->{min_y} : $to->{min_y};
	my $max_y = $from->{max_y} > $to->{max_y} ? $from->{max_y} : $to->{max_y};

	for my $y ($min_y .. $max_y) {
		for my $x ($min_x .. $max_x) {
			next unless is_cell_reachable($x, $y);
			my $idx = coord_to_block_index($x, $y);
			next unless defined $idx && $idx == $from_idx;
			for my $d ([1,0], [-1,0], [0,1], [0,-1]) {
				my $nx = $x + $d->[0];
				my $ny = $y + $d->[1];
				next unless is_cell_reachable($nx, $ny);
				my $nidx = coord_to_block_index($nx, $ny);
				$count++ if defined $nidx && $nidx == $to_idx;
			}
		}
	}

	return $count;
}

sub on_command_lock_map_sweep {
	my (undef, $args) = @_;
	$args = '' unless defined $args;
	my ($command) = split(/\s+/, $args, 2);
	$command = defined $command && $command ne '' ? lc($command) : 'status';

	if ($command eq 'status') {
		my $visited_blocks = scalar keys %{$state{visited_blocks_in_cycle}};
		message sprintf("[lockMapSweep] ready=%d map=%s block=%d/%d visit=%d/%d visitedBlocks=%d\n",
			$state{ready} ? 1 : 0,
			($state{last_lock_map} || '-'),
			$state{current_block} + 1,
			($state{block_count} || 0),
			$state{visits_in_block},
			($state{cells_per_block} || 0),
			$visited_blocks
		), 'info';
		return;
	}

	if ($command eq 'clearstate') {
		if ($state{state_file} && -f $state{state_file}) {
			if (unlink $state{state_file}) {
				message "[lockMapSweep] State file removed.\n", 'success';
			} else {
				warning "[lockMapSweep] Failed to remove state file: $!\n", 'system';
			}
		} else {
			warning "[lockMapSweep] No state file to remove.\n", 'system';
		}
		return;
	}

	if ($command eq 'rebuild') {
		if (initialize_or_reload(1)) {
			message "[lockMapSweep] State rebuilt from current lockMap/config.\n", 'success';
		} else {
			warning "[lockMapSweep] Rebuild failed; the previous valid state was preserved.\n", 'system';
		}
		return;
	}

	warning "[lockMapSweep] Usage: lockMapSweep [status|rebuild|clearstate]\n", 'system';
}

sub build_state_file_path {
	my ($map, $bx, $by) = @_;
	my $dir = $config{lockMapSweep_stateDir} || File::Spec->catdir('plugins', 'lockMapSweep', 'state');
	my $safe_map = $map;
	$safe_map =~ s/[^A-Za-z0-9_\-\@]/_/g;
	my $cells = positive_int_or_default($config{lockMapSweep_cellsPerBlock}, 3);
	return File::Spec->catfile($dir, $safe_map . "_${bx}x${by}_c${cells}_v4.state");
}

sub load_state_from_file {
	return 0 unless should_use_state_file();
	return 0 unless $state{state_file};
	return 0 unless -f $state{state_file};

	open my $fh, '<', $state{state_file} or return 0;
	my @lines = <$fh>;
	close $fh;

	my (%meta, %bounds, %visited_blocks, %used_targets, %failed_targets, $pending);
	for my $line (@lines) {
		chomp $line;
		next if $line =~ /^\s*$/;
		if ($line =~ /^meta\t([^\t]+)\t(.*)$/) {
			return 0 if exists $meta{$1};
			$meta{$1} = $2;
		} elsif ($line =~ /^block\t(\d+)\t(\d+)\t(\d+)\t(\d+)\t(\d+)\t(\d+)$/) {
			return 0 if exists $bounds{$1};
			$bounds{$1} = { min_x => $2, max_x => $3, min_y => $4, max_y => $5, walkable_count => $6 };
		} elsif ($line =~ /^visited\t(\d+)$/) {
			return 0 if exists $visited_blocks{$1};
			$visited_blocks{$1} = 1;
		} elsif ($line =~ /^target\t(\d+)\t(\d+)\t(\d+)$/) {
			my ($idx, $x, $y) = ($1, $2, $3);
			return 0 if $used_targets{$idx}{"$x,$y"}++;
		} elsif ($line =~ /^failed\t(\d+)\t(\d+)\t(\d+)$/) {
			my ($idx, $x, $y) = ($1, $2, $3);
			return 0 if $failed_targets{$idx}{"$x,$y"}++;
		} elsif ($line =~ /^pending\t(\d+)\t(\d+)\t(\d+)$/) {
			return 0 if $pending;
			$pending = { block_idx => int($1), x => int($2), y => int($3) };
		} else {
			return 0;
		}
	}

	return 0 unless $meta{version} && $meta{version} eq '4';
	return 0 unless $meta{map} && $meta{map} eq $state{last_lock_map};
	return 0 unless defined $meta{width} && $meta{width} == $state{width};
	return 0 unless defined $meta{height} && $meta{height} == $state{height};
	return 0 unless defined $meta{blocks_x} && $meta{blocks_x} == $state{blocks_x};
	return 0 unless defined $meta{blocks_y} && $meta{blocks_y} == $state{blocks_y};
	return 0 unless defined $meta{cells_per_block} && $meta{cells_per_block} == $state{cells_per_block};
	return 0 unless defined $meta{geometry} && $meta{geometry} eq $state{geometry_signature};
	return 0 unless defined $meta{current_block} && $meta{current_block} =~ /^\d+$/ && $meta{current_block} < $state{block_count};
	return 0 unless defined $meta{visits_in_block} && $meta{visits_in_block} =~ /^\d+$/;
	return 0 unless defined $meta{walk_min_x} && $meta{walk_min_x} =~ /^\d+$/;
	return 0 unless defined $meta{walk_max_x} && $meta{walk_max_x} =~ /^\d+$/;
	return 0 unless defined $meta{walk_min_y} && $meta{walk_min_y} =~ /^\d+$/;
	return 0 unless defined $meta{walk_max_y} && $meta{walk_max_y} =~ /^\d+$/;
	return 0 unless $meta{walk_min_x} == $state{walk_min_x};
	return 0 unless $meta{walk_max_x} == $state{walk_max_x};
	return 0 unless $meta{walk_min_y} == $state{walk_min_y};
	return 0 unless $meta{walk_max_y} == $state{walk_max_y};
	return 0 unless scalar(keys %bounds) == $state{block_count};

	my @restored_bounds;
	my $walk_width = $state{walk_max_x} - $state{walk_min_x} + 1;
	my $walk_height = $state{walk_max_y} - $state{walk_min_y} + 1;
	for my $idx (0 .. $state{block_count} - 1) {
		my $saved = $bounds{$idx} or return 0;
		my $bx = $idx % $state{blocks_x};
		my $by = int($idx / $state{blocks_x});
		my $expected_min_x = $state{walk_min_x} + int(($bx * $walk_width) / $state{blocks_x});
		my $expected_max_x = $state{walk_min_x} + int((($bx + 1) * $walk_width) / $state{blocks_x}) - 1;
		my $expected_min_y = $state{walk_min_y} + int(($by * $walk_height) / $state{blocks_y});
		my $expected_max_y = $state{walk_min_y} + int((($by + 1) * $walk_height) / $state{blocks_y}) - 1;
		$expected_max_x = $state{walk_max_x} if $bx == $state{blocks_x} - 1;
		$expected_max_y = $state{walk_max_y} if $by == $state{blocks_y} - 1;
		return 0 unless $saved->{min_x} == $expected_min_x && $saved->{max_x} == $expected_max_x
			&& $saved->{min_y} == $expected_min_y && $saved->{max_y} == $expected_max_y;
		return 0 if $saved->{min_x} > $saved->{max_x} || $saved->{min_y} > $saved->{max_y};
		my @target_cells;
		for my $y ($saved->{min_y} .. $saved->{max_y}) {
			for my $x ($saved->{min_x} .. $saved->{max_x}) {
				push @target_cells, { x => $x, y => $y } if is_cell_eligible($x, $y);
			}
		}
		return 0 unless @target_cells == $saved->{walkable_count};
		$restored_bounds[$idx] = { %$saved, target_cells => \@target_cells };
	}
	for my $idx (keys %visited_blocks) {
		return 0 if $idx >= $state{block_count} || !$restored_bounds[$idx]{walkable_count};
	}
	for my $idx (keys %used_targets) {
		return 0 if $idx >= $state{block_count};
		my $block = $restored_bounds[$idx];
		for my $coord (keys %{$used_targets{$idx}}) {
			my ($x, $y) = split /,/, $coord;
			return 0 unless within_block({ x => $x, y => $y }, $block) && is_cell_eligible($x, $y);
		}
	}
	for my $idx (keys %failed_targets) {
		return 0 if $idx >= $state{block_count};
		my $block = $restored_bounds[$idx];
		for my $coord (keys %{$failed_targets{$idx}}) {
			my ($x, $y) = split /,/, $coord;
			return 0 unless within_block({ x => $x, y => $y }, $block) && is_cell_eligible($x, $y);
		}
	}
	if ($pending) {
		return 0 if $pending->{block_idx} >= $state{block_count};
		my $pending_block = $restored_bounds[$pending->{block_idx}];
		return 0 unless $pending->{block_idx} == $meta{current_block};
		return 0 unless within_block({ x => $pending->{x}, y => $pending->{y} }, $pending_block)
			&& is_cell_eligible($pending->{x}, $pending->{y});
	}
	my $block = $restored_bounds[$meta{current_block}];
	my $quota = scalar @{$block->{target_cells}};
	$quota = $state{cells_per_block} if $quota > $state{cells_per_block};
	return 0 if $meta{visits_in_block} >= $quota;

	$state{current_block} = int($meta{current_block});
	$state{visits_in_block} = int($meta{visits_in_block});
	$state{bounds} = \@restored_bounds;
	$state{walk_min_x} = int($meta{walk_min_x});
	$state{walk_max_x} = int($meta{walk_max_x});
	$state{walk_min_y} = int($meta{walk_min_y});
	$state{walk_max_y} = int($meta{walk_max_y});
	$state{visited_blocks_in_cycle} = \%visited_blocks;
	$state{used_targets_by_block} = {};
	$state{failed_targets_by_block} = {};
	for my $idx (keys %used_targets) {
		$state{used_targets_by_block}{block_key($restored_bounds[$idx])} = $used_targets{$idx};
	}
	for my $idx (keys %failed_targets) {
		$state{failed_targets_by_block}{block_key($restored_bounds[$idx])} = $failed_targets{$idx};
	}
	$state{pending_target} = $pending;

	return 1;
}

sub persist_state {
	return 1 unless should_use_state_file();
	return 0 unless $state{state_file};

	return 0 unless $state{ready};
	my (undef, $dir) = File::Spec->splitpath($state{state_file});
	$dir ||= '.';
	eval { make_path($dir) unless -d $dir; 1 } or do {
		warning "[lockMapSweep] Failed to create state directory: $dir\n", 'system';
		return 0;
	};
	my ($fh, $temporary);
	eval { ($fh, $temporary) = tempfile('.lockMapSweep-XXXXXX', DIR => $dir, UNLINK => 0); 1 } or do {
		my $error_text = $@ || $! || 'unknown temporary-file error';
		warning "[lockMapSweep] Failed to create temporary state file in $dir: $error_text\n", 'system';
		return 0;
	};
	unless ($fh) {
		warning "[lockMapSweep] Failed to create temporary state file in $dir: $!\n", 'system';
		return 0;
	}
	my $ok = eval {
		print {$fh} "meta\tversion\t4\n";
		print {$fh} "meta\tmap\t$state{last_lock_map}\n";
		print {$fh} "meta\twidth\t$state{width}\n";
		print {$fh} "meta\theight\t$state{height}\n";
		print {$fh} "meta\tblocks_x\t$state{blocks_x}\n";
		print {$fh} "meta\tblocks_y\t$state{blocks_y}\n";
		print {$fh} "meta\tcells_per_block\t$state{cells_per_block}\n";
		print {$fh} "meta\tgeometry\t$state{geometry_signature}\n";
		print {$fh} "meta\tcurrent_block\t$state{current_block}\n";
		print {$fh} "meta\tvisits_in_block\t$state{visits_in_block}\n";
		print {$fh} "meta\twalk_min_x\t$state{walk_min_x}\n";
		print {$fh} "meta\twalk_max_x\t$state{walk_max_x}\n";
		print {$fh} "meta\twalk_min_y\t$state{walk_min_y}\n";
		print {$fh} "meta\twalk_max_y\t$state{walk_max_y}\n";
		for my $idx (0 .. $#{$state{bounds}}) {
			my $b = $state{bounds}->[$idx];
			print {$fh} join("\t", 'block', $idx, @{$b}{qw(min_x max_x min_y max_y walkable_count)}) . "\n";
		}
		for my $idx (0 .. $#{$state{bounds}}) {
			my $key = block_key($state{bounds}[$idx]);
			for my $coord (sort keys %{$state{failed_targets_by_block}{$key} || {}}) {
				my ($x, $y) = split /,/, $coord;
				print {$fh} "failed\t$idx\t$x\t$y\n";
			}
		}
		if (my $pending = $state{pending_target}) {
			print {$fh} "pending\t$pending->{block_idx}\t$pending->{x}\t$pending->{y}\n";
		}
		for my $idx (sort { $a <=> $b } keys %{$state{visited_blocks_in_cycle}}) {
			print {$fh} "visited\t$idx\n";
		}
		for my $idx (0 .. $#{$state{bounds}}) {
			my $key = block_key($state{bounds}[$idx]);
			for my $coord (sort keys %{$state{used_targets_by_block}{$key} || {}}) {
				my ($x, $y) = split /,/, $coord;
				print {$fh} "target\t$idx\t$x\t$y\n";
			}
		}
		close($fh) or die "Cannot close temporary state file: $!";
		rename($temporary, $state{state_file}) or die "Cannot atomically replace state file: $!";
		1;
	};
	if (!$ok) {
		my $error_text = $@ || 'unknown write failure';
		close $fh;
		unlink $temporary if -e $temporary;
		warning "[lockMapSweep] State persistence failed: $error_text\n", 'system';
		return 0;
	}
	return 1;
}

sub should_use_state_file {
	return !defined $config{lockMapSweep_useStateFile} || $config{lockMapSweep_useStateFile} !~ /^0$/;
}

sub positive_int_or_default {
	my ($value, $default) = @_;
	return $default if !defined $value;
	return $default if $value !~ /^\d+$/;
	return $default if $value <= 0;
	return int($value);
}

1;
