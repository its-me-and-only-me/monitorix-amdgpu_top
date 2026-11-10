#!/usr/bin/perl
#
# parse_test.pl - parser test for the amdgpu_top MODULE ITSELF
#                 (calls amdgpu_top::collect_json / ::extract_values,
#                  so it always tests what ships)
#
# Usage:
#   ./parse_test.pl                 # live: amdgpu_top -J -n 1
#   ./parse_test.pl --no-pc         # live without performance counters
#   ./parse_test.pl --file samples/oneshot.json [more.json ...]
#   ./parse_test.pl --json          # raw flat hash as JSON
#
# Exit codes: 0 = all files/devices extracted OK (with sane value counts),
#             1 = collection/parse error, 2 = usage error
#

use strict;
use warnings;
use FindBin qw($Bin);
use lib "/usr/lib/monitorix";	# Monitorix.pm
use lib "$Bin";		# amdgpu_top.pm (repo copy wins over any installed one)
use amdgpu_top;
use JSON::PP;

my @files;
my $live = 1;
my $no_pc = 0;
my $as_json = 0;

while(@ARGV) {
	my $a = shift(@ARGV);
	if($a eq "--file") {
		$live = 0;
		while(@ARGV && $ARGV[0] !~ /^--/) {
			push(@files, shift(@ARGV));
		}
	}
	elsif($a eq "--no-pc") { $no_pc = 1 }
	elsif($a eq "--json")  { $as_json = 1 }
	else {
		print STDERR "Usage: $0 [--file f1.json ...] [--no-pc] [--json]\n";
		exit(2);
	}
}

if(!@files && !$live) {
	print STDERR "No sample files given.\n";
	exit(2);
}

my @sources;
if($live) {
	push(@sources, { desc => "live: amdgpu_top -J -n 1" . ($no_pc ? " --no-pc" : ""), no_pc => $no_pc });
}
push(@sources, { desc => "file: $_", file => $_ }) for (@files);

my $rc = 0;

foreach my $src (@sources) {
	print "=" x 72, "\nSource: $src->{desc}\n";
	my ($data, $err) = amdgpu_top::collect_json("parse_test", %$src);
	if($err) {
		print "ERROR: $err\n";
		$rc = 1;
		next;
	}

	my $ndev = scalar(@{$data->{devices}});
	printf("devices: %d | amdgpu_top v%d.%d.%d\n", $ndev,
		map { $data->{amdgpu_top_version}{$_} } qw(major minor patch));

	if($ndev == 0) {
		print "ERROR: no devices in document\n";
		$rc = 1;
		next;
	}

	foreach my $i (0 .. $ndev - 1) {
		my $dev = $data->{devices}[$i];
		my $vals = amdgpu_top::extract_values($dev);
		if(!$vals) {
			print "ERROR: device $i is not a hash\n";
			$rc = 1;
			next;
		}

		my @names = amdgpu_top::ds_names();
		my $defined_cnt = grep { defined($vals->{$_}) } @names;

		if($as_json) {
			print JSON::PP->new->canonical->pretty->encode(
				{ device => $i, values => { map { $_ => $vals->{$_} } @names } });
		}
		else {
			printf("-- device %d: %s (%s)\n", $i,
				$dev->{Info}{DeviceName}  // "?",
				$dev->{Info}{"GPU Type"}  // "?");
			my @sections = (
				["activity/GRBM/GRBM2 [%]", [grep { /^(act_|g_|t_pipe|prim|sh_|color|depth|geom|cp_|eff_|ring|sdma|tex_|rb_|utc_)/ } @names]],
				["temperatures [C]",        [grep { /^t_/ && $_ ne "t_pipe" } @names]],
				["power [W]",               [grep { /^p_/ } @names]],
				["clocks [MHz]",            [grep { /^(sclk|mclk|cpu_f)/ } @names]],
				["voltage [mV]",            [grep { /^vdd/ } @names]],
				["fan/PCIe",                [grep { /^(fan|pcie)/ } @names]],
				["VRAM [MiB]",              [grep { /^(vram|gtt)_/ } @names]],
				["gpu_metrics temps [C]",   [grep { /^gm_t_/ } @names]],
				["gpu_metrics clk [MHz]",   [grep { /^gm_a.*clk$/ } @names]],
				["gpu_metrics power [W]",   [grep { /^gm_p_/ } @names]],
				["gpu_metrics volt [mV]",   [grep { /^gm_v_/ } @names]],
				["gpu_metrics other",       [grep { /^gm_fan/ } @names]],
				["fdinfo totals",           [grep { /^fd_|^proc_/ } @names]],
			);
			foreach my $sec (@sections) {
				print "  [$sec->[0]]\n";
				foreach my $n (@{$sec->[1]}) {
					printf("    %-12s %s\n", $n, defined($vals->{$n}) ? $vals->{$n} : "n/a");
				}
			}
			# sanity: which names are not covered by the section groups?
			my %covered = map { $_ => 1 } map { @{$_->[1]} } @sections;
			my @missing_sec = grep { !$covered{$_} } @names;
			print "  [UNGROUPED - fix sections!]\n    $_\n" foreach (@missing_sec);
			printf("  => %d/%d values defined\n", $defined_cnt, scalar(@names));
		}

		# plausibility checks on the live sample only when values exist
		if($defined_cnt < 8) {
			print "WARNING: only $defined_cnt defined values - suspicious\n";
			$rc = 1 if($live);
		}
	}
}

print "RESULT: ", ($rc ? "FAILED" : "OK"), "\n";
exit($rc);
