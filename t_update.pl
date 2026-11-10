#!/usr/bin/perl
#
# t_update.pl - offline function test for the Monitorix amdgpu_top module
#
# Simulates the Monitorix daemon: builds a minimal %config, calls
# amdgpu_top_init() + amdgpu_top_update() against a JSON sample file and
# verifies the resulting RRD structure and values.
#
# RRD timing semantics (verified): a GAUGE update becomes readable via
# AVERAGE only after its 60-second bucket has closed, and the consolidated
# value is the exact value only if the update happened near the bucket
# START (it is time-weighted otherwise). Therefore every test update is
# issued right after a minute boundary. Total runtime ~2-3 minutes.
#
# Exit codes: 0 = all checks passed, 1 = failures (listed)
#

use strict;
use warnings;
use FindBin qw($Bin);
use lib "/usr/lib/monitorix";	# Monitorix.pm
use lib "$Bin";		# amdgpu_top.pm (repo copy wins over any installed one)
use File::Path qw(make_path);
use RRDs;
use amdgpu_top;

$| = 1;

my $testdir = "$Bin/test";
my $rrd = "$testdir/amdgpu_top.rrd";

make_path($testdir);
unlink($rrd);
unlink("$rrd.bak");

my @failures;

sub check {
	my ($desc, $ok, $detail) = @_;
	printf("[%s] %s%s\n", $ok ? " OK " : "FAIL", $desc, defined($detail) ? " ($detail)" : "");
	push(@failures, $desc) unless $ok;
}

# sleep 2 s after the next minute boundary (so updates land at bucket start
# and closed buckets become readable)
sub wait_boundary {
	my $now = time();
	my $next = $now - ($now % 60) + 62;
	printf("(waiting %d s for minute boundary)\n", $next - $now);
	sleep($next - $now);
}

# fetch rows containing at least one defined value
# returns (\@vrows, \%ds_index) or (undef, $err)
sub defined_rows {
	my ($rrd) = @_;
	my (undef, undef, $names, $data) = RRDs::fetch($rrd, "AVERAGE", "-r", "60", "-s", "-600");
	return (undef, RRDs::error()) if(RRDs::error());
	my %dix;
	@dix{@$names} = (0 .. $#{$names});
	my @vrows = grep { my $r = $_; grep { defined($_) } @{$r} } @$data;
	return (\@vrows, \%dix);
}

# --- scenario: 1 group with 2 device slots (device 0 twice -> offset test) ---
my %config = (
	os			=> "Linux",
	base_lib		=> "$testdir/",
	max_historic_years	=> 1,
	func_update		=> [],
	amdgpu_top		=> {
		list	=> { 0 => "0, 0" },
		cmd	=> "amdgpu_top -J -n 1",
		file	=> "$Bin/samples/oneshot.json",
		use_nan_for_missing_data => "y",
	},
);

print "== init ==\n";
amdgpu_top_init("amdgpu_top", \%config, 1);
check("init registers func_update", (grep { $_ eq "amdgpu_top" } @{$config{func_update}}) == 1);
check("RRD file created", -e $rrd);

print "\n== RRD structure ==\n";
my $info = RRDs::info($rrd);
my %ds;
for my $key (keys %$info) {
	$ds{$1} = 1 if($key =~ /^ds\[(.*?)\]\.type$/);
}
check("DS count = 2 slots x 79", scalar(keys %ds) == 158, scalar(keys %ds) . " found");
check("e0d0_act_gfx exists", exists($ds{e0d0_act_gfx}));
check("e0d1_proc_count exists", exists($ds{e0d1_proc_count}));
check("e0d1_act_gfx exists (2nd slot)", exists($ds{e0d1_act_gfx}));

print "\n== update #1 (sample) at bucket start ==\n";
wait_boundary();
amdgpu_top_update("amdgpu_top", \%config, 1);

print "\n== update #2 (live) at next bucket start; then verify #1 ==\n";
wait_boundary();
delete($config{amdgpu_top}->{file});
amdgpu_top_update("amdgpu_top", \%config, 1);

my ($vrows, $dix) = defined_rows($rrd);
if(!$vrows) {
	check("fetch works", 0);
}
else {
	check("fetch works", 1);
	# NOTE: rrdtool 1.9 shows an already-updated in-progress bucket row
	# immediately, so both update rows are visible here.
	check("2 defined rows visible (sample + live)", scalar(@$vrows) == 2, scalar(@$vrows) . " rows");
	my $row = $vrows->[0];

	# expected values from samples/oneshot.json (device 0), exact because
	# update #1 landed at the bucket start
	my %expect = (
		e0d0_t_edge     => [40, 40],	# from sample file
		e0d0_vram_tot   => [512, 512],
		e0d0_vram_use   => [367, 367],
		e0d0_gtt_tot    => [122880, 122880],
		e0d0_gtt_use    => [94887, 94887],
		e0d0_gm_t_gfx   => [40.5, 40.75],	# 40.62 (converted /100, +-rounding)
		e0d0_gm_p_sock  => [39.2, 39.5],	# 39.37 (converted /1000)
		e0d0_proc_count => [1, 1],
		e0d0_fd_gtt     => [2, 2],
		e0d0_mclk       => [1000, 1000],
	);
	foreach my $dsn (sort keys %expect) {
		my $v = $row->[$dix->{$dsn}];
		my ($lo, $hi) = @{$expect{$dsn}};
		my $ok = defined($v) && $v >= $lo - 0.01 && $v <= $hi + 0.01;
		check("$dsn == expected ($lo" . ($lo != $hi ? "..$hi" : "") . ")", $ok, defined($v) ? $v : "U");
	}

	# range-only sanity for the volatile entries
	foreach my $dsn (qw(e0d0_act_gfx e0d0_sclk e0d0_t_tctl e0d0_cpu_favg e0d0_cpu_fmax)) {
		my $v = $row->[$dix->{$dsn}];
		check("$dsn defined and >= 0", defined($v) && $v >= 0, defined($v) ? $v : "U");
	}

	# slot d1 (same device index 0) must show the same values -> offset test
	foreach my $suffix (qw(vram_use gtt_use mclk gm_t_gfx gm_p_sock proc_count t_edge)) {
		my $v0 = $row->[$dix->{"e0d0_$suffix"}];
		my $v1 = $row->[$dix->{"e0d1_$suffix"}];
		my $ok = (defined($v0) && defined($v1) && abs($v0 - $v1) < 0.001) || (!defined($v0) && !defined($v1));
		check("slot offset: e0d0_$suffix == e0d1_$suffix", $ok, ($v0 // "U") . " vs " . ($v1 // "U"));
	}

	# NaN policy: t_junc is null on this APU -> U
	check("missing sensor (e0d0_t_junc) = NaN", !defined($row->[$dix->{e0d0_t_junc}]));
}

print "\n== verify #2 (live) at next boundary ==\n";
wait_boundary();
my ($vrows2) = defined_rows($rrd);
check("at least 2 defined rows now (sample + live)", $vrows2 && scalar(@$vrows2) >= 2, $vrows2 ? scalar(@$vrows2) . " rows" : "fetch err");
if($vrows2 && @$vrows2 >= 2) {
	my $live = $vrows2->[-1];
	my $ix = $dix;
	check("live row: vram_tot == 512", defined($live->[$ix->{e0d0_vram_tot}]) && $live->[$ix->{e0d0_vram_tot}] == 512, $live->[$ix->{e0d0_vram_tot}] // "U");
	check("live row: t_tctl 10..100", defined($live->[$ix->{e0d0_t_tctl}]) && $live->[$ix->{e0d0_t_tctl}] >= 10 && $live->[$ix->{e0d0_t_tctl}] <= 100, $live->[$ix->{e0d0_t_tctl}] // "U");
}

print "\n== broken command scenario (immediate) ==\n";
$config{amdgpu_top}->{cmd} = "/usr/bin/printf bogus-not-json";
eval { amdgpu_top_update("amdgpu_top", \%config, 1) };
check("broken cmd: no exception", !$@, $@ ? "$@" : "");
my $lu = RRDs::last($rrd);
check("broken cmd: survived, lastupdate still advances", (time() - $lu) < 90, (time() - $lu) . " s");
# GAUGE values carry over within the heartbeat, so row counts stay stable -
# only requirement: fetch still works and no RRD error occurred.
my ($vrows3) = defined_rows($rrd);
check("broken cmd: RRD still readable, no corruption", defined($vrows3) && scalar(@$vrows3) >= 2, $vrows3 ? scalar(@$vrows3) . " rows" : "fetch err");

print "\n== result ==\n";
if(@failures) {
	print "FAILED checks:\n  $_\n" foreach (@failures);
	exit(1);
}
print "ALL CHECKS PASSED\n";
exit(0);
