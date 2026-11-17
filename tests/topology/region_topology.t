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

my $bounds = [
	{ min_x => 1, max_x => 5, min_y => 1, max_y => 3 },
	{ min_x => 1, max_x => 5, min_y => 4, max_y => 6 },
];
my %walkable;
for my $y (1 .. 3) {
	for my $x (1 .. 5) {
		next if $x == 3;
		$walkable{"$x,$y"} = 1;
	}
}
for my $y (4 .. 6) {
	$walkable{"$_,$y"} = 1 for 1 .. 5;
}
my %reachable = %walkable;
$reachable{'8,1'} = 1; # outside the global connected component and block grid
my %eligible = map { $_ => 1 } ('1,1', '2,1', '4,1', '5,1', '1,4', '2,4', '3,4');
my $can_move = sub {
	my ($from, $to) = @_;
	my ($dx, $dy) = (abs($to->{x} - $from->{x}), abs($to->{y} - $from->{y}));
	return 0 if (!$dx && !$dy) || $dx > 1 || $dy > 1;
	return 0 unless $walkable{"$to->{x},$to->{y}"};
	if ($dx && $dy) {
		return 0 unless $walkable{"$to->{x},$from->{y}"} && $walkable{"$from->{x},$to->{y}"};
	}
	return 1;
};

my $topology = lockMapSweep::build_region_topology_for_grid(
	$bounds,
	sub { $reachable{"$_[0],$_[1]"} },
	sub { $eligible{"$_[0],$_[1]"} },
	sub { $walkable{"$_[0],$_[1]"} },
	$can_move,
);
my $regions = $topology->{regions};
my $lookup = $topology->{region_lookup};
is(scalar(@$regions), 3, 'two disconnected upper regions and one lower connector region are identified');
my ($a, $b, $lower) = @{$regions}[map { $lookup->{$_} } ('1,1', '4,1', '1,4')];
is_deeply([$a->{block_idx}, $b->{block_idx}, $lower->{block_idx}], [0, 0, 1], 'region ownership follows the fixed block grid');
is_deeply([$a->{eligible_count}, $b->{eligible_count}, $lower->{eligible_count}], [2, 2, 3],
	'area weights count eligible destinations while topology includes intermediate cells');
ok($a->{neighbors}{$lower->{id}} && $b->{neighbors}{$lower->{id}}
	&& $lower->{neighbors}{$a->{id}} && $lower->{neighbors}{$b->{id}},
	'same-block regions connect globally through an external block');
ok(!exists $lookup->{'8,1'}, 'globally unreachable cells create no region or coverage obligation');

done_testing();
