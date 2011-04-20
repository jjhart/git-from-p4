#! /usr/bin/perl

use Cwd;
use FindBin qw($Bin);
use File::Basename qw(basename);
use File::Slurp;
use Getopt::Long;

use strict;
use warnings;

#--------------------------------------------------------------------------------
# global options, many configurable via Getopt::Long
#--------------------------------------------------------------------------------
my $AUTHOR    = 'John Hart <john.hart@ihance.com>';
my $BRANCH    = 'master';
my $BATCHSIZE = 10;
my $MARKS     = $ENV{HOME} . '/marks';
my $P4WAIT    = 30; # initial p4cmd timeout, backs off to 10 minutes
my $PREFIX;
my $SPOT;
my $CHANGE;
my $LAST;
my @DIRS;
my ($D, $V);
#--------------------------------------------------------------------------------


get_opts();

spot_check($SPOT), exit(0) if $SPOT;

my @cls = p4_get_cls(@DIRS);
@cls = grep { (!$CHANGE || $CHANGE < $_) && (!$LAST || $LAST >= $_) } @cls;
map { do_cl_batch($_, @DIRS) } split_list($BATCHSIZE, @cls);

exit(0);



#--------------------------------------------------------------------------------
# main subs
#--------------------------------------------------------------------------------

# open the GIT output handle as a pipe to git fast import (git_import_cmd())
# then calling import_cl for each changelist
sub do_cl_batch {
	my ($cls, @dirs) = @_;
	redir_io( sub { map { do_cl($_, @dirs) } @$cls; }, git_import_cmd());
	print STDERR `git log -1 | head -1`;
	}

# import a single changelist (sync files & dump to STDOUT)
sub do_cl {
	my ($cl, @dirs) = @_;
	print STDERR "syncing to $cl...\n";
	my ($date, $desc) = p4_sync($cl, @DIRS);
	print_preamble($date, $desc, $cl);
	map { -d and git_dump($_) } @dirs;
	}

# more elegantly done with recursion, car/cdr style, but call stack gets too deep
sub split_list {
	my ($size, @l) = @_;
	my @ret = ();
	do { 
		push(@ret, [ @l <= $size ? @l : @l[0 .. ($size-1)] ]);
		@l = @l <= $size ? () : @l[$size .. (@l-1)];
		}
	while (@l);
	@ret;
	}

#--------------------------------------------------------------------------------
# spot check
#--------------------------------------------------------------------------------
sub spot_check {
	my ($co) = @_;
	cmd("git checkout $co 2> /dev/null");
	my ($cl) = grep { /^\s+\[Perforce change \d+\]/ } cmd("git log -1 $co");
	($cl) = ($cl =~ /\s+\[Perforce change (\d+)\]/);
	p4_sync($cl, @DIRS);
	map { spot_check_dir($_) } @DIRS;
	}

sub spot_check_dir {
	my ($d) = @_;
	my ($gd) = git_path($_);
	print("skip - $d\n"), return unless -d $d && -d $gd;
	system(sprintf('diff -rbq %s %s', $gd, $d)) or print ("good - $gd\n");
	}

#--------------------------------------------------------------------------------
# p4
#--------------------------------------------------------------------------------

# get a sorted list of call changelists that touch the given dirs
sub p4_get_cls {
	my (@dirs) = @_;
	sort { $a <=> $b } uniq(map { s~^Change ~~; s~ .*$~~s; $_ } p4cmd('p4 changes -i %s', join(' ', map { "$_/..." } @dirs)));
	}

# syncs the given directories to the given CL
# returns a (date, description) pair for the CL
sub p4_sync {
	my ($cl, @dirs) = @_;
	# note the STDERR redirect & grep to ignore these two warning types
	p4cmd('p4 sync %s 2>&1 | grep -v -e " - file(s) up to date.$" -e " - no file(s) at that changelist number.$"', join(' ', map { "$_/...\@$cl" } @dirs));
	p4_clean(@dirs);
	p4_desc_cl($cl);
	}

sub p4_clean {
	my (@dirs) = @_;
	my $d = cwd();
	map { -d and chdir($_) and cmd("find . -empty -delete") } @dirs;
	chdir($d);
	}

# Extracts a timestamp & changelist description for the given changelist
sub p4_desc_cl {
	my ($cl) = @_;
	my $txt = p4cmd('p4 describe -s %s', $cl);
	my ($date) = ($txt =~ /^Change $cl by .* on (\d+.*)$/m) or die("Could not parse change $cl: $txt");
	$txt =~ s~^Affected files \.\.\..*~~ms; # strip entire list of effected files
	$txt =~ s~^.*\n\n~~m;
	$txt =~ s~^\t~~mg;
	$txt =~ s~\n*$~~s;
	($date, $txt);
	}

#--------------------------------------------------------------------------------
# git
#--------------------------------------------------------------------------------
sub git_import_cmd {
	return ">> $D" if $D;
	my $quiet = $V ? '' : '--quiet';
	-f $MARKS
		? "| git fast-import $quiet --export-marks='$MARKS' --import-marks='$MARKS'"
		: "| git fast-import $quiet --export-marks='$MARKS'";
	}

sub print_preamble {
	my ($date, $desc, $cl) = @_;

	# translates a p4 date (2011/12/13 16:32:43) into git epoch-seconds-plus-offset
	my $gitdate = cmd(qq{date -j -f "%Y/%m/%d %H:%M:%S" '$date' "+%s %z"});
	chomp($gitdate);

	print "commit refs/heads/$BRANCH\n";
	print "mark :$cl\n";
	print "committer $AUTHOR $gitdate\n";
	print_txt("$desc\n\n[Perforce change $cl]\n");
	print "from :$CHANGE\n" if $CHANGE;
	print "deleteall\n";
	$CHANGE = $cl;
	}

sub read_marks {
	return undef unless -f $MARKS;
	my @lines = read_file($MARKS);
	local $_ = @lines[@lines-1] || die("$MARKS file is empty");
	(/^:(\d+) .*$/);
	}

sub print_txt {
	my ($txt) = @_;
	my ($len) = length($txt);
	print "data $len\n$txt";
	}

sub git_path {
	my ($f) = @_;
	$f =~ s~^\Q$PREFIX\E~~;
	$f;
	}

sub git_dump {
	my ($f) = @_;
	-d $f and return map { git_dump("$f/$_") } read_dir($f);
	my $gitpath = git_path($f);

	my $text = read_file($f);
	my $mode = -x $f ? '755' : '644';
	print "M $mode inline $gitpath\n";
	print_txt($text);
	}

#--------------------------------------------------------------------------------
# helpers
#--------------------------------------------------------------------------------
sub uniq { my %uniq = map { $_ => 1 } @_; keys(%uniq); }
sub hdr  { printf("%s\n%s\n%1\$s\n", '-'x80, @_);      }

sub redir_io {
	my ($func, $redir_to) = @_;
	
  open GIT, $redir_to or die "Can't open GIT output ($redir_to): $!";
  binmode(GIT, ':raw');
  select GIT and $| = 1; # send $func's "print" output to GIT, set autoflush

	$func->();
	
	close(GIT);
  }


# elegant little LCP finder mod'd from http://linux.seindal.dk/2005/09/09/longest-common-prefix-in-perl
sub longest_common_prefix {
	my $prefix = shift;
	map { chop $prefix while (! /^\Q$prefix\E/); } @_;
	$prefix;
	}

#--------------------------------------------------------------------------------
# shellouts
#--------------------------------------------------------------------------------
sub cmd {
	my ($cmd, @args) = @_;
	$cmd = sprintf($cmd, @args) if @args;
	$V and print STDERR "$cmd\n";
	my @ret = `$cmd`;
	$? and die("Failure executing '$cmd': $?");
	wantarray ? @ret : join('', @ret);
	}


# p4 hangs alot.  this wraps cmd in a timeout (in $Bin/timeout)
sub p4cmd {
	my ($cmd, @args) = @_;

	my ($wait, $i, @ret) = ($P4WAIT);
	for ($i = 0; $i < 10; $i++) {
		eval { @ret = cmd($Bin . "/timeout -t $wait $cmd", @args); };
		$@ or return wantarray ? @ret : join('', @ret);
		$@ =~ /^Failure executing/ or die($@);
		$wait = 2 * ($wait < 300 ? $wait : 300);
		}

	die("Quitting after $i tries: $cmd\n");
	}

#--------------------------------------------------------------------------------
# options
#--------------------------------------------------------------------------------
sub get_opts {
	my ($help) = 0;
	
  GetOptions(
  	 'author=s'   => \$AUTHOR
  	,'branch=s'   => \$BRANCH
  	,'mark=s' 	  => \$MARKS
  	,'prefix=s'   => \$PREFIX
  	,'change=i'   => \$CHANGE
  	,'last=i'     => \$LAST
  	,'wait=i'     => \$P4WAIT
  	,'spot=s'     => \$SPOT
  	,'debug=s'    => \$D
  	,'verbose'    => \$V
  	,'help|?'  	  => \$help) or $help = 1;
	$help = 1 unless $BRANCH;
	help_exit() if $help;


	$SPOT || $CHANGE || ! -f $MARKS or help_exit("Marks file exists ($MARKS), specify --change to continue");

	@DIRS = @ARGV or help_exit("Must specify at least one directory!");
	map { s~/$~~ } @DIRS; # don't want trailing "/" in our dirs

	$PREFIX ||= longest_common_prefix(@DIRS);
	}

sub help_exit {
  my ($err) = @_;

	print STDERR "ERROR: $err\n" if $err;

	my $name = basename($0);

  print STDERR <<EOH;

Usage: $name <options> DIR1 [DIR2, ...]

Options:

  -a, --author   Author name to use for all commits

  -b, --branch   Git branch to import into [ master ]

  -m, --marks    git marks file [ ~/marks ]
  -c, --change   p4 changelist # of the last mark; required if marks file exists
  -l, --last     p4 changelist # to stop after

  -p, --prefix   Directory prefix to strip from DIRS when importing
                 If not specified, uses the longest common prefix of the DIRS

  -d, --debug    debug mode - append the p4 export to this file, rather than
                 rather than piping to git --fast-import.  You could cat this
                 file to fast-import later to get the same end result.

  -w, --wait     Initial p4 command timeout in seconds [ 30 ].
                 p4 hangs a lot, so p4 commands are retried if they don't complete
                 within the timeout window.  retries use an exponential backoff
                 strategy - timeout doubles each retry to a max of 10 minutes.

  -s, --spot     spotcheck mode - sync both repos to given commit

Import the full P4 history of the given directories into the current git repo.

If a directory has moved in p4, you must provide both the old & new paths as arguments.

As this command must be run from the git directory, the DIR arguments will necessarily
be prefixed with a bunch of stuff (relative "../../" or absolute paths).  By default,
the longest common prefix of the DIRS will be used, but you can use -p to override this.

examples:

  $name -p ../../oldsrc/ -a 'Bob Jones <bj\@yada.com>' ../../oldsrc/lib ../../oldsrc/bin

  $name                  -a 'Bob Jones <bj\@yada.com>' ../../oldsrc/lib ../../oldsrc/bin

Both commands will import "lib" and "bin" at the root of the current git repo.

EOH

	exit(1);
	}

