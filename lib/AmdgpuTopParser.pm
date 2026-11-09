#
# AmdgpuTopParser - data collection and value extraction for the
#                   Monitorix 'amdgpu_top' module (standalone test version).
#
# Collects one JSON document from 'amdgpu_top -J -n 1' (one-shot mode)
# and extracts the fixed schema of RRD data sources (see plan.md section 2.2).
#
# This file is the test vehicle; the identical logic is inlined into
# /usr/lib/monitorix/amdgpu_top.pm during Step 2.
#

package AmdgpuTopParser;

use strict;
use warnings;
use Exporter 'import';
use JSON::PP;

our @EXPORT_OK = qw(collect_json extract_values ds_names ds_spec);

our $VERSION = "0.1";

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# numeric value of a {"unit": "...", "value": N} pair (undef if missing/null/non-numeric)
sub uval {
	my ($node) = @_;
	return undef unless ref($node) eq "HASH";
	my $v = $node->{value};
	return num($v);
}

# sanitize to plain number or undef
sub num {
	my ($v) = @_;
	return undef unless defined($v);
	return undef if(ref($v));
	# accept integers and decimals (reject '' , 'nan', 'inf', strings)
	return undef unless($v =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/);
	# reject inf/nan after numeric conversion (e.g. "9" x 1000 overflow not possible here, but keep guard)
	my $n = $v + 0;
	return undef if($n != $n);            # NaN
	return undef if($n == 9**9**9 || $n == -(9**9**9));
	return $n;
}

# average of positive array values (e.g. temperature_core with 0 = absent); undef if none
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
# DS spec: ordered list of [ ds-suffix (<= 19 chars, RRD limit), extractor ]
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
	#     temperature_core is a 16-entry array with 0 = absent on APUs ---
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

sub ds_spec   { return @DSPEC }
sub ds_names  { return map { $_->[0] } @DSPEC }

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
# collect_json(cmd => ..., no_pc => 0|1, file => path) -> ($data, $error)
#
# One-shot invocation of amdgpu_top ('-n 1' must be part of cmd) or offline
# read of a JSON sample file. Returns the decoded document or an error.
# ---------------------------------------------------------------------------
sub collect_json {
	my (%o) = @_;

	my $raw;

	if($o{file}) {
		my $fh;
		unless(open($fh, "<", $o{file})) {
			return (undef, "unable to open '$o{file}': $!");
		}
		local $/;
		$raw = <$fh>;
		close($fh);
	}
	else {
		my $cmd = $o{cmd} || "amdgpu_top -J -n 1";
		my @argv = (split(/\s+/, $cmd), ($o{no_pc} ? ("--no-pc") : ()));
		my $fh;
		unless(open($fh, "-|", @argv)) {
			return (undef, "unable to execute '" . join(" ", @argv) . "': $!");
		}
		local $/;
		$raw = <$fh>;
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
		# --dump output is a plain array of devices - normalize it
		if(ref($data) eq "ARRAY") {
			return ({ devices => $data }, undef);
		}
		return (undef, "unexpected JSON structure");
	}
	return ($data, undef);
}

1;
