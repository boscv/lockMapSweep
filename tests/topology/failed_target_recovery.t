#!/usr/bin/env perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;

our ($route_target, $route_attempts, $movement_settled, $ai_route_index, $ai_clear_count, $test_now);

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
	sub findAction { return $main::ai_route_index }
	sub clear { $main::ai_clear_count++; return 1 }
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
		return $x == 2 && $y == 1 if $self->{baseName} eq 'retry_no_stage';
		return $y == 1 && $x >= 1 && $x <= 3 if $self->{baseName} eq 'retry_pair';
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

$test_now = CORE::time();
{
	no warnings qw(redefine once);
	*lockMapSweep::time = sub () { $main::test_now };
}

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
	my $start_x = $args{start_x} || 1;
	$Globals::char = { pos => { x => $start_x, y => 1 }, pos_to => { x => $start_x, y => 1 } };
	$route_target = undef;
	$route_attempts = 0;
	$movement_settled = 0;
	srand(19);
	return lockMapSweep::initialize_or_reload(1, { x => $start_x, y => 1 });
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
		elsif ($f[0] eq 'failed_retry') { push @{$saved{failed_retry}}, \@f; }
		elsif ($f[0] eq 'pending') { push @{$saved{pending}}, \@f; }
		elsif ($f[0] eq 'deferred') { $saved{deferred}{$f[1]} = $f[4]; }
		elsif ($f[0] eq 'recovery') {
			$saved{recovery} = { phase => $f[1], block_idx => int($f[2]),
				x => int($f[3]), y => int($f[4]), region_key => $f[5],
				stage_x => int($f[6]), stage_y => int($f[7]), retry_after => int($f[8]),
				consecutive_failures => defined $f[9] ? int($f[9]) : 0 };
		}
	}
	close $fh;
	return \%saved;
}

sub expire_saved_retry {
	my ($path) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	my @lines = <$fh>;
	close $fh;
	my $expired_at = int($test_now) - 1;
	@lines = map {
		if (/^meta\tfailed_retry_after\t/) { "meta\tfailed_retry_after\t0\n" }
		elsif (/^failed_retry\t/) { my @f = split /\t/; $f[5] = $expired_at; join("\t", @f) }
		elsif (/^recovery\t(?:return|blocked)\t/) { my @f = split /\t/; $f[8] = $expired_at; join("\t", @f) }
		else { $_ }
	} @lines;
	open my $out, '>', $path or die "write $path: $!";
	print {$out} @lines;
	close $out;
}

sub expire_saved_recovery_retry {
	my ($path) = @_;
	open my $fh, '<', $path or die "open $path: $!";
	my @lines = <$fh>;
	close $fh;
	my $expired_at = int($test_now) - 1;
	@lines = map {
		if (/^recovery\tblocked\t/) { my @f = split /\t/; $f[8] = $expired_at; join("\t", @f) }
		else { $_ }
	} @lines;
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
	@lines = grep { !/^meta\tfailed_retry_after\t/ && !/^failed_retry\t/ } @lines;
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
is($failed_once->{failed_retry}[0][4], 1, 'first failure records one consecutive retry');
ok($failed_once->{failed_retry}[0][5] > $test_now, 'first failure persists a short retry deadline');

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

expire_saved_retry($single_state); # deterministic stand-in for the short cooldown
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

# A new round cannot credit the only destination while the character remains
# stationary on it. It must leave through a walkable staging cell and return.
$movement_settled = 1;
my $routes_before_staging = $route_attempts;
tick();
my $stage_pending = read_state($single_state);
is($stage_pending->{meta}{round_number}, 2, 'occupied destination leaves the new round incomplete');
is(0 + (values %{$stage_pending->{region_visit}})[0], 1, 'selecting an occupied destination adds no region credit');
is($route_attempts, $routes_before_staging + 1, 'planner queues one native route to a staging position');
is($stage_pending->{recovery}{phase}, 'stage', 'staging movement phase is persisted');
is(scalar @{$stage_pending->{pending}}, 1, 'staging route is persisted as pending');
is($stage_pending->{pending}[0][5], 1, 'staging route is marked transit and cannot consume quota');
ok(!lockMapSweep::is_cell_eligible($route_target->{x}, $route_target->{y}),
	'staging destination may be outside the configured coverage restriction');
my $stage_target = { %$route_target };
$Globals::char->{pos_to} = { %$stage_target };
$movement_settled = 0;
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}),
	'reload restores a pending staging route under strict v6 validation');
my $routes_while_staging = $route_attempts;
tick();
is($route_attempts, $routes_while_staging, 'an in-progress staging route is not queued twice after reload');
is(0 + (values %{read_state($single_state)->{region_visit}})[0], 1,
	'pending staging movement receives no region credit');
open my $valid_state_fh, '<', $single_state or die "open $single_state: $!";
my $valid_stage_state = do { local $/; <$valid_state_fh> };
close $valid_state_fh;
my $invalid_stage_state = $valid_stage_state;
$invalid_stage_state =~ s/^(recovery\tstage\t\d+\t\d+\t\d+\t[^\t]+\t)-?\d+\t-?\d+\t\d+(?:\t\d+)?$/${1}4\t1\t0\t0/m
	or die 'could not corrupt staging coordinate for strict-loader regression';
open my $invalid_stage_fh, '>', $single_state or die "write $single_state: $!";
print {$invalid_stage_fh} $invalid_stage_state;
close $invalid_stage_fh;
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}),
	'loader rejects a staging transit coordinate that is not walkable');
ok(!defined read_state($single_state)->{recovery}, 'invalid staging recovery is discarded instead of trusted');
open my $restore_stage_fh, '>', $single_state or die "restore $single_state: $!";
print {$restore_stage_fh} $valid_stage_state;
close $restore_stage_fh;
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}),
	'valid pending staging state reloads after strict rejection check');
is(read_state($single_state)->{recovery}{phase}, 'stage', 'valid staging phase remains intact after restore');
route_failure();
my $stage_failed = read_state($single_state);
is($stage_failed->{recovery}{phase}, 'blocked', 'failed staging enters a bounded persisted blocked state');
is($stage_failed->{recovery}{consecutive_failures}, 1, 'failed staging records its first consecutive failure');
ok($stage_failed->{recovery}{retry_after} > $test_now, 'failed staging retains a short adaptive recovery delay');
is(scalar @{$stage_failed->{pending}}, 0, 'failed staging clears only the pending route');
is(0 + (values %{$stage_failed->{region_visit}})[0], 1, 'failed staging receives no region credit');
ok(lockMapSweep::initialize_or_reload(undef, { x => 2, y => 1 }),
	'reload preserves a failed staging recovery phase');
is(read_state($single_state)->{recovery}{phase}, 'blocked', 'failed staging recovery phase is still present on disk');
my $routes_during_stage_cooldown = $route_attempts;
tick();
is($route_attempts, $routes_during_stage_cooldown, 'failed staging cooldown prevents repeated route attempts');
expire_saved_recovery_retry($single_state);
ok(lockMapSweep::initialize_or_reload(undef, { x => 2, y => 1 }),
	'expired staging cooldown reloads without losing the quota');
is(read_state($single_state)->{recovery}{phase}, 'blocked', 'expired blocked phase is preserved before retry');
tick();
my $staging_retry = read_state($single_state);
is($staging_retry->{recovery}{phase}, 'stage', 'expired cooldown re-enables staging recovery');
is($route_attempts, $routes_during_stage_cooldown + 1, 'one staging retry is queued after cooldown');
$stage_target = { x => int($staging_retry->{pending}[0][2]), y => int($staging_retry->{pending}[0][3]) };
$Globals::char->{pos_to} = { %$stage_target };
$movement_settled = 0;
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}),
	'reload restores the retried pending staging destination');
is(read_state($single_state)->{recovery}{phase}, 'stage', 'staging phase survives pending-route reload');
$movement_settled = 1;
route_success();
my $stage_arrived = read_state($single_state);
is($stage_arrived->{recovery}{phase}, 'return', 'confirmed departure advances recovery to return phase');
is(scalar @{$stage_arrived->{pending}}, 0, 'completed staging movement clears its transit target');
is($stage_arrived->{round_visit}{0} || 0, 0, 'staging arrival leaves the block quota unchanged');
is(0 + (values %{$stage_arrived->{region_visit}})[0], 1, 'staging arrival leaves region history unchanged');
$movement_settled = 0;
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}),
	'reload preserves the confirmed-staging-before-return phase');
$movement_settled = 1;
tick();
is_deeply($route_target, { x => 2, y => 1 }, 'recovery routes back to the original eligible destination');
my $return_pending = read_state($single_state);
is($return_pending->{recovery}{phase}, 'return', 'return phase remains persisted while route is pending');
is($return_pending->{pending}[0][5] || 0, 0, 'return target remains a normal coverage destination');
is($return_pending->{round_visit}{0} || 0, 0, 'queuing the return does not consume the quota');
$Globals::char->{pos_to} = { %$route_target };
$movement_settled = 0;
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}),
	'reload restores a pending return route');
my $routes_during_return = $route_attempts;
tick();
is($route_attempts, $routes_during_return, 'pending return route is not duplicated after reload');
$Globals::char->{pos_to} = { %$stage_target };
$Globals::char->{pos} = { %$stage_target };
$movement_settled = 1;
route_failure();
my $return_failed = read_state($single_state);
is($return_failed->{recovery}{phase}, 'return', 'failed return preserves its recovery obligation');
is($return_failed->{round_visit}{0} || 0, 0, 'failed return receives no block visit credit');
is(0 + (values %{$return_failed->{region_visit}})[0], 1, 'failed return receives no region visit credit');
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}),
	'reload preserves a failed return with its original obligation');
my $routes_during_return_cooldown = $route_attempts;
tick();
is($route_attempts, $routes_during_return_cooldown, 'return failure observes the existing bounded retry cooldown');
expire_saved_retry($single_state);
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}),
	'expired return cooldown restores normal recovery');
tick();
is_deeply($route_target, { x => 2, y => 1 }, 'recovery retries the original destination after cooldown');
route_success();
my $returned = read_state($single_state);
is($returned->{meta}{round_number}, 3, 'one confirmed departure and return completes exactly one quota');
is($returned->{round_visit}{0} || 0, 0, 'completed round resets only after the real return arrival');
is(0 + (values %{$returned->{region_visit}})[0], 2, 'one genuine return adds exactly one region visit');
ok(!defined $returned->{recovery}, 'completed recovery state is cleared');

# Repeated stationary ticks in the next round may stage once but cannot create
# further region history or round transitions.
$movement_settled = 1;
my $routes_before_idle_ticks = $route_attempts;
tick();
my $idle_stage = read_state($single_state);
is($idle_stage->{recovery}{phase}, 'stage', 'next occupied round starts a new staging cycle');
is($idle_stage->{meta}{round_number}, 3, 'stationary selection does not advance the round');
is(0 + (values %{$idle_stage->{region_visit}})[0], 2, 'stationary selection does not add region history');
is($route_attempts, $routes_before_idle_ticks + 1, 'stationary recovery queues one staging route only');
$Globals::char->{pos_to} = { %$route_target };
$movement_settled = 0;
for (1 .. 4) { tick(); }
my $idle_repeated = read_state($single_state);
is($idle_repeated->{meta}{round_number}, 3, 'repeated ticks during staging cannot manufacture coverage rounds');
is(0 + (values %{$idle_repeated->{region_visit}})[0], 2, 'repeated ticks during staging cannot manufacture region visits');
is($route_attempts, $routes_before_idle_ticks + 1, 'repeated ticks do not duplicate the pending staging route');

# A live disable can interrupt a queued stage. Preserve the recovery obligation
# without a pending route, then reload and queue staging again when re-enabled.
$ai_route_index = 0;
$ai_clear_count = 0;
$Globals::config{lockMapSweep_enabled} = 0;
lockMapSweep::on_config_modify(undef, { key => 'lockMapSweep_enabled' });
my $interrupted_stage = read_state($single_state);
is($ai_clear_count, 1, 'config disable interrupts the plugin-owned staging route');
is(scalar @{$interrupted_stage->{pending}}, 0, 'interrupted staging clears only its route target');
is($interrupted_stage->{recovery}{phase}, 'stage', 'interrupted staging obligation remains persisted');
is(0 + (values %{$interrupted_stage->{region_visit}})[0], 2,
	'interrupted staging still has no coverage credit');
$Globals::config{lockMapSweep_enabled} = 1;
ok(lockMapSweep::initialize_or_reload(undef, { x => 2, y => 1 }),
	'reload accepts only a validated interrupted staging phase without a pending route');
is(read_state($single_state)->{recovery}{phase}, 'stage',
	'interrupted staging phase survives strict v6 reload');
my $routes_after_interrupted_stage = $route_attempts;
tick();
is($route_attempts, $routes_after_interrupted_stage + 1,
	're-enabled recovery queues a native staging route again');
is(read_state($single_state)->{round_visit}{0} || 0, 0,
	're-queued staging still does not consume the block quota');
$ai_route_index = undef;

strip_retry_meta($single_state);
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }), 'existing v6 state without retry metadata remains loadable');
is(read_state($single_state)->{meta}{round_number}, 3, 'backward-compatible load preserves its completed round history');
rewrite_retry_meta($single_state, 'not-an-epoch');
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }),
	'malformed retry metadata is discarded without invalidating coverage progress');
my $invalid_retry = read_state($single_state);
is($invalid_retry->{meta}{round_number}, 3, 'invalid retry deadline preserves the saved coverage round');
my $preserved_retry_history = 0;
$preserved_retry_history += $_ for values %{$invalid_retry->{region_visit}};
is($preserved_retry_history, 2, 'invalid retry deadline preserves confirmed region history');
is(scalar @{$invalid_retry->{failed_retry} || []}, 0,
	'untrusted retry metadata is cleared and can be rebuilt safely');

# A one-cell component has no departure path. Preserve its obligation in a
# bounded, explicit state instead of inventing an arrival.
ok(configure_fixture(map => 'retry_no_stage', lock_x => 2, quota => 1, start_x => 2),
	'initialize a fixture with no reachable staging cell');
my $no_stage_state = "$state_dir/retry_no_stage_1x1_c1_v6.state";
my $no_stage_routes = $route_attempts;
my $no_stage_args = tick();
my $no_stage_blocked = read_state($no_stage_state);
is($no_stage_blocked->{recovery}{phase}, 'blocked', 'no-stage topology is recorded as explicitly blocked');
ok($no_stage_blocked->{recovery}{retry_after} > $test_now, 'no-stage block has a bounded retry time');
like(join(' ', values %{$no_stage_blocked->{deferred}}), qr/no reachable staging cell/,
	'no-stage topology records a clear deferred-obligation reason');
ok($no_stage_args->{return}, 'blocked occupied target consumes randomWalk rather than falling through');
is($no_stage_blocked->{meta}{round_number}, 1, 'no-stage topology retains the unfinished round');
is(scalar keys %{$no_stage_blocked->{region_visit}}, 0, 'no-stage topology creates no region visit');
is($route_attempts, $no_stage_routes, 'no-stage topology queues no impossible route');
ok(lockMapSweep::initialize_or_reload(undef, { x => 2, y => 1 }),
	'no-stage blocked state reloads through strict v6 validation');
for (1 .. 3) { tick(); }
is($route_attempts, $no_stage_routes, 'blocked no-stage retries remain bounded across repeated ticks');
is(scalar keys %{read_state($no_stage_state)->{region_visit}}, 0,
	'blocked no-stage retries never create region history');

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

# Simulated time makes the adaptive retry boundaries deterministic. Repeated
# failures at one destination back off 1, 2, 4, then 8 seconds and stay capped.
$test_now = 1000;
ok(configure_fixture(map => 'retry_single', lock_x => 2, quota => 1),
	'initialize deterministic adaptive-backoff fixture');
my $backoff_state = "$state_dir/retry_single_1x1_c1_v6.state";
my @expected_delays = (1, 2, 4, 8, 8);
my $retry_deadline;
for my $attempt (0 .. $#expected_delays) {
	if ($attempt == 0) {
		tick();
	} else {
		my $routes_before_wait = $route_attempts;
		$test_now = $retry_deadline - 0.01;
		run_blocked_tick();
		is($route_attempts, $routes_before_wait, 'destination remains blocked just before its deadline');
		$test_now = $retry_deadline;
		tick();
		is($route_attempts, $routes_before_wait + 1, 'one retry is queued when its deadline becomes eligible');
	}
	route_failure();
	my $backoff = read_state($backoff_state);
	my ($entry) = @{$backoff->{failed_retry}};
	is($entry->[4], $attempt + 1, 'persistent retry count tracks consecutive route failures');
	my $measured_delay = int($entry->[5] - $test_now);
	is($measured_delay, $expected_delays[$attempt],
		'adaptive retry follows the 1, 2, 4, 8 second schedule with an eight-second cap');
	$retry_deadline = $entry->[5];
}

# A confirmed route clears only that destination's retry history.
$test_now = $retry_deadline;
tick();
route_success();
my $backoff_recovered = read_state($backoff_state);
is(scalar @{$backoff_recovered->{failed_retry}}, 0,
	'successful arrival clears the destination consecutive-failure history');

my $backoff_history_total = 0;
$backoff_history_total += $_ for values %{$backoff_recovered->{region_visit}};
is($backoff_history_total, 1,
	'failed attempts do not add history and the successful arrival adds exactly one');
$Globals::char->{pos_to} = { x => 1, y => 1 };
$Globals::char->{pos} = { x => 1, y => 1 };
$movement_settled = 0;
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }),
	'reload after a successful route retains the new round');
tick();
route_failure();
my $after_success_failure = read_state($backoff_state);
is($after_success_failure->{failed_retry}[0][4], 1,
	'a later failure starts a fresh backoff sequence after success');

# Separate failures have separate deadlines: B cannot postpone the now-due A.
$test_now = 2000;
ok(configure_fixture(map => 'retry_pair', quota => 2, start_x => 2),
	'initialize two-target independent-deadline fixture');
my $pair_state = "$state_dir/retry_pair_1x1_c2_v6.state";
tick();
my $target_a = { %$route_target };
route_failure();
my $a_retry = read_state($pair_state)->{failed_retry}[0][5];
tick();
my $target_b = { %$route_target };
ok($target_b->{x} != $target_a->{x} || $target_b->{y} != $target_a->{y},
	'an alternative destination is selected immediately after a failure');
$test_now = 2000.1;
route_failure();
my $pair_failed = read_state($pair_state);
is(scalar @{$pair_failed->{failed_retry}}, 2,
	'both failed destinations retain independent retry records');
my ($b_entry) = grep { $_->[2] == $target_b->{x} && $_->[3] == $target_b->{y} }
	@{$pair_failed->{failed_retry}};
cmp_ok($a_retry, '<', $b_entry->[5], 'later failure B receives a later deadline than A');
$test_now = $a_retry;
my $routes_before_a_retry = $route_attempts;
tick();
is($route_attempts, $routes_before_a_retry + 1,
	'A becomes usable at its own deadline while B remains cooling down');
is_deeply($route_target, $target_a, 'the planner retries due destination A without waiting for B');
route_success();

# Older v6 files with one global 30-second deadline remain loadable. The
# deadline is applied to each failed target once, then rewritten per target.
$test_now = 3000;
ok(configure_fixture(map => 'retry_pair', quota => 2, start_x => 2),
	'reinitialize v6 legacy-migration fixture');
tick();
route_success();
tick();
route_failure();
my $legacy_state = "$state_dir/retry_pair_1x1_c2_v6.state";
my $legacy_failed = read_state($legacy_state);
my $legacy_deadline = int($test_now) + 30;
open my $legacy_in, '<', $legacy_state or die "open $legacy_state: $!";
my @legacy_lines = <$legacy_in>;
close $legacy_in;
@legacy_lines = grep { !/^failed_retry\t/ }
	map { /^meta\tfailed_retry_after\t/ ? "meta\tfailed_retry_after\t$legacy_deadline\n" : $_ } @legacy_lines;
open my $legacy_out, '>', $legacy_state or die "write $legacy_state: $!";
print {$legacy_out} @legacy_lines;
close $legacy_out;
ok(lockMapSweep::initialize_or_reload(undef, { x => 2, y => 1 }),
	'old v6 failed-target state migrates without losing coverage progress');
my $migrated = read_state($legacy_state);
is($migrated->{meta}{round_number}, $legacy_failed->{meta}{round_number},
	'legacy retry migration preserves the current coverage round');
is(scalar @{$migrated->{failed_retry}}, 1,
	'legacy global deadline becomes per-destination retry metadata');
is($migrated->{failed_retry}[0][5], $legacy_deadline,
	'legacy 30-second deadline is retained safely for its existing failed target');
is($migrated->{round_visit}{0}, 1,
	'legacy retry migration preserves an already confirmed block visit');
my $migration_history_total = 0;
$migration_history_total += $_ for values %{$migrated->{region_visit}};
is($migration_history_total, 1,
	'legacy retry migration preserves proportional region history');
open my $bad_retry_in, '<', $legacy_state or die "open $legacy_state: $!";
my $bad_retry_text = do { local $/; <$bad_retry_in> };
close $bad_retry_in;
$bad_retry_text =~ s/^failed_retry\t\d+\t\d+\t\d+\t\d+\t\d+\t[01]$/failed_retry\t0\tinvalid\tmetadata/m
	 or die 'could not corrupt retry metadata for salvage regression';
open my $bad_retry_out, '>', $legacy_state or die "write $legacy_state: $!";
print {$bad_retry_out} $bad_retry_text;
close $bad_retry_out;
ok(lockMapSweep::initialize_or_reload(undef, $Globals::char->{pos_to}),
	'malformed per-target retry metadata is discarded independently of valid coverage state');
my $salvaged = read_state($legacy_state);
is($salvaged->{round_visit}{0}, 1, 'salvage keeps confirmed block visit accounting');
my $salvaged_history = 0;
$salvaged_history += $_ for values %{$salvaged->{region_visit}};
is($salvaged_history, 1, 'salvage keeps confirmed regional history');
is(scalar @{$salvaged->{failed}}, 0, 'malformed retry targets are removed from the cooldown set');
is(scalar @{$salvaged->{failed_retry} || []}, 0,
	'malformed backoff metadata cannot impose an untrusted deadline');

# A failed strategic waypoint can lie outside coverage-destination restrictions.
# It must persist as transit and must not suppress the eligible coverage goal.
$test_now = 4000;
ok(configure_fixture(map => 'retry_single', lock_x => 2, quota => 1),
	'initialize strategic-transit retry fixture');
my $transit_state = "$state_dir/retry_single_1x1_c1_v6.state";
lockMapSweep::record_failed_target({ block_idx => 0, x => 3, y => 1, transit => 1 });
lockMapSweep::persist_state();
my $transit_failed = read_state($transit_state);
is($transit_failed->{failed_retry}[0][6], 1,
	'strategic transit failure is persisted separately from eligible destination failures');
ok(lockMapSweep::initialize_or_reload(undef, { x => 1, y => 1 }),
	'v6 loader accepts a failed walkable transit waypoint outside destination restrictions');
tick();
is_deeply($route_target, { x => 2, y => 1 },
	'failed transit waypoint does not postpone an available coverage destination');

done_testing();
