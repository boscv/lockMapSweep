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
use Utils::PathFinding;
use File::Spec;
use File::Path qw(make_path);

Plugins::register('lockMapSweep', 'Smart lockMap block sweep randomWalk override', \&on_unload, \&on_unload);

my $hooks = Plugins::addHooks(
	['postloadfiles', \&on_postloadfiles],
	['configModify', \&on_config_modify],
	['ai_processRandomWalk', \&on_ai_process_random_walk],
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
	);

	return unless $watched{$args->{key}};
	initialize_or_reload();
}

sub on_ai_process_random_walk {
	my (undef, $args) = @_;
	return unless $args;
	return unless is_enabled();
	return unless $char;
	return unless $field;
	return unless $config{lockMap};
	return unless $field->baseName eq $config{lockMap};

	if (!is_state_compatible()) {
		initialize_or_reload();
	}

	if (!$state{ready}) {
		warning "[lockMapSweep] State is not ready, falling back to default randomWalk.\n", 'system';
		return;
	}

	my $target = pick_target_in_current_plan();
	if (!$target) {
		warning "[lockMapSweep] Unable to find a valid target in planned blocks, falling back to default randomWalk.\n", 'system';
		return;
	}

	$args->{return} = 1;
	message sprintf("[lockMapSweep] Calculating sweep route to block %d: %d, %d\n", $state{current_block}, $target->{x}, $target->{y}), 'route';
	ai_route(
		$field->baseName,
		$target->{x},
		$target->{y},
		maxRouteTime => $config{route_randomWalk_maxRouteTime},
		attackOnRoute => (defined $config{attackAuto}) ? $config{attackAuto} : 2,
		noMapRoute => ($config{route_randomWalk} == 2 ? 1 : 0),
		isRandomWalk => 1
	);

	advance_plan();
	persist_state();
}

sub is_enabled {
	return ($config{lockMapSweep_enabled} && $config{lockMapSweep_enabled} =~ /^1$/) ? 1 : 0;
}

sub initialize_or_reload {
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
	);

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
		return;
	}

	$state{width} = $lock_field->width;
	$state{height} = $lock_field->height;
	$state{reachable_lookup} = build_reachable_lookup($lock_field);
	if (!%{$state{reachable_lookup}}) {
		error "[lockMapSweep] No reachable walkable cells found on lockMap.\n";
		return;
	}

	set_walkable_bounds_from_lookup();

	my $loaded_state = load_state_from_file();
	if ($loaded_state) {
		# Always refresh walkable_count against current reachable component.
		recompute_block_reachable_counts($lock_field);
		$state{ready} = 1;
		$state{used_targets_by_block} = {};
		$state{visited_blocks_in_cycle} = {};
		build_block_index_lookup();
		persist_state();
		message "[lockMapSweep] Loaded block plan from state file.\n", 'success';
		return;
	}

	unless (build_block_plan($lock_field)) {
		error "[lockMapSweep] Failed to build lockMap block plan.\n";
		return;
	}

	$state{ready} = 1;
	$state{used_targets_by_block} = {};
	$state{visited_blocks_in_cycle} = {};
	build_block_index_lookup();
	persist_state();
	message sprintf("[lockMapSweep] Built lockMap plan for %s (%dx%d blocks, %d cells per block).\n", $lock_map, $blocks_x, $blocks_y, $cells_per_block), 'success';
}

sub is_state_compatible {
	return 0 unless $state{ready};
	return 0 unless $state{last_lock_map} && $config{lockMap} && $state{last_lock_map} eq $config{lockMap};
	return 0 unless $state{blocks_x} == positive_int_or_default($config{lockMapSweep_blocksX}, 2);
	return 0 unless $state{blocks_y} == positive_int_or_default($config{lockMapSweep_blocksY}, 2);
	return 0 unless $state{cells_per_block} == positive_int_or_default($config{lockMapSweep_cellsPerBlock}, 3);
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

			my $walkable_count = 0;
			for my $y ($min_y .. $max_y) {
				for my $x ($min_x .. $max_x) {
					next if $x == 0 || $y == 0;
					next unless is_cell_reachable($x, $y);
					$walkable_count++;
				}
			}

			push @{ $state{bounds} }, {
				min_x => $min_x,
				max_x => $max_x,
				min_y => $min_y,
				max_y => $max_y,
				walkable_count => $walkable_count,
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

sub recompute_block_reachable_counts {
	my ($lock_field) = @_;
	return unless $lock_field;
	for my $b (@{$state{bounds}}) {
		next unless $b;
		my $count = 0;
		for my $y ($b->{min_y} .. $b->{max_y}) {
			for my $x ($b->{min_x} .. $b->{max_x}) {
				next if $x == 0 || $y == 0;
				next unless is_cell_reachable($x, $y);
				$count++;
			}
		}
		$b->{walkable_count} = $count;
	}
}

sub build_reachable_lookup {
	my ($lock_field) = @_;
	my %visited;
	my %best_component;
	my $best_size = 0;

	for my $y (1 .. $lock_field->height - 1) {
		for my $x (1 .. $lock_field->width - 1) {
			my $k = "$x,$y";
			next if $visited{$k};
			next unless $lock_field->isWalkable($x, $y);

			my @queue = ({ x => $x, y => $y });
			my %component;
			$visited{$k} = 1;
			$component{$k} = 1;

			while (@queue) {
				my $p = shift @queue;
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
					$visited{$nk} = 1;
					$component{$nk} = 1;
					push @queue, { x => $nx, y => $ny };
				}
			}

			my $size = scalar keys %component;
			if ($size > $best_size) {
				$best_size = $size;
				%best_component = %component;
			}
		}
	}

	return \%best_component;
}

sub is_cell_reachable {
	my ($x, $y) = @_;
	return 0 unless defined $x && defined $y;
	return exists $state{reachable_lookup}{"$x,$y"} ? 1 : 0;
}

sub pick_target_in_current_plan {
	return undef unless $state{block_count};

	my $tries_blocks = $state{block_count};
	while ($tries_blocks-- > 0) {
		my $block = $state{bounds}->[$state{current_block}];
		if ($block && $block->{walkable_count} > 0) {
			my $must_stay_in_block = ($state{visits_in_block} > 0) ? 1 : 0;
			my $target = pick_random_walkable_in_block($state{current_block}, $block, $must_stay_in_block);
			return $target if $target;
		}
		$state{current_block} = pick_next_block($state{current_block});
		$state{visits_in_block} = 0;
	}

	return undef;
}

sub pick_random_walkable_in_block {
	my ($block_idx, $block, $must_stay_in_block) = @_;
	return undef unless $block;

	my $tries = 300;
	my $block_key = sprintf('%d:%d:%d:%d', $block->{min_x}, $block->{max_x}, $block->{min_y}, $block->{max_y});
	$state{used_targets_by_block}{$block_key} ||= {};
	my $used = $state{used_targets_by_block}{$block_key};

	my $from = $state{last_target};
	if (!$must_stay_in_block && $from && defined $state{last_block}) {
		my $target = pick_transition_target_in_block($from, $state{last_block}, $block_idx, $block, $used);
		if ($target) {
			$used->{"$target->{x},$target->{y}"} = 1;
			$state{last_target} = { x => $target->{x}, y => $target->{y} };
			$state{last_block} = $block_idx;
			return $target;
		}
		return undef;
	}

	while ($tries-- > 0) {
		my $x = $block->{min_x} + int(rand($block->{max_x} - $block->{min_x} + 1));
		my $y = $block->{min_y} + int(rand($block->{max_y} - $block->{min_y} + 1));
		my $cell_key = "$x,$y";
		next if $x == 0 || $y == 0;
		next if $used->{$cell_key};
		next unless is_cell_reachable($x, $y);
		next unless $field->isWalkable($x, $y);

		if ($state{last_target} && $state{last_target}{x} == $x && $state{last_target}{y} == $y) {
			next;
		}

		if ($must_stay_in_block) {
			my $from = $state{last_target};
			next unless $from;
			next unless path_exists_within_block($from, { x => $x, y => $y }, $block);
		}

		$used->{$cell_key} = 1;
		$state{last_target} = { x => $x, y => $y };
		$state{last_block} = $block_idx;
		return { x => $x, y => $y };
	}

	return undef;
}

sub pick_transition_target_in_block {
	my ($from, $from_block_idx, $to_block_idx, $to_block, $used) = @_;
	return undef unless defined $from && defined $to_block;

	my %allowed = (
		$from_block_idx => 1,
		$to_block_idx => 1,
	);

	my @queue = ($from);
	my %visited = ("$from->{x},$from->{y}" => 1);
	my @candidates;

	while (@queue) {
		my $p = shift @queue;
		my $idx = coord_to_block_index($p->{x}, $p->{y});
		if (defined $idx && $idx == $to_block_idx) {
			my $k = "$p->{x},$p->{y}";
			if (!$used->{$k} && ($p->{x} != $from->{x} || $p->{y} != $from->{y})) {
				push @candidates, { x => $p->{x}, y => $p->{y} };
			}
		}

		for my $d ([-1,0], [1,0], [0,-1], [0,1], [-1,-1], [1,-1], [-1,1], [1,1]) {
			my $nx = $p->{x} + $d->[0];
			my $ny = $p->{y} + $d->[1];
			next if $nx <= 0 || $ny <= 0;
			next if $nx >= $state{width} || $ny >= $state{height};
			next unless is_cell_reachable($nx, $ny);
			next unless $field->isWalkable($nx, $ny);

			my $nidx = coord_to_block_index($nx, $ny);
			next unless defined $nidx && $allowed{$nidx};

			my $k = "$nx,$ny";
			next if $visited{$k};
			$visited{$k} = 1;
			push @queue, { x => $nx, y => $ny };
		}
	}

	return undef unless @candidates;
	return $candidates[int(rand(@candidates))];
}

sub transition_path_is_valid {
	my ($from, $to, $from_block_idx, $to_block_idx) = @_;
	return 1 if !defined $from_block_idx || !defined $to_block_idx;
	return 0 unless defined $from && defined $to;

	my %allowed = (
		$from_block_idx => 1,
		$to_block_idx => 1,
	);
	return path_exists_with_allowed_blocks($from, $to, \%allowed);
}

sub path_exists_with_allowed_blocks {
	my ($from, $to, $allowed_blocks) = @_;
	return 0 unless $from && $to && $allowed_blocks;

	my $from_idx = coord_to_block_index($from->{x}, $from->{y});
	my $to_idx = coord_to_block_index($to->{x}, $to->{y});
	return 0 unless defined $from_idx && defined $to_idx;
	return 0 unless $allowed_blocks->{$from_idx} && $allowed_blocks->{$to_idx};

	my @queue = ($from);
	my %visited = ("$from->{x},$from->{y}" => 1);

	while (@queue) {
		my $p = shift @queue;
		return 1 if $p->{x} == $to->{x} && $p->{y} == $to->{y};

		for my $d ([-1,0], [1,0], [0,-1], [0,1], [-1,-1], [1,-1], [-1,1], [1,1]) {
			my $nx = $p->{x} + $d->[0];
			my $ny = $p->{y} + $d->[1];
			next if $nx <= 0 || $ny <= 0;
			next if $nx >= $state{width} || $ny >= $state{height};
			next unless is_cell_reachable($nx, $ny);
			next unless $field->isWalkable($nx, $ny);

			my $idx = coord_to_block_index($nx, $ny);
			next unless defined $idx && $allowed_blocks->{$idx};

			my $k = "$nx,$ny";
			next if $visited{$k};
			$visited{$k} = 1;
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
	if ($state{visits_in_block} >= $state{cells_per_block}) {
		if (defined $state{bounds}->[$current_block]) {
			my $b = $state{bounds}->[$current_block];
			my $block_key = sprintf('%d:%d:%d:%d', $b->{min_x}, $b->{max_x}, $b->{min_y}, $b->{max_y});
			delete $state{used_targets_by_block}{$block_key};
		}

		$state{visited_blocks_in_cycle}{$current_block} = 1;
		$state{last_block} = $current_block;
		$state{visits_in_block} = 0;
		$state{current_block} = pick_next_block($current_block);
	}
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
			unlink $state{state_file};
			message "[lockMapSweep] State file removed.\n", 'success';
		} else {
			warning "[lockMapSweep] No state file to remove.\n", 'system';
		}
		return;
	}

	if ($command eq 'rebuild') {
		if ($state{state_file} && -f $state{state_file}) {
			unlink $state{state_file};
		}
		initialize_or_reload();
		message "[lockMapSweep] State rebuilt from current lockMap/config.\n", 'success';
		return;
	}

	warning "[lockMapSweep] Usage: lockMapSweep [status|rebuild|clearstate]\n", 'system';
}

sub build_state_file_path {
	my ($map, $bx, $by) = @_;
	my $dir = $config{lockMapSweep_stateDir} || File::Spec->catdir('plugins', 'lockMapSweep', 'state');
	my $safe_map = $map;
	$safe_map =~ s/[^A-Za-z0-9_\-\@]/_/g;
	return File::Spec->catfile($dir, $safe_map . "_${bx}x${by}.state");
}

sub load_state_from_file {
	return 0 unless should_use_state_file();
	return 0 unless $state{state_file};
	return 0 unless -f $state{state_file};

	open my $fh, '<', $state{state_file} or return 0;
	my @lines = <$fh>;
	close $fh;

	my %meta;
	my @bounds;
	for my $line (@lines) {
		chomp $line;
		next if $line =~ /^\s*$/;
		if ($line =~ /^meta\t([^\t]+)\t(.*)$/) {
			$meta{$1} = $2;
		} elsif ($line =~ /^block\t(\d+)\t(\d+)\t(\d+)\t(\d+)\t(\d+)\t(\d+)$/) {
			$bounds[$1] = {
				min_x => $2,
				max_x => $3,
				min_y => $4,
				max_y => $5,
				walkable_count => $6,
			};
		}
	}

	return 0 unless $meta{version} && $meta{version} eq '2';
	return 0 unless $meta{map} && $meta{map} eq $state{last_lock_map};
	return 0 unless $meta{blocks_x} && $meta{blocks_x} == $state{blocks_x};
	return 0 unless $meta{blocks_y} && $meta{blocks_y} == $state{blocks_y};
	return 0 unless @bounds == $state{block_count};

	$state{width} = int($meta{width} || 0);
	$state{height} = int($meta{height} || 0);
	$state{cells_per_block} = int($meta{cells_per_block} || $state{cells_per_block});
	$state{current_block} = int($meta{current_block} || 0);
	$state{visits_in_block} = int($meta{visits_in_block} || 0);
	$state{current_block} = 0 if $state{current_block} >= $state{block_count};
	$state{visits_in_block} = 0 if $state{visits_in_block} >= $state{cells_per_block};
	$state{bounds} = \@bounds;
	$state{walk_min_x} = int($meta{walk_min_x} || 0);
	$state{walk_max_x} = int($meta{walk_max_x} || 0);
	$state{walk_min_y} = int($meta{walk_min_y} || 0);
	$state{walk_max_y} = int($meta{walk_max_y} || 0);
	$state{last_block} = undef;

	return 1;
}

sub persist_state {
	return 1 unless should_use_state_file();
	return 0 unless $state{state_file};

	my (undef, $dir) = File::Spec->splitpath($state{state_file});
	if ($dir && !-d $dir) {
		make_path($dir);
	}

	open my $fh, '>', $state{state_file} or do {
		warning "[lockMapSweep] Failed to write state file: $state{state_file}\n", 'system';
		return 0;
	};

	print {$fh} "meta\tversion\t2\n";
	print {$fh} "meta\tmap\t$state{last_lock_map}\n";
	print {$fh} "meta\twidth\t$state{width}\n";
	print {$fh} "meta\theight\t$state{height}\n";
	print {$fh} "meta\tblocks_x\t$state{blocks_x}\n";
	print {$fh} "meta\tblocks_y\t$state{blocks_y}\n";
	print {$fh} "meta\tcells_per_block\t$state{cells_per_block}\n";
	print {$fh} "meta\tcurrent_block\t$state{current_block}\n";
	print {$fh} "meta\tvisits_in_block\t$state{visits_in_block}\n";
	print {$fh} "meta\twalk_min_x\t$state{walk_min_x}\n";
	print {$fh} "meta\twalk_max_x\t$state{walk_max_x}\n";
	print {$fh} "meta\twalk_min_y\t$state{walk_min_y}\n";
	print {$fh} "meta\twalk_max_y\t$state{walk_max_y}\n";

	for my $idx (0 .. $#{$state{bounds}}) {
		my $b = $state{bounds}->[$idx];
		print {$fh} join("\t", 'block', $idx, $b->{min_x}, $b->{max_x}, $b->{min_y}, $b->{max_y}, $b->{walkable_count}) . "\n";
	}

	close $fh;
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