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
use Time::HiRes qw(time);

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

# Align travel-cost softmax to the same bound used for first-leg detours.
my $MAX_REASONABLE_DETOUR = 24;
my $GLOBAL_PLAN_TEMPERATURE = $MAX_REASONABLE_DETOUR;
my $STRATEGIC_WAYPOINT_STEPS = 96;
my $FAILED_TARGET_RETRY_SECONDS = 30;

my $strategic_search_cache;

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
	destination_bitmap => '',
	destination_cell_count => 0,
	regions => [],
	region_lookup => {},
	region_index_map => '',
	regions_by_block => {},
	topology_built => 0,
	block_visit_counts => {},
	region_visit_history => {},
	round_number => 1,
	deferred_blocks => {},
	geometry_signature => '',
		restriction_signature => '',
	pending_target => undef,
	failed_targets_by_block => {},
	failed_retry_after => 0,
	failed_config_signature => undef,
);

sub on_unload {
	Plugins::delHooks($hooks);
	Commands::unregister($cmd_hooks);
	message "[lockMapSweep] Plugin unloading/reloading.\n", 'success';
}

sub on_postloadfiles {
	# Core files can load before OpenKore has an authoritative character map
	# position. In that case map-change will build the topology with the correct
	# origin; doing an origin-less full build here only to discard it duplicates
	# the largest-component and region scans during startup.
	return unless $char && $field && $config{lockMap}
		&& $field->baseName eq $config{lockMap};
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
	# OpenKore can leave pos at the start of its last movement packet after the
	# server has already settled at pos_to. Plan from the settled endpoint so
	# route estimates start at the confirmed current cell.
	my $origin = $char->{pos_to} || $char->{pos};
	if ($origin && defined $origin->{x} && defined $origin->{y}
		&& !is_cell_reachable($origin->{x}, $origin->{y})) {
		initialize_or_reload(undef, $origin);
	}
	if ($origin && $strategic_search_cache
		&& $strategic_search_cache->{origin} ne "$origin->{x},$origin->{y}") {
		$strategic_search_cache = undef;
	}

	if (!$state{ready}) {
		warning "[lockMapSweep] State is not ready, falling back to default randomWalk.\n", 'system';
		return;
	}
	if (release_failed_targets_if_due()) {
		persist_state();
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
		my $has_origin = $origin && defined $origin->{x} && defined $origin->{y};
		my $origin_key = $has_origin ? "$origin->{x},$origin->{y}" : 'unknown';
		my $origin_block = $has_origin ? coord_to_block_index($origin->{x}, $origin->{y}) : undef;
		my $block = $state{bounds}->[$state{current_block}];
		warning sprintf(
			"[lockMapSweep] Unable to find a valid target (origin=%s reachable=%d originBlock=%s currentBlock=%d candidates=%d); falling back to default randomWalk.\n",
			$origin_key,
			is_cell_reachable($origin->{x}, $origin->{y}),
			defined $origin_block ? $origin_block + 1 : 'none',
			$state{current_block} + 1,
			$block ? $block->{walkable_count} : 0,
		), 'system';
		if (failure_retry_wait_active()) {
			diagnose_failed_target_exhaustion();
			$args->{return} = 1;
			return;
		}
		return;
	}

	my $attack_auto = Misc::getAttackAutoMode();
	my $attack_on_route = (!defined $attack_auto || $attack_auto < 0) ? 0 : ($attack_auto >= 2 ? 2 : 1);
	set_current_block($target->{block_idx});
	$state{pending_target} = {
		block_idx => $target->{block_idx},
		region_key => $target->{region_key},
		x => $target->{x},
		y => $target->{y},
		from_x => $target->{from_x},
		from_y => $target->{from_y},
		transit => $target->{transit} ? 1 : 0,
	};
	if ($target->{transit}) {
		message sprintf("[lockMapSweep] Calculating strategic transit route to block %d: %d, %d toward region %s (goal cost %d, waypoint %d).\n",
			$target->{block_idx} + 1, $target->{x}, $target->{y},
			$target->{goal_region_key} || 'unknown', $target->{goal_cost} || 0,
			$target->{waypoint_cost} || 0), 'route';
	} else {
		message sprintf("[lockMapSweep] Calculating sweep route to block %d: %d, %d\n", $target->{block_idx} + 1, $target->{x}, $target->{y}), 'route';
	}
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
		$args->{return} = 1;
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
	if ($pending->{transit}) {
		persist_state();
		message sprintf("[lockMapSweep] Reached strategic transit waypoint at %d, %d; no block visit credited.\n",
			$pending->{x}, $pending->{y}), 'route';
		return 1;
	}

	my $key = block_key($block);
	$state{used_targets_by_block}{$key} ||= {};
	$state{used_targets_by_block}{$key}{"$pending->{x},$pending->{y}"} = 1;
	$state{block_visit_counts}{$block_idx} = ($state{block_visit_counts}{$block_idx} || 0) + 1;
	$state{region_visit_history}{$pending->{region_key}}++ if $pending->{region_key};
	$state{last_target} = { x => $pending->{x}, y => $pending->{y} };
	$state{last_block} = $block_idx;
	set_current_block($block_idx);
	$state{visited_blocks_in_cycle}{$block_idx} = 1
		if remaining_block_visits($block_idx) <= 0;
	advance_plan();
	persist_state();
	message sprintf("[lockMapSweep] Confirmed arrival at %d, %d in block %d.\n", $pending->{x}, $pending->{y}, $block_idx + 1), 'route';
	return 1;
}

sub reject_pending_target {
	my ($reason) = @_;
	my $pending = delete $state{pending_target} or return 0;
	my $block = $state{bounds}->[$pending->{block_idx}];
	my $key = $block ? block_key($block) : $pending->{block_idx};
	$state{failed_targets_by_block}{$key} ||= {};
	$state{failed_targets_by_block}{$key}{"$pending->{x},$pending->{y}"} = 1;
	$state{failed_retry_after} = int(time()) + $FAILED_TARGET_RETRY_SECONDS;
	$strategic_search_cache = undef;
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
		destination_bitmap => '',
		destination_cell_count => 0,
		regions => [],
		region_lookup => {},
		region_index_map => '',
		regions_by_block => {},
		topology_built => 0,
		block_visit_counts => {},
		region_visit_history => {},
		round_number => 1,
		deferred_blocks => {},
		geometry_signature => '',
		restriction_signature => '',
		pending_target => undef,
		failed_targets_by_block => {},
		failed_retry_after => 0,
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
	if ($origin) {
		my $origin_key = "$origin->{x},$origin->{y}";
		message sprintf(
			"[lockMapSweep] Reachability origin=%s walkable=%d reachable=%d cells=%d.\n",
			$origin_key,
			$lock_field->isWalkable($origin->{x}, $origin->{y}) ? 1 : 0,
			exists $state{reachable_lookup}{$origin_key} ? 1 : 0,
			scalar keys %{$state{reachable_lookup}},
		), 'plugin';
	}
	if (!%{$state{reachable_lookup}}) {
		error "[lockMapSweep] No reachable walkable cells found on lockMap.\n";
		return $restore_previous->();
	}
	$state{restriction_signature} = lock_restriction_signature();
	$state{destination_bitmap} = build_destination_lookup($lock_field);
	if (!$state{destination_cell_count}) {
		error "[lockMapSweep] No reachable cells satisfy lockMap coordinate restrictions.\n";
		return $restore_previous->();
	}
	$state{geometry_signature} = map_geometry_signature($lock_field);
	$strategic_search_cache = undef;

	set_walkable_bounds_from_lookup();
	unless (build_block_plan($lock_field)) {
		error "[lockMapSweep] Failed to build lockMap block plan.\n";
		return $restore_previous->();
	}

	my $loaded_state = !$force_rebuild && load_state_from_file();
	if ($loaded_state) {
		$state{ready} = 1;
		align_current_block_to_origin($origin);
		persist_state();
		message "[lockMapSweep] Loaded global coverage plan from state file.\n", 'success';
		return 1;
	}
	if (!$force_rebuild && $state{state_file} && -f $state{state_file}) {
		warning "[lockMapSweep] Saved coverage state is incompatible with current map geometry or settings; starting a new round.\n", 'system';
	} elsif (!$force_rebuild && $state{state_file}) {
		my $legacy_file = $state{state_file};
		$legacy_file =~ s/_v6\.state$/_v5.state/;
		my $older_file = $legacy_file;
		$older_file =~ s/_v5\.state$/_v4.state/;
		warning "[lockMapSweep] Version 4 state has block-only progress and cannot restore region coverage; starting a new round.\n", 'system'
			if -f $older_file && !-f $legacy_file;
	}

	$state{ready} = 1;
	$state{used_targets_by_block} = {};
	$state{visited_blocks_in_cycle} = {};
	$state{block_visit_counts} = {};
	$state{region_visit_history} = {};
	$state{round_number} = 1;
	$state{deferred_blocks} = {};
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

			my $eligible_count = 0;
			for my $y ($min_y .. $max_y) {
				for my $x ($min_x .. $max_x) {
					next unless is_cell_eligible($x, $y);
					$eligible_count++;
				}
			}

			push @{ $state{bounds} }, {
				min_x => $min_x,
				max_x => $max_x,
				min_y => $min_y,
				max_y => $max_y,
				walkable_count => $eligible_count,
			};
		}
	}

	$state{block_visit_counts} = {};
	set_current_block(first_non_empty_block());
	$state{used_targets_by_block} = {};
	$state{visited_blocks_in_cycle} = {};
	$state{region_visit_history} = {} unless ref($state{region_visit_history}) eq 'HASH';
	$state{round_number} = 1 unless $state{round_number};
	$state{deferred_blocks} = {};
	$state{last_block} = undef;
	build_region_topology($lock_field);
	return 1;
}

sub build_region_topology {
	my ($lock_field) = @_;
	return 0 unless $lock_field && $state{bounds} && @{$state{bounds}};
	my $started = time();
	my $reachable_count = scalar keys %{$state{reachable_lookup}};
	my $topology = build_region_topology_for_grid(
		$state{bounds},
		sub { is_cell_reachable(@_) },
		sub { is_cell_eligible(@_) },
		sub { $lock_field->isWalkable(@_) },
		sub { $lock_field->canMove(@_) },
		sub { block_index_for_cell(@_) },
	);
	$state{regions} = $topology->{regions};
	my $region_index_map = "\0" x ($state{width} * $state{height} * 4);
	while (my ($key, $region_id) = each %{$topology->{region_lookup}}) {
		my ($x, $y) = split /,/, $key, 2;
	vec($region_index_map, $y * $state{width} + $x, 32) = $region_id + 1;
	}
	$state{region_index_map} = $region_index_map;
	$state{region_lookup} = {};
	$state{regions_by_block} = $topology->{regions_by_block};
	$state{topology_built} = 1;
	my $region_map_cells = 0;
	my $region_target_cells = 0;
	for my $region (@{$state{regions}}) {
		$region_map_cells += $region->{cell_count} || 0;
		$region_target_cells += $region->{eligible_count} || 0;
	}
	# Every reachable cell belongs to exactly one region. Keep the region map as
	# the single post-build membership index instead of retaining a second large
	# hash with the same coordinate keys and boolean values.
	$state{reachable_lookup} = {};
	message sprintf("[lockMapSweep] Region topology built regions=%d reachableCells=%d regionMapCells=%d eligibleDestinations=%d regionTargetCells=%d eligibilityBitmapBytes=%d weightedRouteCells=%d weightedEdges=%d elapsedMs=%.1f.\n",
		scalar(@{$state{regions}}), $reachable_count, $region_map_cells, $state{destination_cell_count},
		$region_target_cells, length($state{destination_bitmap} || ''), $topology->{weighted_route_cells} || 0,
		$topology->{weighted_edge_count} || 0, (time() - $started) * 1000), 'plugin';
	return scalar @{$state{regions}};
}

sub build_region_topology_for_grid {
	my ($bounds, $is_reachable, $is_eligible, $is_walkable, $can_move, $block_index_for_cell) = @_;
	return { regions => [], region_lookup => {}, regions_by_block => {} }
		unless ref($bounds) eq 'ARRAY' && ref($is_reachable) eq 'CODE'
			&& ref($is_eligible) eq 'CODE' && ref($is_walkable) eq 'CODE'
			&& ref($can_move) eq 'CODE';
	my @regions;
	my %region_at;
	my %regions_by_block;
	my %block_at;
	my %portal_cells;
	my @directions = ([-1, 0], [1, 0], [0, -1], [0, 1],
		[-1, -1], [1, -1], [-1, 1], [1, 1]);
	if (ref($block_index_for_cell) ne 'CODE') {
		for my $block_idx (0 .. $#$bounds) {
			my $block = $bounds->[$block_idx];
			next unless $block;
			for my $y ($block->{min_y} .. $block->{max_y}) {
				for my $x ($block->{min_x} .. $block->{max_x}) {
					$block_at{"$x,$y"} = $block_idx;
				}
			}
		}
	}
	my $block_for_cell = ref($block_index_for_cell) eq 'CODE'
		? $block_index_for_cell
		: sub { $block_at{"$_[0],$_[1]"} };

	# First split each block into movement-connected components. Restriction-
	# excluded walkable cells stay in the component graph because OpenKore may
	# traverse them en route to an eligible destination.
	for my $block_idx (0 .. $#$bounds) {
		my $block = $bounds->[$block_idx];
		next unless $block;
		for my $y ($block->{min_y} .. $block->{max_y}) {
			for my $x ($block->{min_x} .. $block->{max_x}) {
				my $start_key = "$x,$y";
				next unless $is_reachable->($x, $y) && !exists $region_at{$start_key};
				my $region_id = scalar @regions;
				my @queue = ({ x => $x, y => $y });
				my $head = 0;
				$region_at{$start_key} = $region_id;
				my ($cell_count, $eligible_count, $sum_x, $sum_y) = (0, 0, 0, 0);
				my @targets;
				while ($head < @queue) {
					my $pos = $queue[$head++];
					$cell_count++;
					$sum_x += $pos->{x};
					$sum_y += $pos->{y};
					my $pos_key = "$pos->{x},$pos->{y}";
					if ($is_eligible->($pos->{x}, $pos->{y})) {
						$eligible_count++;
						push @targets, pack_region_target($pos->{x}, $pos->{y});
					}
					for my $d (@directions) {
						my ($nx, $ny) = ($pos->{x} + $d->[0], $pos->{y} + $d->[1]);
						my $next_key = "$nx,$ny";
						next if exists $region_at{$next_key};
						my $neighbor_block = $block_for_cell->($nx, $ny);
						next unless defined($neighbor_block) && $neighbor_block == $block_idx;
						next unless $is_reachable->($nx, $ny) && $is_walkable->($nx, $ny);
						next unless $can_move->($pos, { x => $nx, y => $ny });
						$region_at{$next_key} = $region_id;
						push @queue, { x => $nx, y => $ny };
					}
				}
				my $center_x = $sum_x / ($cell_count || 1);
				my $center_y = $sum_y / ($cell_count || 1);
			my ($representative, $representative_distance);
			if (@targets) {
				for my $target (@targets) {
					my ($target_x, $target_y) = unpack_region_target($target);
					my $distance = ($target_x - $center_x) ** 2 + ($target_y - $center_y) ** 2;
					if (!defined($representative_distance) || $distance < $representative_distance) {
						$representative = { x => $target_x, y => $target_y };
						$representative_distance = $distance;
					}
				}
			} else {
				($representative) = sort {
					(($a->{x} - $center_x) ** 2 + ($a->{y} - $center_y) ** 2)
						<=> (($b->{x} - $center_x) ** 2 + ($b->{y} - $center_y) ** 2)
				} @queue;
			}
				$regions[$region_id] = {
					id => $region_id,
					key => sprintf('%d:%s', $block_idx, $start_key),
					block_idx => $block_idx,
					cell_count => $cell_count,
					eligible_count => $eligible_count,
					target_cells => \@targets,
					representative => { %$representative },
					neighbors => {},
					weighted_neighbors => {},
				};
				push @{$regions_by_block{$block_idx}}, $region_id;
			}
		}
	}

	# Build the global region graph from legal movement transitions. Paths that
	# leave a block and later return are represented as ordinary graph paths
	# through the intervening block regions.
	my @transition_edges;
	for my $key (keys %region_at) {
		my ($x, $y) = split /,/, $key, 2;
		my $from_id = $region_at{$key};
		for my $d (@directions) {
			my ($nx, $ny) = ($x + $d->[0], $y + $d->[1]);
			my $to_key = "$nx,$ny";
			next unless exists $region_at{$to_key};
			my $to_id = $region_at{$to_key};
			next if $from_id == $to_id;
			next unless $can_move->({ x => $x, y => $y }, { x => $nx, y => $ny });
			$regions[$from_id]{neighbors}{$to_id}++;
			push @transition_edges, [$from_id, $key, $to_id, $to_key];
			$portal_cells{$from_id}{$key} = 1;
			$portal_cells{$to_id}{$to_key} = 1;
		}
	}

	# Each component is searched once from its representative in each direction.
	# Only distances to boundary portal cells survive, keeping the compressed
	# weighted graph small while making continuation estimates movement-aware.
	my (%portal_from_cost, %portal_to_cost);
	my $weighted_route_cells = 0;
	for my $region (@regions) {
		my $id = $region->{id};
		my $keys = $portal_cells{$id} || {};
		next unless %$keys;
		my ($forward, $forward_count) = region_local_portal_costs(
			$region->{representative}, $id, \%region_at, $keys, $is_walkable, $can_move, 0);
		my ($reverse, $reverse_count) = region_local_portal_costs(
			$region->{representative}, $id, \%region_at, $keys, $is_walkable, $can_move, 1);
		$weighted_route_cells += $forward_count + $reverse_count;
		$portal_from_cost{$id} = $forward;
		$portal_to_cost{$id} = $reverse;
	}
	for my $edge (@transition_edges) {
		my ($from_id, $from_key, $to_id, $to_key) = @$edge;
		my $from_cost = $portal_from_cost{$from_id}{$from_key};
		my $to_cost = $portal_to_cost{$to_id}{$to_key};
		next unless defined $from_cost && defined $to_cost;
		my $cost = $from_cost + 1 + $to_cost;
		my $old = $regions[$from_id]{weighted_neighbors}{$to_id};
		$regions[$from_id]{weighted_neighbors}{$to_id} = $cost
			if !defined($old) || $cost < $old;
	}
	my $weighted_edge_count = 0;
	$weighted_edge_count += scalar keys %{$_->{weighted_neighbors}} for @regions;

	return { regions => \@regions, region_lookup => \%region_at, regions_by_block => \%regions_by_block,
		weighted_route_cells => $weighted_route_cells, weighted_edge_count => $weighted_edge_count };
}

sub region_local_portal_costs {
	my ($origin, $region_id, $region_at, $portals, $is_walkable, $can_move, $reverse) = @_;
	return ({}, 0) unless $origin && ref($region_at) eq 'HASH' && ref($portals) eq 'HASH';
	my $origin_key = "$origin->{x},$origin->{y}";
	my %costs = ($origin_key => 0);
	my @queue = ({ x => $origin->{x}, y => $origin->{y} });
	my $head = 0;
	my %found;
	while ($head < @queue) {
		my $pos = $queue[$head++];
		my $pos_key = "$pos->{x},$pos->{y}";
		$found{$pos_key} = $costs{$pos_key} if $portals->{$pos_key};
		for my $d ([-1,0], [1,0], [0,-1], [0,1], [-1,-1], [1,-1], [-1,1], [1,1]) {
			my ($nx, $ny) = ($pos->{x} + $d->[0], $pos->{y} + $d->[1]);
			my $next_key = "$nx,$ny";
			next if exists $costs{$next_key};
			next unless exists $region_at->{$next_key} && $region_at->{$next_key} == $region_id;
			next unless $is_walkable->($nx, $ny);
			my $can = $reverse
				? $can_move->({x => $nx, y => $ny}, $pos)
				: $can_move->($pos, {x => $nx, y => $ny});
			next unless $can;
			$costs{$next_key} = $costs{$pos_key} + 1;
			push @queue, {x => $nx, y => $ny};
		}
	}
	return (\%found, scalar @queue);
}

# Target cells are persisted in region topology as packed 16-bit x/y coordinates.
# OpenKore field dimensions fit in this representation, and it avoids retaining
# one Perl hash and several references for every eligible cell on large maps.
sub pack_region_target {
	my ($x, $y) = @_;
	return (int($y) << 16) | int($x);
}

sub unpack_region_target {
	my ($target) = @_;
	return ($target->{x}, $target->{y}) if ref($target) eq 'HASH';
	return (int($target) & 0xffff, int($target) >> 16);
}

sub calculate_region_selection_weights {
	my ($regions, $confirmed_by_region, $candidate_ids) = @_;
	$confirmed_by_region ||= {};
	return [] unless ref($regions) eq 'ARRAY' && ref($confirmed_by_region) eq 'HASH';
	my @active = grep { $_ && ($_->{eligible_count} || 0) > 0 } @$regions;
	my $eligible_total = 0;
	$eligible_total += $_->{eligible_count} for @active;
	return [] unless $eligible_total > 0;

	my $confirmed_total = 0;
	for my $region (@active) {
		my $key = defined $region->{key} ? $region->{key} : $region->{id};
		my $count = $confirmed_by_region->{$key} || 0;
		$confirmed_total += $count if $count > 0;
	}
	my $debt_scale = sqrt($confirmed_total + 1);
	my $max_log_bias = log(3);
	my @log_weights;
	for my $region (@active) {
		my $region_id = $region->{id};
		next if $candidate_ids && !$candidate_ids->{$region_id};
		my $key = defined $region->{key} ? $region->{key} : $region_id;
		my $share = $region->{eligible_count} / $eligible_total;
		my $confirmed = $confirmed_by_region->{$key} || 0;
		my $debt = $confirmed_total * $share - $confirmed;
		my $log_bias = $debt / $debt_scale;
		$log_bias = $max_log_bias if $log_bias > $max_log_bias;
		$log_bias = -$max_log_bias if $log_bias < -$max_log_bias;
		push @log_weights, {
			region_id => $region_id,
			region_key => $key,
			share => $share,
			debt => $debt,
			log_weight => log($share) + $log_bias,
		};
	}
	return [] unless @log_weights;

	# Log-sum-exp keeps tiny regions and large histories numerically stable.
	my $max_log = $log_weights[0]{log_weight};
	for my $item (@log_weights) {
		$max_log = $item->{log_weight} if $item->{log_weight} > $max_log;
	}
	my $sum = 0;
	for my $item (@log_weights) {
		$item->{weight} = exp($item->{log_weight} - $max_log);
		$sum += $item->{weight};
	}
	for my $item (@log_weights) {
		$item->{probability} = $item->{weight} / $sum;
	}
	return \@log_weights;
}

sub sample_region_from_weights {
	my ($weighted_regions, $roll) = @_;
	return undef unless ref($weighted_regions) eq 'ARRAY' && @$weighted_regions;
	$roll = rand() unless defined $roll;
	return undef if $roll < 0 || $roll >= 1;
	my $cumulative = 0;
	for my $item (@$weighted_regions) {
		$cumulative += $item->{probability};
		return $item->{region_id} if $roll < $cumulative;
	}
	return $weighted_regions->[-1]{region_id};
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

# The per-block table is authoritative. Keep the legacy current-block counter
# synchronized whenever the selected block changes, and before persistence.
sub set_current_block {
	my ($block_idx) = @_;
	return 0 unless defined $block_idx && $block_idx =~ /^\d+$/;
	return 0 if $state{block_count} && $block_idx >= $state{block_count};
	$state{current_block} = int($block_idx);
	$state{visits_in_block} = $state{block_visit_counts}{$state{current_block}} || 0;
	return 1;
}

sub align_current_block_to_origin {
	my ($origin) = @_;
	return unless $origin && !$state{pending_target};
	my $block_idx = coord_to_block_index($origin->{x}, $origin->{y});
	return unless defined $block_idx && $state{bounds}->[$block_idx]
		&& $state{bounds}->[$block_idx]{walkable_count} > 0;
	return if $block_idx == $state{current_block};
	set_current_block($block_idx);
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
	return '' if defined($lock_x) && $lock_x !~ /^-?\d+$/;
	return '' if defined($lock_y) && $lock_y !~ /^-?\d+$/;
	my $eligible = "\0" x int(($field_width * $field_height + 7) / 8);
	my $eligible_count = 0;
	for my $key (keys %{$state{reachable_lookup}}) {
		my ($x, $y) = split(/,/, $key, 2);
		next if $x <= 0 || $y <= 0 || $x >= $field_width || $y >= $field_height;
		next if defined($lock_x) && ($rand_x ? ($x < $lock_x - $rand_x || $x >= $lock_x + $rand_x) : $x != $lock_x);
		next if defined($lock_y) && ($rand_y ? ($y < $lock_y - $rand_y || $y >= $lock_y + $rand_y) : $y != $lock_y);
		next if $excluded{$x} && $excluded{$x}{$y};
		vec($eligible, $y * $field_width + $x, 1) = 1;
		$eligible_count++;
	}
	$state{destination_cell_count} = $eligible_count;
	return $eligible;
}

sub map_geometry_signature {
	my ($lock_field) = @_;
	my $sha = Digest::SHA->new(256);
	$sha->add($lock_field->width . 'x' . $lock_field->height . ':');
	$sha->add($lock_field->{rawMap} || '');
	$sha->add(':' . lock_restriction_signature() . ':');
	$sha->add($state{destination_bitmap} || '');
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

sub same_position {
	my ($left, $right) = @_;
	return 0 unless ref($left) eq 'HASH' && ref($right) eq 'HASH';
	return defined($left->{x}) && defined($left->{y})
		&& defined($right->{x}) && defined($right->{y})
		&& $left->{x} == $right->{x} && $left->{y} == $right->{y};
}

sub filter_candidates_within_detour {
	my ($candidates, $maximum_detour) = @_;
	return [] unless ref($candidates) eq 'ARRAY' && @$candidates;
	$maximum_detour = $MAX_REASONABLE_DETOUR
		unless defined $maximum_detour && $maximum_detour >= 0;
	my $best_arrival = (sort { $a <=> $b } map { $_->{arrival_cost} } @$candidates)[0];
	return [grep { $_->{arrival_cost} <= $best_arrival + $maximum_detour } @$candidates];
}

sub is_cell_reachable {
	my ($x, $y) = @_;
	return 0 unless defined $x && defined $y;
	return defined(region_id_at($x, $y)) ? 1 : 0 if $state{topology_built};
	return exists $state{reachable_lookup}{"$x,$y"} ? 1 : 0;
}

sub region_id_at {
	my ($x, $y) = @_;
	return undef unless defined $x && defined $y && $x >= 0 && $y >= 0
		&& $x < $state{width} && $y < $state{height};
	my $encoded = vec($state{region_index_map}, $y * $state{width} + $x, 32);
	return $encoded ? $encoded - 1 : undef;
}

sub is_cell_eligible {
	my ($x, $y) = @_;
	return 0 unless defined $x && defined $y;
	return 0 if $x < 0 || $y < 0 || $x >= $state{width} || $y >= $state{height};
	return vec($state{destination_bitmap}, $y * $state{width} + $x, 1) ? 1 : 0;
}

sub pick_target_in_current_plan {
	return undef unless $state{block_count} && $char && $field;
	my $from = $char->{pos_to} || $char->{pos};
	return undef unless $from && defined $from->{x} && defined $from->{y};
	return undef unless defined coord_to_block_index($from->{x}, $from->{y});
	start_new_coverage_round() if coverage_round_is_complete();
	return undef if failure_retry_wait_active();

	my $decision_started = time();
	my $goal_index_started = time();
	my $local_goal_bitmap = build_local_goal_bitmap($from);
	my $goal_index_ms = (time() - $goal_index_started) * 1000;
	my ($local_started, $local_costs, $local_previous, $local_cells_examined) = (time(), undef, undef, 0);
	($local_costs, $local_previous, $local_cells_examined) =
		cell_route_tree_from($from, 128, 0, $local_goal_bitmap, $MAX_REASONABLE_DETOUR);
	my $local_search_ms = (time() - $local_started) * 1000;
	my $costs = $local_costs;
	my @candidates;
	my %available_by_block;
	my %target_sets;
	for my $region (@{$state{regions}}) {
		my $block_idx = $region->{block_idx};
		next unless remaining_block_visits($block_idx) > 0 && $region->{eligible_count} > 0;
		my $block = $state{bounds}->[$block_idx] or next;
		my $key = block_key($block);
		$state{used_targets_by_block}{$key} ||= {};
		$state{failed_targets_by_block}{$key} ||= {};
		my @targets;
		for my $target (@{$region->{target_cells} || []}) {
			my ($target_x, $target_y) = unpack_region_target($target);
			my $cell_key = "$target_x,$target_y";
			next unless exists $costs->{$cell_key}
				&& !$state{used_targets_by_block}{$key}{$cell_key}
				&& !$state{failed_targets_by_block}{$key}{$cell_key}
				&& !same_position({ x => $target_x, y => $target_y }, $from)
				&& !same_position({ x => $target_x, y => $target_y }, $state{last_target});
			push @targets, { x => $target_x, y => $target_y };
		}
		next unless @targets;
		@targets = sort { $costs->{"$a->{x},$a->{y}"} <=> $costs->{"$b->{x},$b->{y}"} } @targets;
		my $min_cost = $costs->{"$targets[0]{x},$targets[0]{y}"};
		next if $min_cost > 128;
		my @closest = grep { $costs->{"$_->{x},$_->{y}"} == $min_cost } @targets;
		my $target = $closest[int(rand(@closest))];
		my $candidate = {
			region_id => $region->{id},
			region_key => $region->{key},
			block_idx => $block_idx,
			region => $region,
		x => $target->{x},
		y => $target->{y},
		arrival_cost => $min_cost,
	};
		push @candidates, $candidate;
		push @{$available_by_block{$block_idx}}, $region;
		$target_sets{$region->{id}} = scalar @targets;
	}
	unless (@candidates) {
		debug sprintf("[lockMapSweep] Local decision metrics expanded=%d predecessorMap=0 goalIndexMs=%.1f searchMs=%.1f totalMs=%.1f candidates=0 selection=strategic.\n",
			$local_cells_examined || 0, $goal_index_ms, $local_search_ms,
			(time() - $decision_started) * 1000), 'plugin', 2;
		return select_strategic_transit_target($from, scalar keys %$costs);
	}

	# Coverage debt can affect an opportunity only inside the bounded detour window
	# from the nearest remaining obligation, with a 128-step absolute cap.
	my %locally_kept = map { $_->{region_id} => 1 }
		@{filter_candidates_within_detour(\@candidates, $MAX_REASONABLE_DETOUR)};
	my $best_local_arrival = (sort { $a <=> $b } map { $_->{arrival_cost} } @candidates)[0];
	for my $candidate (@candidates) {
		unless ($locally_kept{$candidate->{region_id}}) {
			debug sprintf("[lockMapSweep] Candidate rejected block=%d region=%s arrival=%d bestArrival=%d reason=optional-detour-limit-%d.\n",
				$candidate->{block_idx} + 1, $candidate->{region_key}, $candidate->{arrival_cost},
				$best_local_arrival, $MAX_REASONABLE_DETOUR), 'plugin', 2;
		}
	}
	@candidates = grep { $locally_kept{$_->{region_id}} } @candidates;
	for my $candidate (@candidates) {
		debug sprintf("[lockMapSweep] Candidate block=%d region=%s arrival=%d priorityPending=1 localDetourLimit=%d.\n",
			$candidate->{block_idx} + 1, $candidate->{region_key}, $candidate->{arrival_cost},
			$MAX_REASONABLE_DETOUR), 'plugin', 2;
	}
	my %opportunity_blocks = map { $_->{block_idx} => 1 } @candidates;
	refresh_deferred_blocks(\%opportunity_blocks,
		'outside the 24-step detour window from the nearest current opportunity');
	my %probability_by_region;
	for my $block_idx (keys %available_by_block) {
		my @all_regions = @{$state{regions_by_block}{$block_idx} || []};
		my @region_records = map { $state{regions}[$_] } @all_regions;
		my %eligible_candidate = map { $_->{region_id} => 1 }
			grep { $_->{block_idx} == $block_idx } @candidates;
		my $weighted = calculate_region_selection_weights(
			\@region_records, \%{$state{region_visit_history}}, \%eligible_candidate);
		$probability_by_region{$_->{region_id}} = $_->{probability} for @$weighted;
	}
	my $planned_first = choose_global_plan_first_region(\@candidates, \%probability_by_region);
	return undef unless defined $planned_first;
	my ($candidate) = grep { $_->{region_id} == $planned_first } @candidates;
	return undef unless $candidate;
	debug sprintf("[lockMapSweep] Local decision metrics expanded=%d predecessorMap=0 goalIndexMs=%.1f searchMs=%.1f totalMs=%.1f candidates=%d selected=%s target=%d,%d origin=%d,%d estimatedArrival=%d.\n",
		$local_cells_examined || 0, $goal_index_ms, $local_search_ms, (time() - $decision_started) * 1000,
		scalar(@candidates), $candidate->{region_key}, $candidate->{x}, $candidate->{y},
		$from->{x}, $from->{y}, $candidate->{arrival_cost}), 'plugin', 2;
	return {
		block_idx => $candidate->{block_idx},
		region_key => $candidate->{region_key},
		x => $candidate->{x},
		y => $candidate->{y},
		from_x => $from->{x},
		from_y => $from->{y},
	};
}

sub build_local_goal_bitmap {
	my ($from) = @_;
	my $bitmap = "\0" x int(($state{width} * $state{height} + 7) / 8);
	for my $region (@{$state{regions}}) {
		my $block_idx = $region->{block_idx};
		next unless remaining_block_visits($block_idx) > 0;
		my $block = $state{bounds}[$block_idx] or next;
		my $key = block_key($block);
		my $used = $state{used_targets_by_block}{$key} || {};
		my $failed = $state{failed_targets_by_block}{$key} || {};
		for my $target (@{$region->{target_cells} || []}) {
			my ($target_x, $target_y) = unpack_region_target($target);
			my $cell_key = "$target_x,$target_y";
			next if $used->{$cell_key} || $failed->{$cell_key};
			next if ($target_x == $from->{x} && $target_y == $from->{y})
				|| ($state{last_target} && $target_x == $state{last_target}{x}
					&& $target_y == $state{last_target}{y});
			vec($bitmap, $target_y * $state{width} + $target_x, 1) = 1;
		}
	}
	return $bitmap;
}

sub select_strategic_transit_target {
	my ($from, $local_cells_examined) = @_;
	my $started = time();
	my $origin_key = "$from->{x},$from->{y}";
	my $origin_region = region_id_at($from->{x}, $from->{y});
	my @pending_regions = grep {
		remaining_block_visits($_->{block_idx}) > 0 && ($_->{eligible_count} || 0) > 0
	} @{$state{regions}};
	my %pending_ids = map { $_->{id} => 1 } @pending_regions;
	my $graph_hops = defined $origin_region
		? region_graph_hops_from($origin_region, $state{regions}) : {};
	my @graph_reachable = grep { exists $graph_hops->{$_->{id}} } @pending_regions;
	my $pending_targets = 0;
	for my $region (@pending_regions) {
		my $block = $state{bounds}[$region->{block_idx}] or next;
		my $key = block_key($block);
		for my $cell (@{$region->{target_cells} || []}) {
			my ($cell_x, $cell_y) = unpack_region_target($cell);
			my $cell_key = "$cell_x,$cell_y";
			$pending_targets++ unless $state{used_targets_by_block}{$key}{$cell_key}
				|| $state{failed_targets_by_block}{$key}{$cell_key};
		}
	}
	unless (@pending_regions && $pending_targets) {
		my ($unused_targets, $failed_targets) = pending_target_availability();
		if (!$unused_targets && $failed_targets) {
			diagnose_failed_target_exhaustion();
		} else {
			refresh_deferred_blocks({}, 'no unused eligible targets remain for pending block quotas');
		}
		message sprintf("[lockMapSweep] Planning diagnosis: no usable pending destinations (pendingRegions=%d pendingTargets=%d localCells=%d elapsedMs=%.1f).\n",
			scalar(@pending_regions), $pending_targets, $local_cells_examined || 0, (time() - $started) * 1000), 'route';
		return undef;
	}
	unless (defined $origin_region && @graph_reachable) {
		my $reason = defined $origin_region
			? 'pending regions are disconnected in the region graph'
			: 'current position is missing from the region graph';
		refresh_deferred_blocks({}, $reason);
		message sprintf("[lockMapSweep] Planning diagnosis: region graph disconnected (originRegion=%s pendingRegions=%d graphReachable=%d pendingTargets=%d).\n",
			defined $origin_region ? $origin_region : 'none', scalar(@pending_regions), scalar(@graph_reachable), $pending_targets), 'route';
		return undef;
	}

	my $cache = $strategic_search_cache;
	my $cache_reused = $cache && $cache->{origin} eq $origin_key
		&& $cache->{geometry} eq $state{geometry_signature};
	if (!$cache_reused) {
		my $search_started = time();
		my ($costs, $previous, $expanded) = cell_route_tree_compact_from($from);
		$cache = {
			origin => $origin_key,
			geometry => $state{geometry_signature},
			costs => $costs,
			previous => $previous,
			expanded => $expanded,
		};
		$strategic_search_cache = $cache;
		debug sprintf("[lockMapSweep] Strategic route tree cache=miss origin=%s costEntries=%d predecessorEntries=%d costBytes=%d predecessorBytes=%d elapsedMs=%.1f.\n",
			$origin_key, $expanded, $expanded > 0 ? $expanded - 1 : 0,
			length(${$cache->{costs}}), length(${$cache->{previous}}),
			(time() - $search_started) * 1000), 'plugin', 2;
	} else {
		debug sprintf("[lockMapSweep] Strategic route tree cache=hit origin=%s costEntries=%d predecessorEntries=%d costBytes=%d predecessorBytes=%d.\n",
			$origin_key, $cache->{expanded}, $cache->{expanded} > 0 ? $cache->{expanded} - 1 : 0,
			length(${$cache->{costs}}), length(${$cache->{previous}})), 'plugin', 2;
	}
	my ($costs, $previous) = @{$cache}{qw(costs previous)};
	my @global_candidates;
	my %probability_by_region;
	my %target_sets;
	for my $region (@pending_regions) {
		my $block = $state{bounds}[$region->{block_idx}] or next;
		my $key = block_key($block);
		my ($min_cost, @closest);
		my $available = 0;
		for my $target (@{$region->{target_cells} || []}) {
			my ($target_x, $target_y) = unpack_region_target($target);
			my $cell_key = "$target_x,$target_y";
			next if $state{used_targets_by_block}{$key}{$cell_key}
				|| $state{failed_targets_by_block}{$key}{$cell_key};
			my $cost = route_cost_at($costs, $target_x, $target_y);
			next unless defined $cost;
			$available++;
			if (!defined $min_cost || $cost < $min_cost) {
				$min_cost = $cost;
				@closest = ({ x => $target_x, y => $target_y });
			} elsif ($cost == $min_cost) {
				push @closest, { x => $target_x, y => $target_y };
			}
		}
		$target_sets{$region->{id}} = $available;
		next unless defined $min_cost && @closest;
		my $target = $closest[int(rand(@closest))];
		push @global_candidates, {
			region_id => $region->{id}, region_key => $region->{key},
			block_idx => $region->{block_idx}, region => $region,
			x => $target->{x}, y => $target->{y}, arrival_cost => $min_cost,
		};
	}
	unless (@global_candidates) {
		my $reason = @graph_reachable
			? 'globally reachable topology has no route-cost path to any pending destination'
			: 'pending destinations are unreachable from the current region';
		refresh_deferred_blocks({}, $reason);
		message sprintf("[lockMapSweep] Planning diagnosis: %s (pendingRegions=%d graphReachable=%d searchExpanded=%d localCells=%d elapsedMs=%.1f).\n",
			$reason, scalar(@pending_regions), scalar(@graph_reachable), $cache->{expanded},
			$local_cells_examined || 0, (time() - $started) * 1000), 'route';
		return undef;
	}

	my %eligible_ids = map { $_->{region_id} => 1 } @global_candidates;
	for my $block_idx (keys %{$state{regions_by_block}}) {
		my @records = map { $state{regions}[$_] } @{$state{regions_by_block}{$block_idx}};
		my $weighted = calculate_region_selection_weights(
			\@records, \%{$state{region_visit_history}}, \%eligible_ids);
		$probability_by_region{$_->{region_id}} = $_->{probability} for @$weighted;
	}
	my $planned_region = choose_global_plan_first_region(
		\@global_candidates, \%probability_by_region);
	my ($goal) = grep { $_->{region_id} == $planned_region } @global_candidates;
	unless ($goal) {
		message "[lockMapSweep] Planning diagnosis: global lookahead returned no first region.\n", 'route';
		return undef;
	}
	my $path = reconstruct_cell_path($origin_key, "$goal->{x},$goal->{y}", $previous);
	unless (ref($path) eq 'ARRAY' && @$path > 1 && @$path == $goal->{arrival_cost} + 1) {
		refresh_deferred_blocks({}, 'route-search tree could not reconstruct a path to a connected pending region');
		message sprintf("[lockMapSweep] Planning diagnosis: local search exhausted and global route reconstruction failed (goal=%s cost=%d).\n",
			$goal->{region_key}, $goal->{arrival_cost}), 'route';
		return undef;
	}
	my $max_index = $goal->{arrival_cost} < 128 ? $goal->{arrival_cost} : 128;
	my $waypoint_index;
	for my $i (1 .. $max_index) {
		my ($x, $y) = @{$path->[$i]};
		my $block_idx = coord_to_block_index($x, $y);
		my $block = defined $block_idx ? $state{bounds}[$block_idx] : undef;
		my $failed = $block
			&& $state{failed_targets_by_block}{block_key($block)}{"$x,$y"};
		if (is_cell_eligible($x, $y) && !$failed
			&& !same_position({x => $x, y => $y}, $from)) {
			$waypoint_index = $i;
		}
	}
	unless (defined $waypoint_index) {
		refresh_deferred_blocks({}, 'no legal lockMap destination exists within the bounded strategic waypoint horizon');
		message sprintf("[lockMapSweep] Planning diagnosis: no eligible waypoint within 128 steps (goal=%s goalCost=%d searchExpanded=%d).\n",
			$goal->{region_key}, $goal->{arrival_cost}, $cache->{expanded}), 'route';
		return undef;
	}
	my ($way_x, $way_y) = @{$path->[$waypoint_index]};
	my $way_key = "$way_x,$way_y";
	my $way_region_id = region_id_at($way_x, $way_y);
	my $way_region = defined $way_region_id ? $state{regions}[$way_region_id] : undef;
	my $goal_probability = $probability_by_region{$goal->{region_id}} || 0;
	my $local_reachable_count = scalar grep {
		$_->{arrival_cost} <= 128
	} @global_candidates;
	refresh_deferred_blocks({}, 'pending obligation is globally connected but requires bounded strategic transit');
	message sprintf("[lockMapSweep] Strategic plan diagnosis: pending-region travel selected (origin=%s goal=%s estimatedArrival=%d waypoint=%d localPendingRegions=%d pendingRegions=%d graphReachable=%d searchExpanded=%d elapsedMs=%.1f).\n",
		$origin_key, $goal->{region_key}, $goal->{arrival_cost}, $waypoint_index,
		$local_reachable_count, scalar(@pending_regions), scalar(@graph_reachable),
		$cache->{expanded}, (time() - $started) * 1000), 'route';
	for my $candidate (sort { $a->{arrival_cost} <=> $b->{arrival_cost} } @global_candidates) {
		debug sprintf("[lockMapSweep] Candidate block=%d region=%s arrival=%d priority=%.6f availableTargets=%d selection=global-obligation\n",
			$candidate->{block_idx} + 1, $candidate->{region_key}, $candidate->{arrival_cost},
			$probability_by_region{$candidate->{region_id}} || 0,
			$target_sets{$candidate->{region_id}} || 0), 'plugin', 2;
	}
	return {
		block_idx => $way_region ? $way_region->{block_idx} : $goal->{block_idx},
		region_key => $way_region ? $way_region->{key} : $goal->{region_key},
		x => $way_x, y => $way_y,
		from_x => $from->{x}, from_y => $from->{y},
		transit => 1,
		goal_region_key => $goal->{region_key},
		goal_cost => $goal->{arrival_cost},
		waypoint_cost => $waypoint_index,
	};
}

sub refresh_deferred_blocks {
	my ($opportunities, $reason) = @_;
	my $changed = 0;
	for my $idx (0 .. $#{$state{bounds}}) {
		my $remaining = remaining_block_visits($idx);
		next unless $remaining > 0;
		if ($opportunities->{$idx}) {
			$changed = 1 if delete $state{deferred_blocks}{$idx};
			next;
		}
		next if $state{deferred_blocks}{$idx};
		$state{deferred_blocks}{$idx} = {
			remaining => $remaining,
			round => $state{round_number},
			reason => $reason,
		};
		warning sprintf("[lockMapSweep] Deferring block %d with %d remaining visits: %s.\n",
			$idx + 1, $remaining, $reason), 'route';
		$changed = 1;
	}
	persist_state() if $changed && $state{ready};
}

sub pending_target_availability {
	my ($unused, $failed) = (0, 0);
	for my $region (@{$state{regions}}) {
		my $block_idx = $region->{block_idx};
		next unless remaining_block_visits($block_idx) > 0;
		my $block = $state{bounds}[$block_idx] or next;
		my $key = block_key($block);
		my $used = $state{used_targets_by_block}{$key} || {};
		my $blocked = $state{failed_targets_by_block}{$key} || {};
		for my $packed (@{$region->{target_cells} || []}) {
			my ($x, $y) = unpack_region_target($packed);
			my $cell = "$x,$y";
			next if $used->{$cell};
			if ($blocked->{$cell}) { $failed++; }
			else { $unused++; }
		}
	}
	return ($unused, $failed);
}

sub failure_retry_wait_active {
	my $retry_after = $state{failed_retry_after} || 0;
	return 0 unless $retry_after > time();
	my ($unused, $failed) = pending_target_availability();
	return $failed > 0 && $unused == 0 ? 1 : 0;
}

sub release_failed_targets_if_due {
	my $retry_after = $state{failed_retry_after} || 0;
	return 0 if $retry_after > time();
	my $has_failed = 0;
	for my $targets (values %{$state{failed_targets_by_block} || {}}) {
		if (ref($targets) eq 'HASH' && keys %$targets) { $has_failed = 1; last; }
	}
	return 0 unless $has_failed;
	$state{failed_targets_by_block} = {};
	$state{failed_retry_after} = 0;
	for my $idx (keys %{$state{deferred_blocks}}) {
		delete $state{deferred_blocks}{$idx}
			if ($state{deferred_blocks}{$idx}{reason} || '') =~ /all remaining destinations failed/;
	}
	message "[lockMapSweep] Failed destinations are eligible for a controlled retry; coverage quotas remain pending.\n", 'route';
	return 1;
}

sub diagnose_failed_target_exhaustion {
	my $retry_after = $state{failed_retry_after} || (int(time()) + $FAILED_TARGET_RETRY_SECONDS);
	$state{failed_retry_after} = $retry_after;
	my $reason = "all remaining destinations failed; coverage is blocked until retry at $retry_after";
	my $changed = 0;
	for my $idx (0 .. $#{$state{bounds}}) {
		my $remaining = remaining_block_visits($idx);
		next unless $remaining > 0;
		my $old = $state{deferred_blocks}{$idx};
		next if $old && ($old->{reason} || '') eq $reason
			&& $old->{remaining} == $remaining && $old->{round} == $state{round_number};
		$state{deferred_blocks}{$idx} = {
			remaining => $remaining,
			round => $state{round_number},
			reason => $reason,
		};
		$changed = 1;
	}
	warning "[lockMapSweep] Coverage blocked: every unused destination has a failed route; quotas are retained and retry is scheduled after $retry_after.\n", 'route'
		if $changed;
	persist_state() if $changed && $state{ready};
}

sub block_visit_quota {
	my ($block_idx) = @_;
	my $block = $state{bounds}->[$block_idx] or return 0;
	my $eligible = $block->{walkable_count} || 0;
	return $eligible < $state{cells_per_block} ? $eligible : $state{cells_per_block};
}

sub remaining_block_visits {
	my ($block_idx) = @_;
	my $remaining = block_visit_quota($block_idx) - ($state{block_visit_counts}{$block_idx} || 0);
	return $remaining > 0 ? $remaining : 0;
}

sub coverage_round_is_complete {
	for my $idx (0 .. $#{$state{bounds}}) {
		return 0 if block_visit_quota($idx) && remaining_block_visits($idx) > 0;
	}
	return 1;
}

sub start_new_coverage_round {
	$state{round_number}++;
	$state{block_visit_counts} = {};
	set_current_block($state{current_block});
	$state{failed_retry_after} = 0;
	$state{visited_blocks_in_cycle} = {};
	$state{used_targets_by_block} = {};
	$state{failed_targets_by_block} = {};
	$state{deferred_blocks} = {};
	$state{last_block} = undef;
}

sub cell_route_costs_from {
	my ($origin, $max_cost) = @_;
	my ($costs) = cell_route_tree_from($origin, $max_cost, 0);
	return $costs;
}

sub cell_route_tree_from {
	my ($origin, $max_cost, $track_previous, $goal_bitmap, $goal_detour) = @_;
	$track_previous = 1 unless defined $track_previous;
	my %costs = ("$origin->{x},$origin->{y}" => 0);
	my $previous = $track_previous ? {} : undef;
	my $search_limit = $max_cost;
	my $nearest_goal_cost;
	my @queue = ({ x => $origin->{x}, y => $origin->{y} });
	my $head = 0;
	my @directions = ([-1, 0], [1, 0], [0, -1], [0, 1],
		[-1, -1], [1, -1], [-1, 1], [1, 1]);
	while ($head < @queue) {
		my $pos = $queue[$head++];
		my $next_cost = $costs{"$pos->{x},$pos->{y}"} + 1;
		last if defined $search_limit && $next_cost > $search_limit;
		for my $d (@directions) {
			my ($nx, $ny) = ($pos->{x} + $d->[0], $pos->{y} + $d->[1]);
			my $key = "$nx,$ny";
			next if exists $costs{$key};
			next unless is_cell_reachable($nx, $ny) && $field->isWalkable($nx, $ny);
			next unless $field->canMove($pos, { x => $nx, y => $ny });
			$costs{$key} = $next_cost;
			$previous->{$key} = "$pos->{x},$pos->{y}" if $track_previous;
			if (defined($goal_bitmap) && length($goal_bitmap)
				&& vec($goal_bitmap, $ny * $state{width} + $nx, 1)) {
				if (!defined $nearest_goal_cost) {
					$nearest_goal_cost = $next_cost;
					my $goal_limit = $next_cost + ($goal_detour || 0);
					$search_limit = $goal_limit
						if !defined($search_limit) || $goal_limit < $search_limit;
				}
			}
			push @queue, { x => $nx, y => $ny };
		}
	}
	return (\%costs, $previous, scalar @queue);
}

sub cell_route_tree_compact_from {
	my ($origin) = @_;
	my $width = $state{width};
	my $height = $state{height};
	my $cell_count = $width * $height;
	my $costs = "\0" x ($cell_count * 4);
	my $previous = "\0" x int(($cell_count + 1) / 2);
	my $origin_index = $origin->{y} * $width + $origin->{x};
	vec($costs, $origin_index, 32) = 1;
	my @queue = ($origin_index);
	my $head = 0;
	my @directions = ([-1, 0], [1, 0], [0, -1], [0, 1],
		[-1, -1], [1, -1], [-1, 1], [1, 1]);
	my @opposite_direction = (1, 0, 3, 2, 7, 6, 5, 4);
	while ($head < @queue) {
		my $index = $queue[$head++];
		my $x = $index % $width;
		my $y = int($index / $width);
		my $pos = { x => $x, y => $y };
		my $next_cost = vec($costs, $index, 32);
		for my $direction_index (0 .. $#directions) {
			my ($dx, $dy) = @{$directions[$direction_index]};
			my ($nx, $ny) = ($x + $dx, $y + $dy);
			next if $nx < 0 || $ny < 0 || $nx >= $width || $ny >= $height;
			my $next_index = $ny * $width + $nx;
			next if vec($costs, $next_index, 32);
			next unless is_cell_reachable($nx, $ny) && $field->isWalkable($nx, $ny);
			next unless $field->canMove($pos, { x => $nx, y => $ny });
			vec($costs, $next_index, 32) = $next_cost + 1;
			vec($previous, $next_index, 4) = $opposite_direction[$direction_index];
			push @queue, $next_index;
		}
	}
	return (\$costs, \$previous, scalar @queue);
}

sub route_cost_at {
	my ($costs, $x, $y) = @_;
	return undef unless defined $costs && defined $x && defined $y;
	if (ref($costs) eq 'SCALAR') {
		return undef if $x < 0 || $y < 0 || $x >= $state{width} || $y >= $state{height};
		my $encoded = vec($$costs, $y * $state{width} + $x, 32);
		return $encoded ? $encoded - 1 : undef;
	}
	return undef unless ref($costs) eq 'HASH';
	my $key = "$x,$y";
	return exists $costs->{$key} ? $costs->{$key} : undef;
}

sub reconstruct_cell_path {
	my ($origin_key, $destination_key, $previous) = @_;
	return () unless defined $origin_key && defined $destination_key;
	return reconstruct_compact_cell_path($origin_key, $destination_key, $previous)
		if ref($previous) eq 'SCALAR';
	return () unless ref($previous) eq 'HASH';
	my @reverse = ($destination_key);
	my $key = $destination_key;
	my %seen = ($key => 1);
	while ($key ne $origin_key) {
		$key = $previous->{$key};
		return () unless defined $key && !$seen{$key}++;
		push @reverse, $key;
	}
	return [map { [split /,/, $_, 2] } reverse @reverse];
}

sub reconstruct_compact_cell_path {
	my ($origin_key, $destination_key, $previous) = @_;
	my ($origin_x, $origin_y) = split /,/, $origin_key, 2;
	my ($x, $y) = split /,/, $destination_key, 2;
	my @reverse = ([int($x), int($y)]);
	my $origin_index = $origin_y * $state{width} + $origin_x;
	my $index = $y * $state{width} + $x;
	my $steps = 0;
	my @directions = ([-1, 0], [1, 0], [0, -1], [0, 1],
		[-1, -1], [1, -1], [-1, 1], [1, 1]);
	while ($index != $origin_index) {
		return () if ++$steps > $state{width} * $state{height};
		my $direction_index = vec($$previous, $index, 4);
		return () if $direction_index > $#directions;
		$x += $directions[$direction_index][0];
		$y += $directions[$direction_index][1];
		return () if $x < 0 || $y < 0 || $x >= $state{width} || $y >= $state{height};
		$index = $y * $state{width} + $x;
		push @reverse, [int($x), int($y)];
	}
	return [reverse @reverse];
}

sub region_graph_hops_from {
	my ($start_region_id, $regions) = @_;
	$regions ||= $state{regions};
	my %hops = ($start_region_id => 0);
	my @queue = ($start_region_id);
	my $head = 0;
	while ($head < @queue) {
		my $region_id = $queue[$head++];
		my $region = $regions->[$region_id] or next;
		for my $neighbor (keys %{$region->{neighbors} || {}}) {
			next if exists $hops{$neighbor};
			$hops{$neighbor} = $hops{$region_id} + 1;
			push @queue, $neighbor;
		}
	}
	return \%hops;
}

sub region_graph_costs_from {
	my ($start_region_id, $regions) = @_;
	$regions ||= $state{regions};
	return {} unless ref($regions) eq 'ARRAY' && $regions->[$start_region_id];
	my %costs = ($start_region_id => 0);
	my @heap = ([0, $start_region_id]);
	while (@heap) {
		my ($cost, $id) = heap_pop_min(\@heap);
		next if $costs{$id} < $cost;
		my $region = $regions->[$id] or next;
		for my $neighbor (keys %{$region->{weighted_neighbors} || {}}) {
			my $next_cost = $cost + $region->{weighted_neighbors}{$neighbor};
			next if defined $costs{$neighbor} && $costs{$neighbor} <= $next_cost;
			$costs{$neighbor} = $next_cost;
			heap_push_min(\@heap, [$next_cost, $neighbor]);
		}
	}
	return \%costs;
}

sub heap_push_min {
	my ($heap, $item) = @_;
	push @$heap, $item;
	my $index = $#$heap;
	while ($index > 0) {
		my $parent = int(($index - 1) / 2);
		last if $heap->[$parent][0] <= $item->[0];
		$heap->[$index] = $heap->[$parent];
		$index = $parent;
	}
	$heap->[$index] = $item;
}

sub heap_pop_min {
	my ($heap) = @_;
	my $minimum = $heap->[0];
	my $last = pop @$heap;
	if (@$heap) {
		my $index = 0;
		while (1) {
			my $left = 2 * $index + 1;
			last if $left > $#$heap;
			my $right = $left + 1;
			my $child = $right <= $#$heap && $heap->[$right][0] < $heap->[$left][0]
				? $right : $left;
			last if $heap->[$child][0] >= $last->[0];
			$heap->[$index] = $heap->[$child];
			$index = $child;
		}
		$heap->[$index] = $last;
	}
	return @$minimum;
}

sub choose_global_plan_first_region {
	my ($first_candidates, $first_probabilities) = @_;
	return undef unless @$first_candidates;
	my (%block_remaining, %target_remaining, %probability);
	for my $candidate (@$first_candidates) {
		$probability{$candidate->{region_id}} = $first_probabilities->{$candidate->{region_id}} || 0;
	}
	for my $idx (0 .. $#{$state{bounds}}) {
		$block_remaining{$idx} = remaining_block_visits($idx);
	}
	for my $region (@{$state{regions}}) {
		my $block = $state{bounds}[$region->{block_idx}] or next;
		my $block_key = block_key($block);
		my $available = 0;
		for my $cell (@{$region->{target_cells} || []}) {
			my ($cell_x, $cell_y) = unpack_region_target($cell);
			my $key = "$cell_x,$cell_y";
			$available++ unless $state{used_targets_by_block}{$block_key}{$key}
				|| $state{failed_targets_by_block}{$block_key}{$key};
		}
		$target_remaining{$region->{id}} = $available;
	}

	my %full_probability;
	for my $block_idx (0 .. $#{$state{bounds}}) {
		my @ids = @{$state{regions_by_block}{$block_idx} || []};
		my @region_records = map { $state{regions}[$_] } @ids;
		my $weighted = calculate_region_selection_weights(\@region_records, \%{$state{region_visit_history}});
		$full_probability{$_->{region_id}} = $_->{probability} for @$weighted;
	}

	my $remaining_obligations = 0;
	$remaining_obligations += $_ for values %block_remaining;
	my $lookahead = $remaining_obligations > 8 ? 7 : $remaining_obligations - 1;
	$lookahead = 0 if $lookahead < 0;
	my $plans = build_global_plan_beam(\@{$state{regions}}, \%block_remaining, \%target_remaining,
		$first_candidates, \%probability, \%full_probability, $lookahead);
	return undef unless @$plans;
	my %first_best;
	for my $plan (@$plans) {
		$first_best{$plan->{first_id}} = $plan->{score}
			if !defined($first_best{$plan->{first_id}}) || $plan->{score} < $first_best{$plan->{first_id}};
	}
	return undef unless %first_best;
	my $weighted = calculate_first_region_probabilities(\%first_best, $GLOBAL_PLAN_TEMPERATURE);
	my %candidate_by_id = map { $_->{region_id} => $_ } @$first_candidates;
	my %selection_probability = map { $_->{region_id} => $_->{probability} } @$weighted;
	for my $item (sort { $first_best{$a} <=> $first_best{$b} } keys %first_best) {
		my $candidate = $candidate_by_id{$item};
		my $priority_cost = $probability{$item} > 0
			? -$GLOBAL_PLAN_TEMPERATURE * log($probability{$item}) : 0;
		my $score = $first_best{$item};
		my $continuation = $score - ($candidate->{arrival_cost} || 0) - $priority_cost;
		debug sprintf("[lockMapSweep] Plan first=%d region=%s arrivalCost=%d continuationEstimate=%.1f coveragePriorityCost=%.1f score=%.1f selectionProbability=%.5f lookahead=%d beamWidth=48.\n",
			$item + 1, $candidate->{region_key}, $candidate->{arrival_cost}, $continuation,
			$priority_cost, $score, $selection_probability{$item} || 0,
			$lookahead), 'plugin', 2;
	}
	return sample_region_from_weights($weighted);
}

# Gibbs weighting keeps area/history probability proportional at equal cost;
# a full detour-window cost difference reduces odds by e^-1 without zeroing them.
sub calculate_first_region_probabilities {
	my ($score_by_region, $temperature) = @_;
	return [] unless ref($score_by_region) eq 'HASH' && %$score_by_region;
	$temperature = $GLOBAL_PLAN_TEMPERATURE
		unless defined $temperature && $temperature > 0;
	my $min_score;
	for my $score (values %$score_by_region) {
		$min_score = $score if !defined($min_score) || $score < $min_score;
	}
	my @weighted = map {
		+{ region_id => $_, log_weight => -($score_by_region->{$_} - $min_score) / $temperature }
	} sort { $a <=> $b } keys %$score_by_region;
	my $sum = 0;
	for my $item (@weighted) {
		$item->{weight} = exp($item->{log_weight});
		$sum += $item->{weight};
	}
	$_->{probability} = $_->{weight} / $sum for @weighted;
	return \@weighted;
}

sub build_global_plan_beam {
	my ($regions, $block_remaining, $target_remaining, $first_candidates,
		$first_probabilities, $future_probabilities, $depth) = @_;
	return [] unless ref($regions) eq 'ARRAY' && ref($block_remaining) eq 'HASH'
		&& ref($target_remaining) eq 'HASH' && ref($first_candidates) eq 'ARRAY'
		&& ref($first_probabilities) eq 'HASH' && ref($future_probabilities) eq 'HASH';
	$depth = 4 unless defined $depth && $depth =~ /^\d+$/;
	my @beam;
	for my $candidate (@$first_candidates) {
		my $p = $first_probabilities->{$candidate->{region_id}} || 0;
		next unless $p > 0;
		my %remaining = %$block_remaining;
		$remaining{$candidate->{block_idx}}--;
		my %available = %$target_remaining;
		$available{$candidate->{region_id}}--;
		push @beam, {
			first_id => $candidate->{region_id},
			last_id => $candidate->{region_id},
			remaining => \%remaining,
			available => \%available,
			sequence => [$candidate->{region_id}],
			score => $candidate->{arrival_cost} - $GLOBAL_PLAN_TEMPERATURE * log($p),
		};
	}
	return [] unless @beam;
	@beam = sort { $a->{score} <=> $b->{score} } @beam;
	splice(@beam, 48) if @beam > 48;

	# The bounded beam compares future coverage obligations. First-leg costs are
	# exact movement-rule costs; continuation costs use movement-weighted region
	# graph distances between representative points. OpenKore still executes and
	# confirms each destination route independently.
	for (1 .. $depth) {
		my @expanded;
		for my $state (@beam) {
			my $route_costs = region_graph_costs_from($state->{last_id}, $regions);
			my @choices;
			for my $region (@$regions) {
				my $block_idx = $region->{block_idx};
				next unless ($state->{remaining}{$block_idx} || 0) > 0;
				next unless ($state->{available}{$region->{id}} || 0) > 0;
			next unless defined $route_costs->{$region->{id}};
				my $p = $future_probabilities->{$region->{id}} || 0;
				next unless $p > 0;
				my $travel = $route_costs->{$region->{id}};
				# A second obligation in one component starts from an unknown target
				# cell, so retain a conservative service movement estimate.
				$travel += sqrt($region->{eligible_count} || 1) / 2
					if $region->{id} == $state->{last_id};
				push @choices, { region_id => $region->{id}, block_idx => $block_idx,
					cost => $travel - $GLOBAL_PLAN_TEMPERATURE * log($p) };
			}
			@choices = sort { $a->{cost} <=> $b->{cost} } @choices;
			splice(@choices, 12) if @choices > 12;
			if (!@choices) {
				push @expanded, $state;
				next;
			}
			for my $choice (@choices) {
				my %remaining = %{$state->{remaining}};
				my %available = %{$state->{available}};
				$remaining{$choice->{block_idx}}--;
				$available{$choice->{region_id}}--;
				push @expanded, {
					first_id => $state->{first_id},
					last_id => $choice->{region_id},
					remaining => \%remaining,
					available => \%available,
					sequence => [@{$state->{sequence}}, $choice->{region_id}],
					score => $state->{score} + $choice->{cost},
				};
			}
		}
		last unless @expanded;
		@expanded = sort { $a->{score} <=> $b->{score} } @expanded;
		my (%kept, @next_beam);
		for my $item (@expanded) {
			next if ($kept{$item->{first_id}} || 0) >= 4;
			$kept{$item->{first_id}}++;
			push @next_beam, $item;
			last if @next_beam >= 48;
		}
		@beam = @next_beam;
	}
	return \@beam;
}

sub pick_random_walkable_in_block {
	my ($block_idx, $block, $from, $from_block_idx) = @_;
	return undef unless $block && $from;
	my $block_key = block_key($block);
	$state{used_targets_by_block}{$block_key} ||= {};
	$state{failed_targets_by_block}{$block_key} ||= {};
	my $used = $state{used_targets_by_block}{$block_key};
	my $failed = $state{failed_targets_by_block}{$block_key};
	my @candidates;
	for my $y ($block->{min_y} .. $block->{max_y}) {
		for my $x ($block->{min_x} .. $block->{max_x}) {
			next unless is_cell_eligible($x, $y);
			my $key = "$x,$y";
			next if $used->{$key} || $failed->{$key};
			next if $x == $from->{x} && $y == $from->{y};
			push @candidates, { x => $x, y => $y };
		}
	}
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
	set_current_block(pick_next_block($block_idx));
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
	start_new_coverage_round() if coverage_round_is_complete();
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
	return undef unless is_cell_reachable($x, $y);
	return block_index_for_cell($x, $y);
}

sub block_index_for_cell {
	my ($x, $y) = @_;
	return undef unless defined $x && defined $y && $state{blocks_x} > 0 && $state{blocks_y} > 0;
	return undef if $x < $state{walk_min_x} || $x > $state{walk_max_x}
		|| $y < $state{walk_min_y} || $y > $state{walk_max_y};
	my $walk_width = $state{walk_max_x} - $state{walk_min_x} + 1;
	my $walk_height = $state{walk_max_y} - $state{walk_min_y} + 1;
	return undef if $walk_width <= 0 || $walk_height <= 0;
	my $bx = int((($x - $state{walk_min_x} + 1) * $state{blocks_x} - 1) / $walk_width);
	my $by = int((($y - $state{walk_min_y} + 1) * $state{blocks_y} - 1) / $walk_height);
	return undef if $bx < 0 || $bx >= $state{blocks_x} || $by < 0 || $by >= $state{blocks_y};
	return block_grid_to_index($bx, $by);
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
		message "[lockMapSweep] Status command received.\n", 'plugin';
		my $visited_blocks = scalar keys %{$state{visited_blocks_in_cycle}};
		my $remaining_visits = 0;
		$remaining_visits += remaining_block_visits($_) for 0 .. $#{$state{bounds}};
		my $pending = $state{pending_target}
			? "$state{pending_target}{x},$state{pending_target}{y}"
			: 'none';
		message sprintf("[lockMapSweep] ready=%d map=%s round=%d block=%d/%d visit=%d/%d visitedBlocks=%d remainingVisits=%d deferredBlocks=%d\n",
			$state{ready} ? 1 : 0,
			($state{last_lock_map} || '-'),
			$state{round_number} || 0,
			$state{current_block} + 1,
			($state{block_count} || 0),
			$state{visits_in_block},
			($state{cells_per_block} || 0),
			$visited_blocks,
			$remaining_visits,
			scalar keys %{$state{deferred_blocks}}
		), 'info';
		message "[lockMapSweep] pending=$pending\n", 'info';
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
	return File::Spec->catfile($dir, $safe_map . "_${bx}x${by}_c${cells}_v6.state");
}

sub load_state_from_file {
	return 0 unless should_use_state_file();
	return 0 unless $state{state_file};

	my $source_file = $state{state_file};
	unless (-f $source_file) {
		(my $legacy = $source_file) =~ s/_v6\.state$/_v5.state/;
		return 0 unless -f $legacy;
		$source_file = $legacy;
	}
	return 0 unless -f $source_file;
	open my $fh, '<', $source_file or return 0;
	my @lines = <$fh>;
	close $fh;

	my (%meta, %bounds, %visited_blocks, %used_targets, %failed_targets,
		%round_visits, %region_visits, %deferred, $pending);
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
		} elsif ($line =~ /^round_visit\t(\d+)\t(\d+)$/) {
			return 0 if exists $round_visits{$1};
			$round_visits{$1} = int($2);
		} elsif ($line =~ /^region_visit\t([^\t]+)\t(\d+)$/) {
			return 0 if exists $region_visits{$1};
			$region_visits{$1} = int($2);
		} elsif ($line =~ /^deferred\t(\d+)\t(\d+)\t(\d+)\t([^\t]*)$/) {
			return 0 if exists $deferred{$1};
			$deferred{$1} = { remaining => int($2), round => int($3), reason => $4 };
		} elsif ($line =~ /^target\t(\d+)\t(\d+)\t(\d+)$/) {
			my ($idx, $x, $y) = ($1, $2, $3);
			return 0 if $used_targets{$idx}{"$x,$y"}++;
		} elsif ($line =~ /^failed\t(\d+)\t(\d+)\t(\d+)$/) {
			my ($idx, $x, $y) = ($1, $2, $3);
			return 0 if $failed_targets{$idx}{"$x,$y"}++;
		} elsif ($line =~ /^pending\t(\d+)\t(\d+)\t(\d+)\t([^\t]+)(?:\t([01]))?$/) {
			return 0 if $pending;
			$pending = { block_idx => int($1), x => int($2), y => int($3),
				region_key => $4, transit => defined $5 ? int($5) : 0 };
		} else {
			return 0;
		}
	}

	return 0 unless $meta{version} && $meta{version} =~ /^(?:5|6)$/;
	return 0 if defined $meta{failed_retry_after}
		&& ($meta{failed_retry_after} !~ /^\d{1,11}$/ || $meta{failed_retry_after} > 4_102_444_800);
	return 0 if ($meta{failed_retry_after} || 0) && !keys %failed_targets;
	return 0 if $meta{version} eq '5' && $pending && $pending->{transit};
	return 0 unless $meta{map} && $meta{map} eq $state{last_lock_map};
	return 0 unless defined $meta{width} && $meta{width} == $state{width};
	return 0 unless defined $meta{height} && $meta{height} == $state{height};
	return 0 unless defined $meta{blocks_x} && $meta{blocks_x} == $state{blocks_x};
	return 0 unless defined $meta{blocks_y} && $meta{blocks_y} == $state{blocks_y};
	return 0 unless defined $meta{cells_per_block} && $meta{cells_per_block} == $state{cells_per_block};
	return 0 unless defined $meta{geometry} && $meta{geometry} eq $state{geometry_signature};
	return 0 unless defined $meta{current_block} && $meta{current_block} =~ /^\d+$/ && $meta{current_block} < $state{block_count};
	return 0 unless defined $meta{visits_in_block} && $meta{visits_in_block} =~ /^\d+$/;
	return 0 unless defined $meta{round_number} && $meta{round_number} =~ /^\d+$/ && $meta{round_number} > 0;
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
		my $eligible_count = 0;
		for my $y ($saved->{min_y} .. $saved->{max_y}) {
			for my $x ($saved->{min_x} .. $saved->{max_x}) {
				$eligible_count++ if is_cell_eligible($x, $y);
			}
		}
		return 0 unless $eligible_count == $saved->{walkable_count};
		$restored_bounds[$idx] = { %$saved };
	}
	for my $idx (keys %visited_blocks) {
		return 0 if $idx >= $state{block_count} || !$restored_bounds[$idx]{walkable_count};
	}
	my %valid_region_keys = map { $_->{key} => $_ } @{$state{regions}};
	for my $key (keys %region_visits) {
		return 0 unless exists $valid_region_keys{$key} && $region_visits{$key} =~ /^\d+$/;
	}
	for my $idx (keys %round_visits) {
		return 0 if $idx >= $state{block_count};
		my $eligible = $restored_bounds[$idx]{walkable_count} || 0;
		my $quota = $eligible < $state{cells_per_block} ? $eligible : $state{cells_per_block};
		return 0 if $round_visits{$idx} > $quota;
	}
	for my $idx (keys %deferred) {
		return 0 if $idx >= $state{block_count};
		return 0 if $deferred{$idx}{remaining} <= 0 || $deferred{$idx}{round} != $meta{round_number};
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
		my $region_id = region_id_at($pending->{x}, $pending->{y});
		return 0 unless defined $region_id && $state{regions}[$region_id]{key} eq $pending->{region_key};
		return 0 unless $state{regions}[$region_id]{block_idx} == $pending->{block_idx};
	}
	my $current_visits = $round_visits{$meta{current_block}} || 0;
	return 0 unless $meta{visits_in_block} == $current_visits;
	my $block = $restored_bounds[$meta{current_block}];
	my $quota = $block->{walkable_count} || 0;
	$quota = $state{cells_per_block} if $quota > $state{cells_per_block};
	return 0 if $current_visits > $quota;

	$state{block_visit_counts} = \%round_visits;
	set_current_block(int($meta{current_block}));
	$state{bounds} = \@restored_bounds;
	$state{walk_min_x} = int($meta{walk_min_x});
	$state{walk_max_x} = int($meta{walk_max_x});
	$state{walk_min_y} = int($meta{walk_min_y});
	$state{walk_max_y} = int($meta{walk_max_y});
	$state{visited_blocks_in_cycle} = \%visited_blocks;
	$state{round_number} = int($meta{round_number});
	$state{failed_retry_after} = int($meta{failed_retry_after} || 0);
	$state{region_visit_history} = \%region_visits;
	$state{deferred_blocks} = \%deferred;
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
	return 0 unless set_current_block($state{current_block});
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
		print {$fh} "meta\tversion\t6\n";
		print {$fh} "meta\tmap\t$state{last_lock_map}\n";
		print {$fh} "meta\twidth\t$state{width}\n";
		print {$fh} "meta\theight\t$state{height}\n";
		print {$fh} "meta\tblocks_x\t$state{blocks_x}\n";
		print {$fh} "meta\tblocks_y\t$state{blocks_y}\n";
		print {$fh} "meta\tcells_per_block\t$state{cells_per_block}\n";
		print {$fh} "meta\tgeometry\t$state{geometry_signature}\n";
		print {$fh} "meta\tcurrent_block\t$state{current_block}\n";
		print {$fh} "meta\tvisits_in_block\t$state{visits_in_block}\n";
		print {$fh} "meta\tfailed_retry_after\t" . ($state{failed_retry_after} || 0) . "\n";
		print {$fh} "meta\tround_number\t$state{round_number}\n";
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
		for my $idx (sort { $a <=> $b } keys %{$state{block_visit_counts}}) {
			print {$fh} "round_visit\t$idx\t$state{block_visit_counts}{$idx}\n";
		}
		for my $key (sort keys %{$state{region_visit_history}}) {
			print {$fh} "region_visit\t$key\t$state{region_visit_history}{$key}\n";
		}
		for my $idx (sort { $a <=> $b } keys %{$state{deferred_blocks}}) {
			my $deferred = $state{deferred_blocks}{$idx};
			my $reason = $deferred->{reason} || '';
			$reason =~ s/[\t\r\n]/ /g;
			print {$fh} "deferred\t$idx\t$deferred->{remaining}\t$deferred->{round}\t$reason\n";
		}
		if (my $pending = $state{pending_target}) {
			my $transit_flag = $pending->{transit} ? "\t1" : '';
			print {$fh} "pending\t$pending->{block_idx}\t$pending->{x}\t$pending->{y}\t$pending->{region_key}$transit_flag\n";
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
