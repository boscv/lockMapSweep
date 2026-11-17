#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(looks_like_number);

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
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::config"} = \%config;
		*{"${caller}::field"} = \$field;
		*{"${caller}::char"} = \$char;
	}
	$INC{'Globals.pm'} = __FILE__;

	package Log;
	sub import {
		my $caller = caller;
		no strict 'refs';
		for my $name (qw(message warning error debug)) {
			*{"${caller}::$name"} = __PACKAGE__->can($name);
		}
	}
	sub message {}
	sub warning {}
	sub error {}
	sub debug {}
	$INC{'Log.pm'} = __FILE__;

	package AI;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::ai_route"} = \&ai_route;
	}
	sub ai_route {}
	$INC{'AI.pm'} = __FILE__;

	package Field;
	sub import {}
	$INC{'Field.pm'} = __FILE__;

	package Utils;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::actorFinishedMovement"} = \&actorFinishedMovement;
	}
	sub actorFinishedMovement { return 0 }
	$INC{'Utils.pm'} = __FILE__;

	package Utils::PathFinding;
	$INC{'Utils/PathFinding.pm'} = __FILE__;
}

require "$ENV{LOCKMAPSWEEP_PLUGIN}";

sub make_regions {
	my ($shares) = @_;
	my $total = 0;
	$total += $_ for @$shares;
	return [map { +{ id => $_, key => "region-$_", eligible_count => $shares->[$_] } } 0 .. $#$shares];
}

sub test_distribution {
	my ($shares, $quota, $seed) = @_;
	my $regions = make_regions($shares);
	my %confirmed;
	my @round_counts = (0) x scalar(@$shares);
	my $rounds = 20_000;
	my $smallest = 0;
	my $random_state = $seed;
	my $random = sub {
		$random_state = (48_271 * $random_state) % 2_147_483_647;
		return $random_state / 2_147_483_647;
	};
	for my $round (1 .. $rounds) {
		my @this_round = (0) x scalar(@$shares);
		for (1 .. $quota) {
			my $weighted = lockMapSweep::calculate_region_selection_weights($regions, \%confirmed);
			my $selected = lockMapSweep::sample_region_from_weights($weighted, $random->());
			$confirmed{"region-$selected"}++;
			$this_round[$selected]++;
		}
		$round_counts[$_] += $this_round[$_] for 0 .. $#round_counts;
		$smallest++ if $this_round[-1] > 0;
	}
	my $visits = $rounds * $quota;
	my @observed = map { $round_counts[$_] / $visits } 0 .. $#round_counts;
	return (\@observed, $smallest / $rounds);
}

my @cases = (
	[[1, 1], 2, [0.5, 0.5]],
	[[1, 1], 3, [0.5, 0.5]],
	[[2, 1], 3, [2 / 3, 1 / 3]],
	[[4, 1], 2, [0.8, 0.2]],
	[[4, 1], 4, [0.8, 0.2]],
	[[99, 1], 2, [0.99, 0.01]],
);
my $seed = 271;
for my $case (@cases) {
	my ($shares, $quota, $expected) = @$case;
	my ($observed, $smallest_round_rate) = test_distribution($shares, $quota, $seed++);
	for my $idx (0 .. $#$expected) {
		my $tolerance = $expected->[$idx] <= 0.02 ? 0.003 : 0.015;
		cmp_ok(abs($observed->[$idx] - $expected->[$idx]), '<=', $tolerance,
			sprintf('observed %.4f near target %.4f for shares [%s], quota %d',
				$observed->[$idx], $expected->[$idx], join(',', @$shares), $quota));
	}
	if ($shares->[0] == 99) {
		cmp_ok($smallest_round_rate, '>', 0.01, 'the 1% region is reached in some rounds without a fixed schedule');
		cmp_ok($smallest_round_rate, '<', 0.08, 'the 1% region remains occasional across rounds');
	}
}

my $rare_regions = make_regions([99, 1]);
my $neglected_weights = lockMapSweep::calculate_region_selection_weights($rare_regions,
	{ 'region-0' => 1_000, 'region-1' => 0 });
cmp_ok($neglected_weights->[1]{probability}, '>', 0.01, 'a neglected small region gains priority over its area share');
cmp_ok($neglected_weights->[1]{probability}, '<', 0.10, 'bounded debt does not let history dominate area');

my $many_regions = make_regions([(1) x 256]);
my %large_history = map { ("region-$_" => ($_ == 17 ? 10_000 : 0)) } 0 .. 255;
my $many_weights = lockMapSweep::calculate_region_selection_weights($many_regions, \%large_history);
my $probability_sum = 0;
my $all_finite_positive = 1;
for my $entry (@$many_weights) {
	$all_finite_positive = 0 unless looks_like_number($entry->{probability}) && $entry->{probability} > 0;
	$probability_sum += $entry->{probability};
}
ok($all_finite_positive, 'many-region probabilities remain finite and positive');
cmp_ok(abs($probability_sum - 1), '<', 1e-12, 'many-region weights normalize to one');
is(lockMapSweep::sample_region_from_weights($many_weights, 0), $many_weights->[0]{region_id},
	'probability sampling is deterministic for a fixed roll');
ok(!defined lockMapSweep::sample_region_from_weights($many_weights, 1), 'out-of-range random rolls are rejected');

done_testing();
