#!/usr/bin/perl
#
# t_robust.pl - robustness / edge-case tests for the amdgpu_top module (step 7)
#
# Every scenario runs init + update against a FRESH RRD in its own directory
# with debug=1, so the module logs the complete RRD update string
# ("... amdgpu_top_update: N:v1:v2:..."). The assertions parse THAT string -
# it is the deterministic output of the function under test.
#
# (Reading values back via RRDs::fetch is NOT suitable for fast tests: rrdtool
# flushes a closed PDP into the RRA lazily, only when the NEXT update arrives;
# storage semantics are covered by t_update.pl and the live daemon instead.)
#
# Scenario positions map to DS names via RRDs::info (creation order == @DSPEC).
#
# Scenarios:
#   a)  --no-pc JSON via file  : GRBM/GRBM2 DS 'U', other values intact
#   a2) --no-pc live (no_pc=y) : GRBM DS 'U' from live tool, no crash
#   b)  broken command output  : no exception, WARNING logged, ALL DS 'U'
#   b2) binary missing         : no exception, ERROR logged, ALL DS 'U'
#   b3) file option missing    : no exception, ERROR logged
#   c)  index outside devices[]: slot 'U' + WARNING, no crash
#   c2) non-numeric index      : slot 'U' + ERROR
#   d)  use_nan_for_missing_data=n: missing sensors stored as 0
#   e)  two slots "0, 0"       : both slot column blocks byte-identical
#   f)  foreign-schema RRD     : init rotates to .bak and recreates (79 DS)
#
# Exit codes: 0 = all checks passed, 1 = failures (listed)
#

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin";			# amdgpu_top.pm
use lib "/usr/lib/monitorix";	# Monitorix.pm
use File::Path qw(make_path remove_tree);
use RRDs;
use amdgpu_top;

$| = 1;

my $root = "$Bin/test_robust";
remove_tree($root);

my @failures;

sub check {
	my ($desc, $ok, $detail) = @_;
	printf("[%s] %s%s\n", $ok ? " OK " : "FAIL", $desc, defined($detail) ? " ($detail)" : "");
	push(@failures, $desc) unless $ok;
}

# run init+update (debug=1) in an isolated directory, capture all logger
# output. Returns ($log, \@ds_names, \@values|undef).
# @values is the ':'-separated value list of the logged update string
# ('U' for NaN), aligned with @ds_names (per-slot, e0d0_* then e0d1_* ...).
sub run_scenario {
	my ($name, $cfg, %opt) = @_;

	my $dir = "$root/$name";
	make_path($dir);

	# optional pre-planted RRD (scenario f)
	if($opt{plant_rrd}) {
		RRDs::create("$dir/amdgpu_top.rrd",
			"DS:foo:GAUGE:600:U:U", "DS:bar:GAUGE:600:U:U", "DS:baz:GAUGE:600:U:U",
			"RRA:AVERAGE:0.5:1:60");
	}

	my %config = (
		os			=> "Linux",
		base_lib		=> "$dir/",
		max_historic_years	=> 1,
		func_update		=> [],
		amdgpu_top		=> $cfg,
	);

	my $log = "";
	{
		local *STDOUT;
		open(STDOUT, '>', \$log) or die "cannot capture STDOUT: $!";
		eval { amdgpu_top_init("amdgpu_top", \%config, 1) };
		$log .= "EXCEPTION-INIT: $@" if $@;
		eval { amdgpu_top_update("amdgpu_top", \%config, 1) };
		$log .= "EXCEPTION-UPDATE: $@" if $@;
		close(STDOUT);
	}

	# DS order from the (re)created RRD; fetch-independent
	my @ds_names;
	if(-e "$dir/amdgpu_top.rrd") {
		my $info = RRDs::info("$dir/amdgpu_top.rrd");
		# numeric index preserves creation order
		foreach my $key (keys %$info) {
			if($key =~ /^ds\[(.*?)\]\.index$/) {
				$ds_names[$info->{$key}] = $1;
			}
		}
	}

	# parse the update string from the log (last "N:..." occurrence)
	my @values;
	if($log =~ /^.*amdgpu_top_update: (N(?::[^:\s]+)*)/m) {
		@values = split(/:/, $1);
		shift(@values);	# drop leading "N"
	}
	return ($log, \@ds_names, @values ? \@values : undef);
}

# value of DS $name in the update string
sub val {
	my ($values, $ds, $name) = @_;
	return undef unless($values && @$values == @$ds);
	my ($i) = grep { $ds->[$_] eq $name } 0 .. $#$ds;
	return undef unless defined($i);
	my $v = $values->[$i];
	return $v eq "U" ? undef : $v + 0;
}

my $S = "$Bin/samples";

# ---------------------------------------------------------------------------
print "\n== a) --no-pc JSON via file ==\n";
{
	my ($log, $ds, $values) = run_scenario("a_file", {
		list	=> { 0 => "0" },
		cmd	=> "amdgpu_top -J -n 1",
		file	=> "$S/nopc.json",
		use_nan_for_missing_data => "y",
	});
	check("a) no exception", $log !~ /EXCEPTION/);
	check("a) update string has 79 values", $values && @$values == 79, $values ? scalar(@$values) . " values" : "no update string logged");
	check("a) 79 DS in RRD", scalar(@$ds) == 79, scalar(@$ds) . " DS");
	check("a) GRBM (g_pipe) = U", !defined(val($values, $ds, "e0d0_g_pipe")));
	check("a) GRBM2 (cp_comp) = U", !defined(val($values, $ds, "e0d0_cp_comp")));
	check("a) GRBM2 (utc_l2) = U", !defined(val($values, $ds, "e0d0_utc_l2")));
	check("a) act_gfx defined", defined(val($values, $ds, "e0d0_act_gfx")), val($values, $ds, "e0d0_act_gfx") // "U");
	check("a) t_edge = 40", defined(val($values, $ds, "e0d0_t_edge")) && abs(val($values, $ds, "e0d0_t_edge") - 40) < 0.01, val($values, $ds, "e0d0_t_edge") // "U");
	check("a) vram_use = 367", defined(val($values, $ds, "e0d0_vram_use")) && val($values, $ds, "e0d0_vram_use") == 367, val($values, $ds, "e0d0_vram_use") // "U");
}

print "\n== a2) --no-pc live (no_pc = y) ==\n";
{
	my ($log, $ds, $values) = run_scenario("a_live", {
		list	=> { 0 => "0" },
		cmd	=> "amdgpu_top -J -n 1",
		no_pc	=> "y",
		use_nan_for_missing_data => "y",
	});
	check("a2) no exception", $log !~ /EXCEPTION/);
	check("a2) update string logged", $values && @$values == 79, $values ? scalar(@$values) : "none");
	check("a2) GRBM (g_pipe) = U (live --no-pc)", $values && !defined(val($values, $ds, "e0d0_g_pipe")));
	check("a2) gm_p_sock defined", $values && defined(val($values, $ds, "e0d0_gm_p_sock")), val($values, $ds, "e0d0_gm_p_sock") // "U");
}

# ---------------------------------------------------------------------------
print "\n== b) broken command output at init (probe aborts by design) ==\n";
{
	my ($log, $ds, $values) = run_scenario("b", {
		list	=> { 0 => "0" },
		cmd	=> "/usr/bin/printf bogus-not-json",
		use_nan_for_missing_data => "y",
	});
	check("b) no exception", $log !~ /EXCEPTION/);
	check("b) probe error logged by init", $log =~ /ERROR.*JSON parse error/i, ($log =~ /(ERROR[^\n]*)/) ? substr($1, 0, 90) : "nothing logged");
	check("b) init aborts BEFORE RRD creation (by design, like other modules)", !-e "$root/b/amdgpu_top.rrd");
	check("b) daemon-side update still safe", $log !~ /EXCEPTION/);
}

print "\n== b1) tool breaks AFTER successful init (uninstalled mid-run) ==\n";
{
	my ($log, $ds, $values) = run_scenario("b1", {
		list	=> { 0 => "0" },
		cmd	=> "amdgpu_top -J -n 1",
		file	=> "$S/oneshot.json",
		use_nan_for_missing_data => "y",
	});
	check("b1) baseline init ok", -e "$root/b1/amdgpu_top.rrd");
	# now break the source and run update again against the EXISTING RRD
	my $log2 = "";
	{
		local *STDOUT;
		open(STDOUT, '>', \$log2) or die;
		my %config = (
			os => "Linux", base_lib => "$root/b1/", max_historic_years => 1,
			func_update => [],
			amdgpu_top => {
				list	=> { 0 => "0" },
				cmd	=> "definitely_not_installed_xyz -J -n 1",
				use_nan_for_missing_data => "y",
			},
		);
		eval { amdgpu_top_update("amdgpu_top", \%config, 1) };
		$log2 .= "EXCEPTION-UPDATE: $@" if $@;
		close(STDOUT);
	}
	check("b1) no exception after removal", $log2 !~ /EXCEPTION/);
	check("b1) error logged", $log2 =~ /unable to execute|ERROR/i, ($log2 =~ /(ERROR[^\n]*|unable[^\n]*)/) ? substr($1, 0, 90) : "nothing logged");
	check("b1) ALL DS = U in update attempt", $log2 =~ /amdgpu_top_update: (N(?::U){79})\b/);
	check("b1) existing RRD preserved", -e "$root/b1/amdgpu_top.rrd");
}

print "\n== b2) command binary does not exist ==\n";
{
	my ($log, $ds, $values) = run_scenario("b2", {
		list	=> { 0 => "0" },
		cmd	=> "definitely_not_installed_xyz -J -n 1",
		use_nan_for_missing_data => "y",
	});
	check("b2) no exception", $log !~ /EXCEPTION/);
	check("b2) error logged", $log =~ /unable to execute/i, ($log =~ /(unable to execute[^\n]*)/) ? substr($1, 0, 90) : "nothing logged");
	check("b2) ALL DS = U", $values && !(grep { $_ ne "U" } @$values));
}

print "\n== b3) file option points to missing file ==\n";
{
	my ($log, $ds, $values) = run_scenario("b3", {
		list	=> { 0 => "0" },
		cmd	=> "amdgpu_top -J -n 1",
		file	=> "$S/does_not_exist.json",
		use_nan_for_missing_data => "y",
	});
	check("b3) no exception", $log !~ /EXCEPTION/);
	check("b3) error logged", $log =~ /unable to open/i, ($log =~ /(unable to open[^\n]*)/) ? substr($1, 0, 90) : "nothing logged");
	check("b3) ALL DS = U", $values && !(grep { $_ ne "U" } @$values));
}

# ---------------------------------------------------------------------------
print "\n== c) device index outside devices[] ==\n";
{
	my ($log, $ds, $values) = run_scenario("c", {
		list	=> { 0 => "7" },
		cmd	=> "amdgpu_top -J -n 1",
		file	=> "$S/oneshot.json",
		use_nan_for_missing_data => "y",
	});
	check("c) no exception", $log !~ /EXCEPTION/);
	check("c) WARNING about index logged", $log =~ /WARNING.*index 7 not found/i, ($log =~ /(WARNING[^\n]*)/) ? substr($1, 0, 90) : "nothing logged");
	check("c) ALL DS = U", $values && !(grep { $_ ne "U" } @$values));
}

print "\n== c2) invalid (non-numeric) device index ==\n";
{
	my ($log, $ds, $values) = run_scenario("c2", {
		list	=> { 0 => "abc" },
		cmd	=> "amdgpu_top -J -n 1",
		file	=> "$S/oneshot.json",
		use_nan_for_missing_data => "y",
	});
	check("c2) no exception", $log !~ /EXCEPTION/);
	check("c2) ERROR about invalid index", $log =~ /invalid device index/i, ($log =~ /(ERROR[^\n]*)/) ? substr($1, 0, 90) : "nothing logged");
	check("c2) ALL DS = U", $values && !(grep { $_ ne "U" } @$values));
}

# ---------------------------------------------------------------------------
print "\n== d) use_nan_for_missing_data = n -> zeros ==\n";
{
	my ($log, $ds, $values) = run_scenario("d", {
		list	=> { 0 => "0" },
		cmd	=> "amdgpu_top -J -n 1",
		file	=> "$S/nopc.json",	# GRBM null + t_junc null -> zeros expected
		use_nan_for_missing_data => "n",
	});
	check("d) no exception", $log !~ /EXCEPTION/);
	check("d) update string has 79 values", $values && @$values == 79);
	check("d) NO 'U' anywhere", $values && !(grep { $_ eq "U" } @$values), $values ? (grep { $_ eq "U" } @$values) . " U entries" : "");
	check("d) missing GRBM (g_pipe) = 0", defined(val($values, $ds, "e0d0_g_pipe")) && val($values, $ds, "e0d0_g_pipe") == 0, val($values, $ds, "e0d0_g_pipe") // "U");
	check("d) missing sensor (t_junc) = 0", defined(val($values, $ds, "e0d0_t_junc")) && val($values, $ds, "e0d0_t_junc") == 0, val($values, $ds, "e0d0_t_junc") // "U");
	check("d) present sensor (t_edge) = 40", defined(val($values, $ds, "e0d0_t_edge")) && abs(val($values, $ds, "e0d0_t_edge") - 40) < 0.01, val($values, $ds, "e0d0_t_edge") // "U");
}

# ---------------------------------------------------------------------------
print "\n== e) two slots '0, 0' -> identical columns (offset check) ==\n";
{
	my ($log, $ds, $values) = run_scenario("e", {
		list	=> { 0 => "0, 0" },
		cmd	=> "amdgpu_top -J -n 1",
		file	=> "$S/oneshot.json",
		use_nan_for_missing_data => "y",
	});
	check("e) no exception", $log !~ /EXCEPTION/);
	check("e) 158 DS (2 slots x 79)", scalar(@$ds) == 158, scalar(@$ds) . " DS");
	check("e) update string has 158 values", $values && @$values == 158, $values ? scalar(@$values) : "none");
	if($values && @$values == 158) {
		my $diff = 0;
		my @first_diff;
		for(my $i = 0; $i < 79; $i++) {
			if($values->[$i] ne $values->[79 + $i]) {
				$diff++;
				push(@first_diff, "$ds->[$i]: $values->[$i] vs $values->[79 + $i]") if(@first_diff < 3);
			}
		}
		check("e) slot block 2 identical to block 1 (79/79)", $diff == 0, @first_diff ? join("; ", @first_diff) : "");
	}
	else {
		check("e) slot block 2 identical to block 1 (79/79)", 0, "no comparable update string");
	}
}

# ---------------------------------------------------------------------------
print "\n== f) stale RRD with foreign schema -> rotation to .bak ==\n";
{
	my ($log, $ds, $values) = run_scenario("f", {
		list	=> { 0 => "0" },
		cmd	=> "amdgpu_top -J -n 1",
		file	=> "$S/oneshot.json",
		use_nan_for_missing_data => "y",
	}, plant_rrd => 1);
	check("f) no exception", $log !~ /EXCEPTION/);
	check("f) old RRD rotated to .bak", -e "$root/f/amdgpu_top.rrd.bak");
	check("f) new RRD has 79 DS", scalar(@$ds) == 79, scalar(@$ds) . " DS");
	check("f) rotation logged", $log =~ /rotat|\.bak/i, ($log =~ /([^\n]*(?:rotat|\.bak)[^\n]*)/) ? substr($1, 0, 90) : "not logged (informational only)");
	check("f) update after rotation works", $values && grep({ $_ ne "U" } @$values) > 50, $values ? scalar(grep({ $_ ne "U" } @$values)) . " defined values" : "none");
}

# ---------------------------------------------------------------------------
print "\n== result ==\n";
if(@failures) {
	print "FAILED checks:\n  $_\n" foreach (@failures);
	exit(1);
}
print "ALL CHECKS PASSED\n";
exit(0);
