#!/usr/bin/env perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;

our ($route_target, $route_attempts, $movement_settled);

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
	our @messages;
	sub import {
		my $caller = caller;
		no strict 'refs';
		for my $name (qw(message warning error debug)) {
			*{"${caller}::$name"} = __PACKAGE__->can($name);
		}
	}
	sub message { push @messages, $_[0] }
	sub warning { push @messages, $_[0] }
	sub error { push @messages, $_[0] }
	sub debug { push @messages, $_[0] }
	$INC{'Log.pm'} = __FILE__;

	package AI;
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::ai_route"} = \&ai_route;
	}
	sub ai_route {
		$main::route_target = { x => $_[1], y => $_[2] };
		$main::route_attempts++;
	}
	sub is { 1 }
	sub args { return { isRandomWalk => 1, dest => { pos => $main::route_target } } }
	$INC{'AI.pm'} = __FILE__;

	package Misc;
	sub getAttackAutoMode { 0 }
	$INC{'Misc.pm'} = __FILE__;

	package Field;
	our $walk_queries = 0;
	sub import {}
	sub new {
		my ($class, %args) = @_;
		return bless { baseName => $args{name}, rawMap => "retry-fixture" }, $class;
	}
	sub baseName { $_[0]{baseName} }
	sub width { 5 }
	sub height { $_[0]{baseName} eq 'retry_block_switch' ? 8 : 3 }
	sub isWalkable {
		$walk_queries++;
		my ($self, $x, $y) = @_;
		return $x == 1 && $y >= 1 && $y <= 6 if $self->{baseName} eq 'retry_block_switch';
		return $y == 1 && $x >= 1 && $x <= 3;
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
sub configure_fixture {
	my (%args) = @_;
	%Globals::config = (
		lockMap => $args{map},
		lockMapSweep_enabled => 1,
		lockMapSweep_blocksX => 1,
		lockMapSweep_blocksY => $args{blocks_y} || 1,
		lockMapSweep_cellsPerBlock => $args{quota},
		lockMapSweep_useStateFile => 1,
		lockMapSweep_stateDir => $state_dir,
		lockMap_x => $args{lock_x},
		lockMap_y => undef,
		lockMap_randX => 0,
		lockMap_randY => 0,
		route_randomWalk_maxRouteTime => 60,
		route_randomWalk => 0,
	);
	$Globals::field = Field->new(name => $args{map});
	$Globals::char = { pos => { x => 1, y => 1 }, pos_to => { x => 1, y => 1 } };
	$route_target = undef;
	$route_attempts = 0;
	$movement_settled = 0;
	srand(19);
	return lockMapSweep::initialize_or_reload(1, { x => 1, y => 1 });
}

sub tick {
	my %args;
	lockMapSweep::on_ai_process_random_walk(undef, \%args);
	return \%args;
}

sub route_failure {
	lockMapSweep::on_route(undef, { status => 'stuck' });
}

sub route_success {
	$Globals::char->{pos_to} = { %$route_target };
	$movement_settled = 1;
	lockMapSweep::on_route(undef, { status => 'success' });
	$movement_settled = 0;
}

sub read_state {
	my ($path) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	my %saved = (round_visit => {}, region_visit => {}, failed => [], pending => [], deferred => {});
	while (my $line = <$fh>) {
		chomp $line;
		my @f = split /\t/, $line;
		if ($f[0] eq 'meta') { $saved{meta}{$f[1]} = $f[2]; }
		elsif ($f[0] eq 'round_visit') { $saved{round_visit}{$f[1]} = int($f[2]); }
		elsif ($f[0] eq 'region_visit') { $saved{region_visit}{$f[1]} = int($f[2]); }
		elsif ($f[0] eq 'failed') { push @{$saved{failed}}, \@f; }
		elsif ($f[0] eq 'pending') { push @{$saved{pending}}, \@f; }
		elsif ($f[0] eq 'deferred') { $saved{deferred}{$f[1]} = $f[4]; }
	}
	close $fh;
	return \%saved;
}

sub expire_saved_retry {
	my ($path) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	my @lines = <$fh>;
	close $fh;
	@lines = map { /^meta\tfailed_retry_after\t/ ? "meta\tfailed_retry_after\t0\n" : $_ } @lines;
	open my $out, '>', $path or die "write $path: $!";
	print {$out} @lines;
	close $out;
}

sub rewrite_retry_meta {
	my ($path, $value) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	my @lines = <$fh>;
	close $fh;
	@lines = map { /^meta\tfailed_retry_after\t/ ? "meta\tfailed_retry_after\t$value\n" : $_ } @lines;
	open my $out, '>', $path or die "write $path: $!";
	print {$out} @lines;
	close $out;
}

sub strip_retry_meta {
	my ($path) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	my @lines = <$fh>;
	close $fh;
	@lines = grep { !/^meta\tfailed_retry_after\t/ } @lines;
	open my $out, '>', $path or die "write $path: $!";
	print {$out} @lines;
	close $out;
}

sub run_blocked_tick {
	my $routes_before = $route_attempts;
	my $walks_before = $Field::walk_queries;
	my $args = tick();
	is($route_attempts, $routes_before, 'cooldown prevents another route attempt');
	is($Field::walk_queries, $walks_before, 'cooldown avoids another cell-level route search');
	ok($args->{return}, 'exhaustion consumes randomWalk instead of falling through to uncontrolled default movement');
}

# One eligible destination: failure is persisted, throttled across restart, and
# retried after the persisted cooldown expires. Only the server-settled retry
# completes the quota and advances the round.
ok(configure_fixture(map => 'retry_single', lock_x => 2, quota => 1), 'initialize one-target failure fixture');
my $single_state = "$state_dir/retry_single_1x1_c1_v6.state";
tick();
is_deeply($route_target, { x => 2, y => 1 }, 'the sole eligible destination is selected');
route_failure();
my $failed_once = read_state($single_state);
is(scalar @{$failed_once->{failed}}, 1, 'failed destination is persisted as an attempted route failure');
is(scalar @{$failed_once->{pending}}, 0, 'failure clears the pending route');
ok(!keys %{$failed_once->{round_visit}}, 'failed attempt does not receive confirmed-arrival credit');
ok($failed_once->{meta}{failed_retry_after} > time(), 'failure persists a bounded retry deadline');

run_blocked_tick();
my $blocked = read_state($single_state);
like(join(' ', values %{$blocked->{deferred}}), qr/all remaining destinations failed/,
	'exhaustion is exposed as a stable deferred obligation');
is($blocked->{meta}{round_number}, 1, 'exhaustion does not fabricate round completion');

ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }), 'restart loads failed-target cooldown through the v6 state loader');
is(scalar @{read_state($single_state)->{failed}}, 1, 'restart preserves the failed destination');
my $queries_after_restart = $Field::walk_queries;
my $routes_after_restart = $route_attempts;
run_blocked_tick();
is($routes_after_restart, $route_attempts, 'restart does not cause an immediate retry loop');
is($queries_after_restart, $Field::walk_queries, 'restart cooldown does not repeat full route searches');

expire_saved_retry($single_state); # deterministic stand-in for the 30-second wall-clock wait
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }), 'expired retry deadline reloads without clearing valid progress');
tick();
is_deeply($route_target, { x => 2, y => 1 }, 'the previously failed destination becomes eligible again');
is($route_attempts, 2, 'the destination receives one controlled retry');
route_success();
my $single_complete = read_state($single_state);
is($single_complete->{meta}{round_number}, 2, 'one confirmed retry completes the quota and advances the round');
ok(!keys %{$single_complete->{round_visit}}, 'new round starts with reset block counters');
is(0 + (values %{$single_complete->{region_visit}})[0], 1, 'exactly one confirmed region visit is retained');
is(scalar @{$single_complete->{failed}}, 0, 'round transition clears obsolete failed-target marks');
strip_retry_meta($single_state);
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }), 'existing v6 state without retry metadata remains loadable');
is(read_state($single_state)->{meta}{round_number}, 2, 'backward-compatible load preserves its completed round history');
rewrite_retry_meta($single_state, 'not-an-epoch');
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }), 'malformed retry metadata is rejected by strict state validation');
my $invalid_retry = read_state($single_state);
is($invalid_retry->{meta}{round_number}, 1, 'invalid retry deadline starts a clean state instead of importing malformed history');
ok(!keys %{$invalid_retry->{region_visit}}, 'invalid retry deadline does not import region history');

# Several destinations: use healthy alternatives first, retain the failed
# obligation, then reconsider it after cooldown without double-crediting visits.
ok(configure_fixture(map => 'retry_multiple', quota => 3), 'initialize multi-destination failure fixture');
my $multi_state = "$state_dir/retry_multiple_1x1_c3_v6.state";
tick();
my $failed_cell = { %$route_target };
route_failure();
tick();
ok($route_target && ($route_target->{x} != $failed_cell->{x} || $route_target->{y} != $failed_cell->{y}),
	'planner chooses an unfailed alternative before retrying the failed cell');
my $second_cell = { %$route_target };
route_success();
tick();
ok($route_target && ($route_target->{x} != $failed_cell->{x} || $route_target->{y} != $failed_cell->{y})
	&& ($route_target->{x} != $second_cell->{x} || $route_target->{y} != $second_cell->{y}),
	'planner selects a second distinct usable destination');
route_success();
my $two_arrivals = read_state($multi_state);
is($two_arrivals->{round_visit}{0}, 2, 'two successful alternatives receive exactly two confirmed visits');
is(scalar @{$two_arrivals->{failed}}, 1, 'the original failed destination remains outstanding');
my $multi_walks_before = $Field::walk_queries;
run_blocked_tick();
is($Field::walk_queries, $multi_walks_before, 'all-destinations-exhausted state is throttled without full-map search');
is(read_state($multi_state)->{round_visit}{0}, 2, 'exhaustion retains the final quota obligation');

ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}), 'restart during multi-target exhaustion preserves two arrivals');
is(read_state($multi_state)->{round_visit}{0}, 2, 'restart preserves the incomplete block quota');
expire_saved_retry($multi_state);
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}), 'reload expired multi-target cooldown');
tick();
is_deeply($route_target, $failed_cell, 'previously failed cell is reconsidered after the bounded delay');
route_success();
my $multi_complete = read_state($multi_state);
is($multi_complete->{meta}{round_number}, 2, 'recovered third arrival completes the global round');
is($multi_complete->{region_visit}{'0:1,1'}, 3, 'successful destinations are counted once and failed attempts never count');

# Cross-block persistence invariant plus failure recovery: A has one confirmed
# visit, B is selected with a different count, its pending route fails, and the
# saved state must still reload before B's obligation is recovered.
ok(configure_fixture(map => 'retry_block_switch', lock_x => 1, quota => 2, blocks_y => 3),
	'initialize block-switch failure interaction fixture');
my $switch_state = "$state_dir/retry_block_switch_1x3_c2_v6.state";
tick();
is($route_target->{y}, 3, 'first confirmed visit belongs to block A');
route_success();
is(read_state($switch_state)->{round_visit}{1}, 1, 'block A has one confirmed visit before switching');
tick();
my $pending_b = read_state($switch_state)->{pending}[0];
ok($pending_b && $pending_b->[1] != 1, 'planner selects a different block B with its own visit count');
my $failed_b = { x => int($pending_b->[2]), y => int($pending_b->[3]) };
my $block_b_idx = int($pending_b->[1]);
route_failure();
my $switch_failed = read_state($switch_state);
is($switch_failed->{round_visit}{1}, 1, 'B route failure preserves A confirmed progress');
is($switch_failed->{round_visit}{$block_b_idx} || 0, 0, 'B route failure earns no visit credit');
is($switch_failed->{meta}{current_block}, $block_b_idx, 'failed pending target remains the selected block');
is($switch_failed->{meta}{visits_in_block}, 0, 'different B visit count is synchronized before persistence');
is(scalar @{$switch_failed->{failed}}, 1, 'failed B destination is persisted for bounded recovery');

$Globals::char->{pos_to} = { x => 1, y => 3 };
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 3 }),
	'restart reloads A/B progress and the failed destination through the real loader');
my $switch_reloaded = read_state($switch_state);
is($switch_reloaded->{meta}{current_block}, 1, 'position alignment returns to the partially visited A block');
is($switch_reloaded->{meta}{visits_in_block}, 1, 'A alignment uses its authoritative count after failed B route');
is($switch_reloaded->{round_visit}{1}, 1, 'restart retains A visit history');
is(scalar @{$switch_reloaded->{failed}}, 1, 'restart retains B failure without discarding the quota');

expire_saved_retry($switch_state);
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 3 }), 'expired B retry deadline restores normal destination selection');
my $switch_round = read_state($switch_state)->{meta}{round_number};
my $switch_successes = 0;
my $failed_b_recovered = 0;
$route_target = undef;
while ($switch_round == 1 && $switch_successes < 10) {
	unless ($route_target) {
		$movement_settled = 0;
		tick();
	}
	last unless $route_target;
	$failed_b_recovered = 1
		if $route_target->{x} == $failed_b->{x} && $route_target->{y} == $failed_b->{y};
	route_success();
	$route_target = undef;
	$switch_successes++;
	$switch_round = read_state($switch_state)->{meta}{round_number};
}
ok($failed_b_recovered, 'the previously failed B destination is eventually confirmed');
is($switch_round, 2, 'A/B failure-recovery scenario completes the full coverage round');
my $switch_complete = read_state($switch_state);
my $switch_history_total = 0;
$switch_history_total += $_ for values %{$switch_complete->{region_visit}};
is($switch_history_total, 6,
	'all six confirmed visits remain in long-term region history after recovery');

done_testing();
