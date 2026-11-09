#!/usr/bin/perl
#
# t_cgi.pl - offline test for amdgpu_top_cgi() (Monitorix module)
#
# Reproduces the %config/%cgi environment of /var/lib/monitorix/www/cgi/
# monitorix.cgi (config + conf.d merge, tf/colors/version12 structures) and
# calls the module's CGI function directly, so runtime errors become visible
# (the real CGI hides them inside forked children).
#
# Usage: ./t_cgi.pl [--when day|week] [--text]
#
# Exit codes: 0 = all checks passed, 1 = failures (listed)
#

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin";			# amdgpu_top.pm
use lib "/usr/lib/monitorix";	# Monitorix.pm
use Config::General;
use File::Path qw(make_path);
use File::Copy;
use RRDs;
use Encode qw(decode encode);
use amdgpu_top;

$| = 1;

my $when = "day";
my $text_mode = 0;
while(@ARGV) {
	my $a = shift(@ARGV);
	if($a eq "--when")   { $when = shift(@ARGV) }
	elsif($a eq "--text") { $text_mode = 1 }
	else { die "Usage: $0 [--when day|week] [--text]\n" }
}

my $failures = 0;
sub check {
	my ($desc, $ok, $detail) = @_;
	printf("[%s] %s%s\n", $ok ? " OK " : "FAIL", $desc, defined($detail) ? " ($detail)" : "");
	$failures++ unless $ok;
}

# ---------------------------------------------------------------------------
# 1. %config exactly like monitorix.cgi builds it
# ---------------------------------------------------------------------------
my $split_policy = "guess";
my $conf = new Config::General(-ConfigFile => "/etc/monitorix/monitorix.conf", -SplitPolicy => $split_policy);
my %config = $conf->getall;

if($config{include_dir} && opendir(my $DIR, $config{include_dir})) {
	my @files = grep { !/^[.]/ } readdir($DIR);
	closedir($DIR);
	foreach my $c (sort @files) {
		next unless -f $config{include_dir} . "/$c";
		next unless $c =~ m/\.conf$/;
		my $conf_inc = new Config::General(-ConfigFile => $config{include_dir} . "/$c", -SplitPolicy => $split_policy);
		my %config_inc = $conf_inc->getall;
		while(my ($key, $val) = each(%config_inc)) {
			if(ref($val) eq "HASH") {
				while(my ($key2, $val2) = each(%{$val})) {
					delete($config{$key}->{$key2});
					$config{$key}->{$key2} = $val2;
				}
				next;
			}
			if($key eq "additional_graph_name") {
				$config{graph_name} .= ", $val";
				next;
			}
			$config{$key} = $val;
		}
	}
}
check("graph_name includes amdgpu_top", (grep { $_ =~ /^\s*amdgpu_top\s*$/ } split(',', $config{graph_name})) >= 1);
check("graph_enable amdgpu_top = y", lc($config{graph_enable}->{amdgpu_top} || "") eq "y");
check("module title via graph_title", defined($config{graph_title}->{amdgpu_top}));
check("plot titles via graphs->{_amdgpu_topN}", defined($config{graphs}->{_amdgpu_top1}));

# scratch output directory instead of the real web imgs dir
my $img_base = "/tmp/opencode/t_cgi_www";
system("rm -rf $img_base") == 0 or die "cannot clean $img_base (leftover root files? run: sudo rm -rf $img_base)\n";
make_path("$img_base/" . $config{imgs_dir}) or die "cannot create $img_base/" . $config{imgs_dir};
$config{base_dir} = $img_base;
$config{iface_mode} = $text_mode ? "text" : "graph";

# ---------------------------------------------------------------------------
# 2. %cgi structures (mirrors monitorix.cgi)
# ---------------------------------------------------------------------------
my %tf;
($tf{twhen}) = ($when =~ m/^\d+(hour|day|week|month|year)$/);
($tf{nwhen} = $when) =~ s/$tf{twhen}// unless !$tf{twhen};
$tf{nwhen} = 1 unless $tf{nwhen};
$tf{twhen} = "day" unless $tf{twhen};
$tf{when} = $tf{nwhen} . $tf{twhen};
if($tf{twhen} eq "day")   { ($tf{res}, $tf{tc}, $tf{tb}, $tf{ts}) = (3600, 'h', 24, 1) }
else                      { ($tf{res}, $tf{tc}, $tf{tb}, $tf{ts}) = (108000, 'd', 7, 1) }

my $color = "white";
$config{theme}->{$color} ||= {};
for my $d (["main_bg","FFFFFF"],["main_fg","000000"],["title_bg","777777"],["title_fg","CCCC00"],
           ["graph_bg","CCCCCC"],["gap","000000"]) {
	$config{theme}->{$color}->{$d->[0]} ||= $d->[1];
}
my %colors;
$colors{graph_colors} = [];
$colors{fg_color} = $config{theme}->{$color}->{main_fg};
$colors{gap} = $config{theme}->{$color}->{gap};

my @version12 = ("--slope-mode", "--font=LEGEND:7:", "--font=TITLE:9:", "--font=UNIT:8:");
push(@version12, "--font=DEFAULT:0:Mono");
push(@version12, "--x-grid=HOUR:1:HOUR:6:HOUR:6:0:%R") if $tf{twhen} eq "day";
my @version12_small = ("--font=TITLE:8:", "--font=UNIT:7:", "--font=DEFAULT:0:Mono");

$config{global_zoom} ||= 1;
$config{image_format} ||= "PNG";
$config{url} = "http://localhost:8080";	# normally built by monitorix.cgi

my %cgi = (
	colors		=> \%colors,
	tf		=> \%tf,
	version12	=> \@version12,
	version12_small	=> \@version12_small,
	graph		=> "amdgpu_top",
	when		=> $when,
	color		=> $color,
	val		=> "",
	silent		=> "",
);

# stubs for the helper subs that live inside monitorix.cgi (package main)
{
	no strict 'refs';
	*{'main::graph_header'} = sub {
		my ($title, $colspan) = @_;
		return "\n<!-- graph table begins -->\n  <table class='table-module' width='1' >\n    <tr>\n      <td class='td-title' colspan='" . ($colspan // 1) . "'>\n          <b>&nbsp;&nbsp;$title</b>\n      </td>\n    </tr>\n";
	};
	*{'main::graph_footer'} = sub {
		return "  </table>\n<!-- graph table ends -->\n";
	};
}

# ---------------------------------------------------------------------------
# 3. call the CGI function (graph mode)
# ---------------------------------------------------------------------------
print "== amdgpu_top_cgi (iface_mode=$config{iface_mode}, when=$tf{when}) ==\n";
my @out;
my @warns;
local $SIG{__WARN__} = sub { push(@warns, $_[0]) };
eval { @out = amdgpu_top_cgi("amdgpu_top", \%config, \%cgi) };
check("no exception", !$@, $@ ? encode("utf-8", "$@") : "");

my $html = join("", map { eval { decode("utf-8", $_) } // $_ } @out);
open(my $DUMP, ">", "/tmp/opencode/t_cgi_" . ($text_mode ? "text" : "graph") . ".html");
print {$DUMP} $html;
close($DUMP);
check("output non-empty", length($html) > 0, length($html) . " bytes");
check("no Perl warnings", !@warns, @warns ? scalar(@warns) . " warnings: " . encode("utf-8", $warns[0]) : "");
check("no ERROR text", $html !~ /ERROR/, ($html =~ /(ERROR[^\n]*)/) ? encode("utf-8", $1) : "");

if($text_mode) {
	check("text header 'Time'", $html =~ /^Time .*GFX%/m);
	my $text_rows = () = $html =~ /^ *\d+[hd] .+/mg;
	check("text rows present", $text_rows > 0, "$text_rows rows");
	check("info block (show_info)", $html =~ /Radeon \S+ Graphics/, "");
}
else {
	# IMG elements for 10 panels (+ zoom variants if enable_zoom=y)
	my @imgs;
	my %seen;
	while($html =~ /(amdgpu_top\d+ z? \. $tf{when} \. png)/gx) { $seen{$1}++ }
	@imgs = sort keys %seen;

	my $generated = 0;
	my $empty = 0;
	foreach my $f (@imgs) {
		my $path = "$img_base/" . $config{imgs_dir} . "/$f";
		if(-e $path && -s $path > 1000) { $generated++ } else { $empty++ }
	}
	check("all PNGs generated >1KB ($generated/" . scalar(@imgs) . ")", $empty == 0);

	# plot titles from <graphs> must appear in page or in PNG (title is drawn
	# into the image, so verify the DEF-side via rrdtool graph error check:
	# already covered by 'no ERROR'); verify html image count only here.
}

print "\n== result ==\n";
if($failures) {
	print "FAILED checks: $failures\n";
	exit(1);
}
print "ALL CHECKS PASSED\n";
exit(0);
