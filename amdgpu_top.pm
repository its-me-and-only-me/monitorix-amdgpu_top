#
# Monitorix - A lightweight system monitoring tool.
#
# amdgpu_top module: monitors all time-series values provided by the JSON
#                   output of the 'amdgpu_top' tool (amdgpu_top -J -n 1).
#
# Copyright (C) 2005-2022 by Jordi Sanfeliu <jordi@fibranet.cat>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#

package amdgpu_top;

use strict;
use warnings;
use Monitorix;
use RRDs;
use JSON::PP;
use Cwd 'abs_path';
use File::Basename;
use Exporter 'import';
our @EXPORT = qw(amdgpu_top_init amdgpu_top_update);	# + amdgpu_top_cgi (Step 5)

my $max_number_of_gpus = 8;	# Changing this number destroys history.

# ---------------------------------------------------------------------------
# value helpers
# ---------------------------------------------------------------------------

# sanitize to plain number or undef
sub num {
	my ($v) = @_;
	return undef unless defined($v);
	return undef if(ref($v));
	return undef unless($v =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/);
	my $n = $v + 0;
	return undef if($n != $n);			# NaN
	return undef if($n == 9**9**9 || $n == -(9**9**9));
	return $n;
}

# numeric value of a {"unit": "...", "value": N} pair
sub uval {
	my ($node) = @_;
	return undef unless ref($node) eq "HASH";
	return num($node->{value});
}

# average of positive array values (0 = absent sensor); undef if none
sub avg_positive {
	my ($list) = @_;
	return undef unless ref($list) eq "ARRAY";
	my @v = grep { defined($_) && $_ > 0 } map { num($_) } @{$list};
	return undef unless scalar(@v);
	my $s = 0;
	$s += $_ for (@v);
	return $s / scalar(@v);
}

# average/max over "CPU Core freq" array entries {cur_freq => N}
sub cpu_freq_stat {
	my ($dev, $mode) = @_;
	my $arr = $dev->{"Sensors"}->{"CPU Core freq"};
	return undef unless ref($arr) eq "ARRAY";
	my @v = grep { defined($_) } map { num($_->{cur_freq}) } @{$arr};
	return undef unless scalar(@v);
	if($mode eq "max") {
		my $m = $v[0];
		foreach (@v) { $m = $_ if($_ > $m) }
		return $m;
	}
	my $s = 0;
	$s += $_ for (@v);
	return $s / scalar(@v);
}

sub gm {
	my ($dev, $key, $div) = @_;
	my $v = num($dev->{"gpu_metrics"}->{$key});
	return undef unless defined($v);
	return $v / $div if($div);
	return $v;
}

# ---------------------------------------------------------------------------
# DS spec: ordered list of [ ds-suffix (<= 14 chars; RRD DS name limit is 19
# incl. the "e<k>d<n>_" prefix), extractor ]
# The order defines the RRD data source creation order! (79 entries)
# ---------------------------------------------------------------------------
my @DSPEC = (
	# --- gpu_activity (3) ---
	["act_gfx",     sub { uval($_[0]{gpu_activity}{GFX}) }],
	["act_media",   sub { uval($_[0]{gpu_activity}{MediaEngine}) }],
	["act_mem",     sub { uval($_[0]{gpu_activity}{Memory}) }],

	# --- GRBM performance counters (8) ---
	["g_pipe",      sub { uval($_[0]{GRBM}{"Graphics Pipe"}) }],
	["t_pipe",      sub { uval($_[0]{GRBM}{"Texture Pipe"}) }],
	["prim_asm",    sub { uval($_[0]{GRBM}{"Primitive Assembly"}) }],
	["sh_export",   sub { uval($_[0]{GRBM}{"Shader Export"}) }],
	["sh_interp",   sub { uval($_[0]{GRBM}{"Shader Processor Interpolator"}) }],
	["color_blk",   sub { uval($_[0]{GRBM}{"Color Block"}) }],
	["depth_blk",   sub { uval($_[0]{GRBM}{"Depth Block"}) }],
	["geom_eng",    sub { uval($_[0]{GRBM}{"Geometry Engine"}) }],

	# --- GRBM2 performance counters (9) - note the double spaces in keys! ---
	["cp_gfx",      sub { uval($_[0]{GRBM2}{"Command Processor - Graphics"}) }],
	["cp_comp",     sub { uval($_[0]{GRBM2}{"Command Processor -  Compute"}) }],
	["cp_fetch",    sub { uval($_[0]{GRBM2}{"Command Processor -  Fetcher"}) }],
	["eff_arb",     sub { uval($_[0]{GRBM2}{"Efficiency Arbiter"}) }],
	["ring_ctrl",   sub { uval($_[0]{GRBM2}{"Ring List Controller"}) }],
	["sdma",        sub { uval($_[0]{GRBM2}{"SDMA"}) }],
	["tex_cache",   sub { uval($_[0]{GRBM2}{"Texture Cache per Pipe"}) }],
	["rb_memif",    sub { uval($_[0]{GRBM2}{"Render Backend Memory Interface"}) }],
	["utc_l2",      sub { uval($_[0]{GRBM2}{"Unified Translation Cache Level-2"}) }],

	# --- Sensors: temperatures (10) ---
	["t_edge",      sub { uval($_[0]{Sensors}{"Edge Temperature"}) }],
	["t_junc",      sub { uval($_[0]{Sensors}{"Junction Temperature"}) }],
	["t_mem",       sub { uval($_[0]{Sensors}{"Memory Temperature"}) }],
	["t_tctl",      sub { uval($_[0]{Sensors}{"CPU Tctl"}) }],
	["t_edg_crit",  sub { uval($_[0]{Sensors}{"Edge Critical Temperature"}) }],
	["t_jnc_crit",  sub { uval($_[0]{Sensors}{"Junction Critical Temperature"}) }],
	["t_mem_crit",  sub { uval($_[0]{Sensors}{"Memory Critical Temperature"}) }],
	["t_edg_emer",  sub { uval($_[0]{Sensors}{"Edge Emergency Temperature"}) }],
	["t_jnc_emer",  sub { uval($_[0]{Sensors}{"Junction Emergency Temperature"}) }],
	["t_mem_emer",  sub { uval($_[0]{Sensors}{"Memory Emergency Temperature"}) }],

	# --- Sensors: power (3) ---
	["p_avg",       sub { uval($_[0]{Sensors}{"Average Power"}) }],
	["p_input",     sub { uval($_[0]{Sensors}{"Input Power"}) }],
	["p_gfx",       sub { uval($_[0]{Sensors}{"GFX Power"}) }],

	# --- Sensors: clocks (2) ---
	["sclk",        sub { uval($_[0]{Sensors}{"GFX_SCLK"}) }],
	["mclk",        sub { uval($_[0]{Sensors}{"GFX_MCLK"}) }],

	# --- Sensors: voltage (2) ---
	["vddgfx",      sub { uval($_[0]{Sensors}{VDDGFX}) }],
	["vddnb",       sub { uval($_[0]{Sensors}{VDDNB}) }],

	# --- Sensors: fan / PCIe (2) ---
	["fan",         sub { uval($_[0]{Sensors}{Fan}) }],
	["pcie_lsp",    sub { uval($_[0]{Sensors}{"PCIe Link Speed"}) }],

	# --- Sensors: CPU core frequency array (2) ---
	["cpu_favg",    sub { cpu_freq_stat($_[0], "avg") }],
	["cpu_fmax",    sub { cpu_freq_stat($_[0], "max") }],

	# --- VRAM (4) ---
	["vram_tot",    sub { uval($_[0]{VRAM}{"Total VRAM"}) }],
	["vram_use",    sub { uval($_[0]{VRAM}{"Total VRAM Usage"}) }],
	["gtt_tot",     sub { uval($_[0]{VRAM}{"Total GTT"}) }],
	["gtt_use",     sub { uval($_[0]{VRAM}{"Total GTT Usage"}) }],

	# --- gpu_metrics: temperatures (7), raw values are x100 degC;
	#     temperature_core is an array with 0 = absent on APUs ---
	["gm_t_gfx",    sub { gm($_[0], "temperature_gfx", 100) }],
	["gm_t_soc",    sub { gm($_[0], "temperature_soc", 100) }],
	["gm_t_edge",   sub { gm($_[0], "temperature_edge", 100) }],
	["gm_t_hot",    sub { gm($_[0], "temperature_hotspot", 100) }],
	["gm_t_mem",    sub { gm($_[0], "temperature_mem", 100) }],
	["gm_t_l3",     sub { gm($_[0], "temperature_l3", 100) }],
	["gm_t_core",   sub { my $a = avg_positive($_[0]{gpu_metrics}{temperature_core});
	                      defined($a) ? $a / 100 : undef }],

	# --- gpu_metrics: average frequencies (6), MHz ---
	["gm_agfxclk",  sub { gm($_[0], "average_gfxclk_frequency", 0) }],
	["gm_afclk",    sub { gm($_[0], "average_fclk_frequency", 0) }],
	["gm_auclk",    sub { gm($_[0], "average_uclk_frequency", 0) }],
	["gm_asocclk",  sub { gm($_[0], "average_socclk_frequency", 0) }],
	["gm_avclk",    sub { gm($_[0], "average_vclk_frequency", 0) }],
	["gm_adclk",    sub { gm($_[0], "average_dclk_frequency", 0) }],

	# --- gpu_metrics: average powers (4), raw mW -> W ---
	["gm_p_sock",   sub { gm($_[0], "average_socket_power", 1000) }],
	["gm_p_cpu",    sub { gm($_[0], "average_cpu_power", 1000) }],
	["gm_p_gfx",    sub { gm($_[0], "average_gfx_power", 1000) }],
	["gm_p_soc",    sub { gm($_[0], "average_soc_power", 1000) }],

	# --- gpu_metrics: voltages (3), mV ---
	["gm_v_gfx",    sub { gm($_[0], "voltage_gfx", 0) }],
	["gm_v_soc",    sub { gm($_[0], "voltage_soc", 0) }],
	["gm_v_mem",    sub { gm($_[0], "voltage_mem", 0) }],

	# --- gpu_metrics: fan (1) ---
	["gm_fan_pwm",  sub { gm($_[0], "fan_pwm", 0) }],

	# --- fdinfo totals (12) + process count (1) ---
	["fd_cpu",      sub { uval($_[0]{"Total fdinfo"}{CPU}) }],
	["fd_comp",     sub { uval($_[0]{"Total fdinfo"}{Compute}) }],
	["fd_dma",      sub { uval($_[0]{"Total fdinfo"}{DMA}) }],
	["fd_dec",      sub { uval($_[0]{"Total fdinfo"}{Decode}) }],
	["fd_enc",      sub { uval($_[0]{"Total fdinfo"}{Encode}) }],
	["fd_gfx",      sub { uval($_[0]{"Total fdinfo"}{GFX}) }],
	["fd_media",    sub { uval($_[0]{"Total fdinfo"}{Media}) }],
	["fd_jpeg",     sub { uval($_[0]{"Total fdinfo"}{VCN_JPEG}) }],
	["fd_vcn",      sub { uval($_[0]{"Total fdinfo"}{VCN_Unified}) }],
	["fd_vpe",      sub { uval($_[0]{"Total fdinfo"}{VPE}) }],
	["fd_vram",     sub { uval($_[0]{"Total fdinfo"}{VRAM}) }],
	["fd_gtt",      sub { uval($_[0]{"Total fdinfo"}{GTT}) }],
	["proc_count",  sub { ref($_[0]{fdinfo}) eq "HASH" ? scalar(keys(%{$_[0]{fdinfo}})) : undef }],
);

my $number_of_values_per_gpu_in_rrd = scalar(@DSPEC);	# 79

# ---------------------------------------------------------------------------
# collect_json(cmd => ..., no_pc => 0|1, file => path) -> ($data, $error)
#
# One-shot invocation of amdgpu_top; '-n 1' must be part of cmd so the
# command terminates on its own. With 'file' the JSON document is read from
# that file instead (offline tests / dry runs).
# Returns the decoded document or an error.
# ---------------------------------------------------------------------------
sub collect_json {
	my ($myself, %o) = @_;

	my $raw;

	if($o{file}) {
		my $fh;
		unless(open($fh, "<", $o{file})) {
			return (undef, "unable to open '$o{file}': $!");
		}
		{
			local $/;
			$raw = <$fh>;
		}
		close($fh);
	}
	else {
		my $cmd = $o{cmd} || "amdgpu_top -J -n 1";
		my @argv = (split(/\s+/, $cmd), ($o{no_pc} ? ("--no-pc") : ()));

		logger("$myself: executing '" . join(" ", @argv) . "'.") if $o{debug};

		my $fh;
		unless(open($fh, "-|", @argv)) {
			return (undef, "unable to execute '" . join(" ", @argv) . "': $!");
		}
		{
			local $/;
			$raw = <$fh>;
		}
		unless(close($fh)) {
			return (undef, "'" . join(" ", @argv) . "' exited with status " . ($? >> 8));
		}
	}

	return (undef, "empty output") unless(defined($raw) && length($raw));

	my $data = eval { decode_json($raw) };
	if($@ || !defined($data)) {
		return (undef, "JSON parse error: " . ($@ || "undefined result"));
	}
	unless(ref($data) eq "HASH" && ref($data->{devices}) eq "ARRAY") {
		if(ref($data) eq "ARRAY") {	# normalize '--dump' style output
			return ({ devices => $data }, undef);
		}
		return (undef, "unexpected JSON structure");
	}
	return ($data, undef);
}

# extract_values($device_hashref) -> hashref { ds_suffix => number|undef }
sub extract_values {
	my ($dev) = @_;
	return undef unless ref($dev) eq "HASH";
	my %v;
	foreach my $s (@DSPEC) {
		my $val = eval { $s->[1]->($dev) };
		$v{$s->[0]} = num($val);
	}
	return \%v;
}

# ---------------------------------------------------------------------------
# module init
# ---------------------------------------------------------------------------
sub amdgpu_top_init {
	my $myself = (caller(0))[3];
	my ($package, $config, $debug) = @_;
	my $rrd = $config->{base_lib} . $package . ".rrd";
	my $amdgpu_top = $config->{amdgpu_top};

	my $info;
	my @ds;
	my @rra;
	my @tmp;
	my $n;

	my @average;
	my @min;
	my @max;
	my @last;

	if(grep {$_ eq $config->{os}} ("FreeBSD", "OpenBSD", "NetBSD")) {
		logger("$myself is not supported yet by your operating system ($config->{os}).");
		return;
	}

	if(!keys(%{$amdgpu_top->{list}})) {
		logger("$myself: ERROR: no <list>...</list> defined.");
		return;
	}

	# option defaults
	if(!defined($amdgpu_top->{cmd})) {
		$amdgpu_top->{cmd} = "amdgpu_top -J -n 1";
	}
	my $use_nan_for_missing_data = lc($amdgpu_top->{use_nan_for_missing_data} || "") eq "y" ? 1 : 0;

	# checks if the command works and returns parseable JSON
	{
		my ($data, $err) = collect_json($myself,
			cmd   => $amdgpu_top->{cmd},
			file  => $amdgpu_top->{file},
			no_pc => lc($amdgpu_top->{no_pc} || "") eq "y" ? 1 : 0);
		if($err) {
			logger("$myself: ERROR: $err");
			return;
		}
		if(!scalar(@{$data->{devices}})) {
			logger("$myself: ERROR: amdgpu_top returned no AMD GPU device.");
			return;
		}
	}

	# total number of device slots over all groups
	my $total_number_of_gpus = 0;
	foreach my $k (sort keys %{$amdgpu_top->{list}}) {
		my @gpu_group = split(', ', $amdgpu_top->{list}->{$k});
		$total_number_of_gpus += ($max_number_of_gpus < scalar(@gpu_group) ? $max_number_of_gpus : scalar(@gpu_group));
		if($max_number_of_gpus < scalar(@gpu_group)) {
			logger("$myself: WARNING: group $k has more than $max_number_of_gpus devices, only the first $max_number_of_gpus will be monitored.");
		}
	}

	if(-e $rrd) {
		my $rrd_n_values = 0;
		$info = RRDs::info($rrd);
		for my $key (keys %$info) {
			if(index($key, 'ds[') == 0) {
				push(@ds, substr($key, 3, index($key, ']') - 3)) if(index($key, '.type') != -1);
				$rrd_n_values++ if(index($key, '.index') != -1);
			}
			if(index($key, 'rra[') == 0) {
				push(@rra, substr($key, 4, index($key, ']') - 4)) if(index($key, '.rows') != -1);
			}
		}
		if($rrd_n_values != $total_number_of_gpus * $number_of_values_per_gpu_in_rrd) {
			logger("$myself: Detected size mismatch between <list>...</list> (" . ($total_number_of_gpus * $number_of_values_per_gpu_in_rrd) . ") and $rrd (" . $rrd_n_values . "). Resizing it accordingly. All historical data will be lost. Backup file created.");
			rename($rrd, "$rrd.bak");
		}
		if(scalar(@rra) < 12 + (4 * $config->{max_historic_years})) {
			logger("$myself: Detected size mismatch between 'max_historic_years' (" . $config->{max_historic_years} . ") and $rrd (" . ((scalar(@rra) - 12) / 4) . "). Resizing it accordingly. All historical data will be lost. Backup file created.");
			rename($rrd, "$rrd.bak");
		}
	}

	if(!(-e $rrd)) {
		logger("Creating '$rrd' file.");
		for($n = 1; $n <= $config->{max_historic_years}; $n++) {
			push(@average, "RRA:AVERAGE:0.5:1440:" . (365 * $n));
			push(@min, "RRA:MIN:0.5:1440:" . (365 * $n));
			push(@max, "RRA:MAX:0.5:1440:" . (365 * $n));
			push(@last, "RRA:LAST:0.5:1440:" . (365 * $n));
		}
		my @group_keys = sort keys %{$amdgpu_top->{list}};
		for(my $k = 0; $k < scalar(@group_keys); $k++) {
			my @gpu_group = split(', ', $amdgpu_top->{list}->{$group_keys[$k]});
			for($n = 0; $n < scalar(@gpu_group) && $n < $max_number_of_gpus; $n++) {
				foreach my $s (@DSPEC) {
					push(@tmp, "DS:e" . $k . "d" . $n . "_" . $s->[0] . ":GAUGE:120:0:U");
				}
			}
		}
		eval {
			RRDs::create($rrd,
			"--step=60",
			@tmp,
			"RRA:AVERAGE:0.5:1:1440",
			"RRA:AVERAGE:0.5:30:336",
			"RRA:AVERAGE:0.5:60:744",
			@average,
			"RRA:MIN:0.5:1:1440",
			"RRA:MIN:0.5:30:336",
			"RRA:MIN:0.5:60:744",
			@min,
			"RRA:MAX:0.5:1:1440",
			"RRA:MAX:0.5:30:336",
			"RRA:MAX:0.5:60:744",
			@max,
			"RRA:LAST:0.5:1:1440",
			"RRA:LAST:0.5:30:336",
			"RRA:LAST:0.5:60:744",
			@last,
			);
		};
		my $err = RRDs::error;
		if($@ || $err) {
			logger("$@") unless !$@;
			if($err) {
				logger("ERROR: while creating $rrd: $err");
				if($err eq "RRDs::error") {
					logger("... is the RRDtool Perl package installed?");
				}
			}
			return;
		}
	}

	$config->{amdgpu_top_hist} = ();
	push(@{$config->{func_update}}, $package);

	logger("$myself: Ok") if $debug;
}

# ---------------------------------------------------------------------------
# module update (called every minute by the Monitorix daemon)
# ---------------------------------------------------------------------------
sub amdgpu_top_update {
	my $myself = (caller(0))[3];
	my ($package, $config, $debug) = @_;
	my $rrd = $config->{base_lib} . $package . ".rrd";
	my $amdgpu_top = $config->{amdgpu_top};

	my $use_nan_for_missing_data = lc($amdgpu_top->{use_nan_for_missing_data} || "") eq "y" ? 1 : 0;
	my $fill = $use_nan_for_missing_data ? "U" : "0";

	my ($data, $err) = collect_json($myself,
		cmd   => $amdgpu_top->{cmd},
		file  => $amdgpu_top->{file},
		no_pc => lc($amdgpu_top->{no_pc} || "") eq "y" ? 1 : 0,
		debug => $debug);

	if($err) {
		logger("$myself: WARNING: $err; writing missing values instead.");
	}

	my $devices = ref($data) eq "HASH" ? $data->{devices} : [];

	my $rrdata = "N";
	my %extract_cache;

	# iteration order must be identical to the RRD creation order in _init!
	my @group_keys = sort keys %{$amdgpu_top->{list}};
	for(my $k = 0; $k < scalar(@group_keys); $k++) {
		my @gpu_group = split(', ', $amdgpu_top->{list}->{$group_keys[$k]});
		for(my $n = 0; $n < scalar(@gpu_group) && $n < $max_number_of_gpus; $n++) {
			# NOTE: do not use trim() here - Monitorix' trim() returns an
			# empty string for the (valid) device index "0".
			my $idx = defined($gpu_group[$n]) ? $gpu_group[$n] : "";
			$idx =~ s/^\s+//;
			$idx =~ s/\s+$//;
			$idx =~ s/^\"//;
			$idx =~ s/\"$//;

			my $vals;
			if($idx =~ /^\d+$/) {
				if(exists($extract_cache{$idx})) {
					$vals = $extract_cache{$idx};
				}
				else {
					$vals = extract_values($devices->[$idx]);
					$extract_cache{$idx} = $vals;
					if(!defined($vals) && defined($data)) {
						logger("$myself: WARNING: device index $idx not found in amdgpu_top output (group " . $group_keys[$k] . ").");
					}
				}
			}
			else {
				logger("$myself: ERROR: invalid device index '$gpu_group[$n]' in group " . $group_keys[$k] . ".");
			}

			foreach my $s (@DSPEC) {
				my $v = defined($vals) ? $vals->{$s->[0]} : undef;
				$rrdata .= ":" . (defined($v) ? $v : $fill);
			}
		}
	}

	RRDs::update($rrd, $rrdata);
	logger("$myself: $rrdata") if $debug;
	my $rrderr = RRDs::error;
	logger("ERROR: while updating $rrd: $rrderr") if $rrderr;
}

1;
