#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

BEGIN {
	package Plugins;
	sub import {}
	sub register {}
	sub addHooks { return [] }
	sub delHooks {}
	sub callHook {}
	$INC{'Plugins.pm'} = __FILE__;
 package Commands;
	sub import {}
	sub register { return [] }
	sub unregister {}
	$INC{'Commands.pm'} = __FILE__;
 package Globals;
	our (%config, $field, $char);
	sub import { my $c = caller; no strict 'refs'; *{"${c}::config"}=\%config; *{"${c}::field"}=\$field; *{"${c}::char"}=\$char; }
	$INC{'Globals.pm'} = __FILE__;
 package Log;
	sub import { my $c=caller; no strict 'refs'; for my $n(qw(message warning error debug)){ *{"${c}::$n"}=__PACKAGE__->can($n) } }
	sub message {} sub warning {} sub error {} sub debug {}
	$INC{'Log.pm'} = __FILE__;
 package AI;
	sub import { my $c=caller; no strict 'refs'; *{"${c}::ai_route"}=\&ai_route }
	sub ai_route {}
	$INC{'AI.pm'} = __FILE__;
 package Field; sub import {} $INC{'Field.pm'} = __FILE__;
 package Utils;
	sub import { my $c=caller; no strict 'refs'; *{"${c}::actorFinishedMovement"}=\&actorFinishedMovement }
	sub actorFinishedMovement { 0 }
	$INC{'Utils.pm'} = __FILE__;
 package Utils::PathFinding; $INC{'Utils/PathFinding.pm'} = __FILE__;
}

require "$ENV{LOCKMAPSWEEP_PLUGIN}";

# B -> lower -> A -> continuation, with the lower block needing two visits.
my $regions = [
	{ id => 0, block_idx => 0, cell_count => 1, neighbors => { 1 => 1 }, weighted_neighbors => { 1 => 1 } }, # B
	{ id => 1, block_idx => 1, cell_count => 1, neighbors => { 0 => 1, 2 => 1 }, weighted_neighbors => { 0 => 1, 2 => 1 } }, # lower
	{ id => 2, block_idx => 0, cell_count => 1, neighbors => { 1 => 1, 3 => 1 }, weighted_neighbors => { 1 => 1, 3 => 1 } }, # A
	{ id => 3, block_idx => 2, cell_count => 1, neighbors => { 2 => 1 }, weighted_neighbors => { 2 => 1 } }, # continuation
];
my $first_candidates = [
	{ region_id => 0, block_idx => 0, arrival_cost => 0 },
	{ region_id => 1, block_idx => 1, arrival_cost => 1 },
	{ region_id => 2, block_idx => 0, arrival_cost => 2 },
	{ region_id => 3, block_idx => 2, arrival_cost => 3 },
];
my $plans = lockMapSweep::build_global_plan_beam(
	$regions,
	{ 0 => 2, 1 => 2, 2 => 1 },
	{ 0 => 1, 1 => 2, 2 => 1, 3 => 1 },
	$first_candidates,
	{ 0 => 0.5, 1 => 1, 2 => 0.5, 3 => 1 },
	{ 0 => 0.5, 1 => 1, 2 => 0.5, 3 => 1 },
	4,
);
my ($best) = sort { $a->{score} <=> $b->{score} }
	grep { $_->{first_id} == 0 } @$plans;
ok($best, 'bounded global lookahead produces a continuation plan from region B');
is_deeply($best->{sequence}, [0, 1, 1, 2, 3],
	'global plan keeps the lower-block quota non-consecutive and reaches A before continuing');
is(scalar(grep { $_ == 1 } @{$best->{sequence}}), 2,
	'leaving and re-entering the original block does not erase the lower block remaining quota');

# The first region is cheap to reach but is a dead end relative to the next
# obligations. A slightly farther arrival enables a shorter total sequence.
my $departure_regions = [
	{ id => 0, block_idx => 0, cell_count => 10_000, neighbors => { 2 => 1 }, weighted_neighbors => { 2 => 10 } },
	{ id => 1, block_idx => 0, cell_count => 1, neighbors => { 2 => 1 }, weighted_neighbors => { 2 => 1 } },
	{ id => 2, block_idx => 1, cell_count => 1, neighbors => { 0 => 1, 1 => 1 }, weighted_neighbors => { 0 => 10, 1 => 1 } },
];
my $departure_plans = lockMapSweep::build_global_plan_beam(
	$departure_regions,
	{ 0 => 1, 1 => 1 },
	{ 0 => 1, 1 => 1, 2 => 1 },
	[{ region_id => 0, block_idx => 0, arrival_cost => 1 },
	 { region_id => 1, block_idx => 0, arrival_cost => 4 }],
	{ 0 => 0.5, 1 => 0.5 }, { 0 => 0.5, 1 => 0.5, 2 => 1 }, 1,
);
my ($departure_best) = sort { $a->{score} <=> $b->{score} } @$departure_plans;
is($departure_best->{first_id}, 1,
	'arrival and departure costs select the farther region when it shortens the full sequence');

my $equal_cost_weights = lockMapSweep::calculate_first_region_probabilities(
	{ 0 => 12, 1 => 12 }, 24,
);
is_deeply([map { $_->{probability} } @$equal_cost_weights], [0.5, 0.5],
	'equal-cost plans preserve the region scheduler probability');
my $one_window_apart = lockMapSweep::calculate_first_region_probabilities(
	{ 0 => 0, 1 => 24 }, 24,
);
cmp_ok(abs($one_window_apart->[1]{probability} - (1 / (1 + exp(1)))), '<', 1e-12,
	'a full 24-step cost difference lowers priority by e^-1 without making the region impossible');
my $biased_weights = lockMapSweep::calculate_first_region_probabilities(
	{ 0 => -24 * log(0.8), 1 => -24 * log(0.2) }, 24,
);
cmp_ok(abs($biased_weights->[0]{probability} - 0.8), '<', 1e-12,
	'probability-based region coverage remains proportional when travel costs match');
ok(lockMapSweep::same_position({ x => 10, y => 20 }, { x => 10, y => 20 }),
	'a just-confirmed coordinate can be excluded across a round reset');
ok(!lockMapSweep::same_position({ x => 10, y => 20 }, { x => 10, y => 21 }),
	'a different coordinate remains eligible after the round reset');
my $opportunities = lockMapSweep::filter_candidates_within_detour(
	[{ region_id => 0, arrival_cost => 1 }, { region_id => 1, arrival_cost => 25 },
	 { region_id => 2, arrival_cost => 26 }, { region_id => 3, arrival_cost => 129 }], 24,
);
is_deeply([map { $_->{region_id} } @$opportunities], [0, 1],
	'coverage history can favor a full-window detour but cannot cross the hard detour cap');

done_testing();
