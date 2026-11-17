#!/usr/bin/env perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;

our ($route_target, $movement_settled);

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
	sub message {} sub warning {} sub error {} sub debug {}
	$INC{'Log.pm'} = __FILE__;

	package AI;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::ai_route"} = \&ai_route;
	}
	sub ai_route { $main::route_target = { x => $_[1], y => $_[2] }; }
	$INC{'AI.pm'} = __FILE__;

	package Misc;
	sub getAttackAutoMode { 0 }
	$INC{'Misc.pm'} = __FILE__;

	package Field;
	sub import {}
	sub new { return bless { baseName => 'persist_fixture', rawMap => "persist-fixture" }, $_[0] }
	sub baseName { $_[0]{baseName} }
	sub width { 4 }
	sub height { 8 }
	sub isWalkable {
		my ($self, $x, $y) = @_;
		return $x == 1 && $y >= 1 && $y <= 6;
	}
	sub canMove {
		my ($self, $from, $to) = @_;
		return 0 unless $self->isWalkable($to->{x}, $to->{y});
		return abs($from->{x} - $to->{x}) <= 1 && abs($from->{y} - $to->{y}) <= 1;
	}
	$INC{'Field.pm'} = __FILE__;

	package Utils;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::actorFinishedMovement"} = \&actorFinishedMovement;
	}
	sub actorFinishedMovement { $main::movement_settled ? 1 : 0 }
	$INC{'Utils.pm'} = __FILE__;
	package Utils::PathFinding; $INC{'Utils/PathFinding.pm'} = __FILE__;
}

require "$ENV{LOCKMAPSWEEP_PLUGIN}";

my $state_dir = tempdir(CLEANUP => 1);
%Globals::config = (
	lockMap => 'persist_fixture',
	lockMapSweep_enabled => 1,
	lockMapSweep_blocksX => 1,
	lockMapSweep_blocksY => 3,
	lockMapSweep_cellsPerBlock => 2,
	lockMapSweep_useStateFile => 1,
	lockMapSweep_stateDir => $state_dir,
	lockMap_x => 1,
	lockMap_y => undef,
	lockMap_randX => 0,
	lockMap_randY => 0,
	route_randomWalk_maxRouteTime => 60,
	route_randomWalk => 0,
);
$Globals::field = Field->new();
$Globals::char = { pos => { x => 1, y => 1 }, pos_to => { x => 1, y => 1 } };
srand($ENV{LOCKMAPSWEEP_TEST_SEED} || 19);
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }), 'initialize the real plugin state on a deterministic three-block fixture');

sub tick_random_walk {
	my %args;
	lockMapSweep::on_ai_process_random_walk(undef, \%args);
	return \%args;
}

sub saved_state {
	my ($path) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	my %state = (round_visit => {}, region_visit => {}, pending => []);
	while (my $line = <$fh>) {
		chomp $line;
		my @parts = split /\t/, $line;
		if ($parts[0] eq 'meta') { $state{meta}{$parts[1]} = $parts[2]; }
		elsif ($parts[0] eq 'round_visit') { $state{round_visit}{$parts[1]} = $parts[2]; }
		elsif ($parts[0] eq 'region_visit') { $state{region_visit}{$parts[1]} = $parts[2]; }
		elsif ($parts[0] eq 'pending') { push @{$state{pending}}, \@parts; }
	}
	close $fh;
	return \%state;
}

my $state_file = "$state_dir/persist_fixture_1x3_c2_v6.state";
tick_random_walk();
ok($route_target && $route_target->{y} == 3, 'first selected coverage destination is block A');
$Globals::char->{pos_to} = { %$route_target };
$movement_settled = 1;
tick_random_walk();
my $after_a = saved_state($state_file);
is($after_a->{round_visit}{1}, 1, 'confirmed arrival records exactly one visit in block A');
is($after_a->{meta}{current_block}, 0, 'next route selects unvisited neighboring block B');
is($after_a->{meta}{visits_in_block}, 0, 'changing to B synchronizes the legacy current-block counter');
is($after_a->{round_visit}{0} || 0, 0, 'selecting B does not credit a visit');
is(scalar @{$after_a->{pending}}, 1, 'the pending B destination is serialized');
is(scalar values %{$after_a->{region_visit}}, 1, 'confirmed region history is serialized');

# A restart must use the actual v6 loader. Keep the character at A while the
# route to B is pending; no position alignment may discard the pending target.
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }), 'reload the just-written v6 state through the production loader');
my ($pending) = @{$after_a->{pending}};
$Globals::char->{pos_to} = { x => $pending->[2], y => $pending->[3] };
$movement_settled = 0;
my $before_settlement = saved_state($state_file);
tick_random_walk();
is(saved_state($state_file)->{round_visit}{0} || 0, 0, 'restored pending route receives no credit before server settlement');

$movement_settled = 1;
tick_random_walk();
my $after_b = saved_state($state_file);
is($after_b->{round_visit}{0}, 1, 'settling the restored destination adds exactly one B visit');
is(scalar values %{$after_b->{region_visit}}, 2, 'both confirmed region visits survive recovery');
is($after_b->{meta}{visits_in_block}, $after_b->{round_visit}{$after_b->{meta}{current_block}} || 0,
	'continuation after B keeps the selected block counter aligned with its own history');

# Exercise alignment to a different, already visited block with no pending
# route by using a valid persisted snapshot and the real loader.
open my $read, '<', $state_file or die "open $state_file: $!";
my @snapshot = <$read>;
close $read;
@snapshot = map {
	$_ =~ /^meta\tcurrent_block\t/ ? "meta\tcurrent_block\t0\n"
	: $_ =~ /^meta\tvisits_in_block\t/ ? "meta\tvisits_in_block\t1\n"
	: $_ =~ /^pending\t/ ? () : $_
} @snapshot;
open my $write, '>', $state_file or die "write $state_file: $!";
print {$write} @snapshot;
close $write;
$Globals::char->{pos_to} = { x => 1, y => 3 };
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 3 }), 'load valid state with no pending target and align to the character position');
my $aligned = saved_state($state_file);
is($aligned->{meta}{current_block}, 1, 'position alignment selects the block under the character');
is($aligned->{meta}{visits_in_block}, 1, 'position alignment restores the partially visited block’s authoritative count');
is($aligned->{round_visit}{1}, 1, 'alignment leaves block A history unchanged');

# The snapshot now contains different confirmed counts in multiple blocks.
is($aligned->{round_visit}{0}, 1, 'block B retains its separate confirmed count');
ok(!$aligned->{round_visit}{2}, 'block C remains pending after visits in A and B');

# Finish the real route lifecycle until the round rolls over. This exercises
# returning to partial blocks, all three quotas, and the production reset.
my $round = $aligned->{meta}{round_number};
my $arrivals = 0;
$route_target = undef;
while ($round == 1 && $arrivals < 12) {
	unless ($route_target) {
		$movement_settled = 0;
		tick_random_walk();
	}
	last unless $route_target;
	$Globals::char->{pos_to} = { %$route_target };
	$movement_settled = 1;
	tick_random_walk();
	$arrivals++;
	$round = saved_state($state_file)->{meta}{round_number};
}
my $next_round = saved_state($state_file);
is($next_round->{meta}{round_number}, 2, 'completing the final obligation advances the global round');
ok(!keys %{$next_round->{round_visit}}, 'round transition resets all block visit counters');
my $historical_arrivals = 0;
$historical_arrivals += $_ for values %{$next_round->{region_visit}};
is($historical_arrivals, 6,
	'round transition preserves all six confirmed visits in long-term region history');

# Strict validation remains active: corrupt the saved geometry signature and
# verify that the loader rejects it and starts a clean state.
open $read, '<', $state_file or die "open $state_file: $!";
@snapshot = <$read>;
close $read;
@snapshot = map { $_ =~ /^meta\tgeometry\t/ ? "meta\tgeometry\tinvalid\n" : $_ } @snapshot;
open $write, '>', $state_file or die "write $state_file: $!";
print {$write} @snapshot;
close $write;
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 3 }), 'invalid persisted geometry is rejected without weakening the loader');
my $rejected = saved_state($state_file);
is($rejected->{meta}{round_number}, 1, 'rejected state starts a clean coverage round');
ok(!keys %{$rejected->{round_visit}}, 'rejected state does not import malformed block counters');

done_testing();
