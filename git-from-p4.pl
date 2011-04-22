#! /usr/bin/perl

use Cwd;
use FindBin qw($Bin);
use File::Basename qw(basename);
use File::Path;
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
my $SYNCWAIT  = 240;
my $PREFIX;
my $SPOT;
my $CHANGE;
my $LAST;
my @DIRS;
my ($D, $V);
my $HELPSTR = helpstr(); # define before getopt so it can show default values
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
	my ($cl) = @_;
	my $co = readcmd("git log master | grep -e commit -e '\\[Perforce change $cl' | grep -B1 '\\[Perforce change $cl' | cut -d' ' -f 2");
	while (chomp($co)) {}
	readcmd("git checkout $co 2> /dev/null");
	p4_sync($cl, @DIRS);
	map { spot_check_dir($_) } @DIRS;
	}

sub spot_check_dir {
	my ($d) = @_;
	my ($gd) = git_path($_);
	print("::SKIP - $d\n"), return unless -d $d && -d $gd;
	system(sprintf('diff -rbq %s %s', $gd, $d))
		? print "::DIFF $gd\n"
		: print "::GOOD $gd\n";
	}

#--------------------------------------------------------------------------------
# p4
#--------------------------------------------------------------------------------

# get a sorted list of call changelists that touch the given dirs
sub p4_get_cls {
	my (@dirs) = @_;
	sort { $a <=> $b } uniq(map { s~^Change ~~; s~ .*$~~s; $_ } readcmd2('p4 changes -i %s', join(' ', map { "$_/..." } @dirs)));
	}

# syncs the given directories to the given CL
# returns a (date, description) pair for the CL
sub p4_sync {
	my ($cl, @dirs) = @_;
	map { p4_sync_dir($cl, $_) } @dirs;
	p4_desc_cl($cl);
	}

# standard sync of the given dir, then removes empty subdirs
# if standard sync fails, nukes the entire dir and does "p4 sync -f" to re-fetch all
sub p4_sync_dir {
	my ($cl, $d) = @_;
	onfail(sub { timeout($SYNCWAIT, "p4 sync $d/...\@$cl"); p4_clean($d); }) 
			->(sub { rmtree($d); timeout(4*$SYNCWAIT, "p4 sync -f $d/...\@$cl"); });
	}

sub p4_clean {
	my (@dirs) = @_;
	my $d = cwd();
	map { -d and chdir($_) and readcmd("find . -empty -delete") } @dirs;
	chdir($d);
	}

# Extracts a timestamp & changelist description for the given changelist
sub p4_desc_cl {
	my ($cl) = @_;
	my $txt = readcmd2('p4 describe -s %s', $cl);
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
	my $gitdate = readcmd(qq{date -j -f "%Y/%m/%d %H:%M:%S" '$date' "+%s %z"});
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
sub ret {	return wantarray ? @_ : join('', @_);	}

sub readcmd {
	my ($cmd, @args) = @_;
	$cmd = sprintf($cmd, @args) if @args;
	$V and print STDERR "$cmd\n";
	my @ret = `$cmd`;
	$? and die("Failure executing '$cmd': $?");
	ret(@ret);
	}

# try the same command twice if necessary
sub readcmd2 {
	my (@args) = @_;
	onfail(sub { readcmd(@args); })->(sub { readcmd(@args); });
	}

# wraps a call/fail/retry loop
# eg: onfail( $func1 )->( $func2_if_func1_fails )
sub onfail {
	my ($f1) = @_;
	return sub {
		my ($f2) = @_;
		my @ret = eval { $f1->(); };
		$@ or return ret(@ret);
		print(STDERR "retrying after $@");
		ret($f2->());
		}
	}

# note - 'timeout' doesn't work in qx/backticks (always waits the full timeout)
# so we have to use system instead, which is OK b/c we don't need the output
sub timeout {
	my ($wait, $cmd, @args) = @_;
	$cmd = sprintf($cmd, @args) if @args;
	system("${Bin}/timeout -t $wait $cmd");
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
  	,'wait=i'     => \$SYNCWAIT
  	,'spot=s'     => \$SPOT
  	,'debug=s'    => \$D
  	,'verbose'    => \$V
  	,'help|?'  	  => \$help) or $help = 1;
	$help = 1 unless $BRANCH && $AUTHOR;
	help_exit() if $help;

	$SPOT || $CHANGE || ! -f $MARKS or help_exit("Marks file exists ($MARKS), specify --change to continue");

	@DIRS = @ARGV or help_exit("Must specify at least one directory!");
	map { s~/$~~ } @DIRS; # don't want trailing "/" in our dirs

	$PREFIX ||= longest_common_prefix(@DIRS);
	}

sub help_exit {
  my ($err) = @_;
	print STDERR "ERROR: $err\n" if $err;
	print STDERR $HELPSTR;
	exit(1);
	}

sub helpstr {
	my $name = basename($0);

  return <<EOH;

Usage: $name <options> DIR1 [DIR2, ...]

Options:

  -a, --author   Author name to use for all commits
                 Defaults to "$AUTHOR"

  -b, --branch   Git branch to import into [ $BRANCH ]

  -m, --marks    git marks file [ ~/marks ]
  -c, --change   p4 changelist # of the last mark; required if marks file exists
  -l, --last     p4 changelist # to stop after

  -p, --prefix   Directory prefix to strip from DIRS when importing
                 If not specified, uses the longest common prefix of the DIRS

  -d, --debug    debug mode - append the p4 export to this file, rather than
                 rather than piping to git --fast-import.  You could cat this
                 file to fast-import later to get the same end result.

  -w, --wait     Timeout for first call to p4 sync for a given dir [ $SYNCWAIT ]
                 If sync fails or times out, we rm the whole directory and start
                 over with "p4 sync -f" with 4x the timeout.

  -s, --spot     spotcheck mode - sync P4 and git to the given mark & diff

Import the full P4 history of the given directories into the current git repo.  Note
the given DIRS may be only a subset of the p4 repo, that's ok.

Because p4 client commands can hang or otherwise misbehave, it's probably best to
run $name from within the same LAN as the p4 server.  It's certainly faster this way.

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

