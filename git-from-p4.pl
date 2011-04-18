#! /usr/bin/perl

use Date::Parse qw(str2time);
use File::Basename qw(basename);
use File::Slurp;
use Getopt::Long;

use strict;
use warnings;

#--------------------------------------------------------------------------------
# global options, many configurable via Getopt::Long
#--------------------------------------------------------------------------------
my $AUTHOR    = 'John Hart <john.hart@ihance.com>';
my $TZ        = '-0800';
my $BRANCH    = 'master';
my $BATCHSIZE = 10;
my $MARKS     = $ENV{HOME} . '/marks';
my $P4WAIT    = 30; # initial p4cmd timeout, backs off to 10 minutes
my $PREFIX;
my $CHANGE;
my @DIRS;
my ($D, $V);
#--------------------------------------------------------------------------------

get_opts();

my @cls = p4_get_cls(@DIRS);
@cls = grep { !$CHANGE || $CHANGE < $_ } @cls;
map { do_cl_batch($_, @DIRS) } split_list($BATCHSIZE, @cls);

exit(0);

#--------------------------------------------------------------------------------
# main
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
	map { git_dump($_) } @dirs;
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
	p4_desc_cl($cl);
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
	my ($prev) = read_marks($MARKS);
	my $mark = 1 + ($prev || 0);

	$date = str2time($date);

	print "commit refs/heads/$BRANCH\n";
	print "mark :$mark\n";
	print "committer $AUTHOR $date $TZ\n";
	print_txt("$desc\n\n[Perforce change $cl]\n");
	print "from :$prev\n" if $prev;
	print "deleteall\n";
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

sub git_dump {
	my ($f) = @_;
	-d $f and return map { git_dump("$f/$_") } read_dir($f);
	my $gitpath = $f;
	$gitpath =~ s~^\Q$PREFIX\E~~;

	my $text = read_file($f);
	my $mode = -x $f ? '755' : '644';
	print "M $mode inline $gitpath\n";
	print_txt($text);
	}

#--------------------------------------------------------------------------------
# helpers
#--------------------------------------------------------------------------------
sub uniq { my %uniq = map { $_ => 1 } @_; keys(%uniq); }
sub hdr  { printf("%s\n%s\n%1\$s\n", '-'x80, @_);       }

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


# p4 hangs alot.  this wrapper for cmd times out, kills, & retries
sub p4cmd {
	my (@args) = @_;

	my ($wait, @ret) = ($P4WAIT);
	do {
		eval {
			local $SIG{ALRM} = sub { die "alarm\n"; };
			alarm($wait);
			@ret = cmd(@args);
			alarm(0);
			$wait = 2 * ($wait < 300 ? $wait : 300);
			};
		} while ($@ && $@ eq "alarm\n");
	die($@) if $@ && $@ ne "alarm\n";

	wantarray ? @ret : join('', @ret);
	}

#--------------------------------------------------------------------------------
# options
#--------------------------------------------------------------------------------
sub get_opts {
	my ($help) = 0;
	
  GetOptions(
  	 'author=s'   => \$AUTHOR
  	,'timezone=s' => \$TZ
  	,'branch=s'   => \$BRANCH
  	,'mark=s' 	  => \$MARKS
  	,'prefix=s'   => \$PREFIX
  	,'change=i'   => \$CHANGE
  	,'debug=s'    => \$D
  	,'verbose'    => \$V
  	,'help|?'  	  => \$help) or $help = 1;
	$help = 1 unless $BRANCH;
	help_exit() if $help;


	$CHANGE || ! -f $MARKS or help_exit("Marks file exists ($MARKS), specify --change to continue");

	@DIRS = @ARGV or help_exit("Must specify at least one directory!");
	map { -d or help_exit("No such directory: $_") } @DIRS;

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
  -t, --timezone P4 timezone, necessary to give git the right timestamps [ -0800 ]
  -b, --branch   Git branch to import into [ master ]

  -m, --marks    git marks file [ ~/marks ]
  -c, --change   p4 changelist # of the last mark; required if marks file exists

  -p, --prefix   Directory prefix to strip from DIRS when importing
                 If not specified, uses the longest common prefix of the DIRS

  -d, --debug    debug mode - provide a filename to dump to, rather than piping
                 to git --fast-import

Import the full P4 history of the given directories into the current git repo.

If a directory has moved in p4, you must provide both the old & new paths as arguments.

As this command must be run from the git directory, the DIR arguments will necessarily
be prefixed with a bunch of stuff (relative "../../" or absolute paths).  Use the
-p argument to strip off the common bits so your git import is rooted where you want, eg:

Examples:

  $name -p ../../oldsrc/ -a 'Bob Jones <bj\@yada.com>' ../../oldsrc/lib ../../oldsrc/bin

  $name                  -a 'Bob Jones <bj\@yada.com>' ../../oldsrc/lib ../../oldsrc/bin

Both commands will import "lib" and "bin" at the root of the current git repo.

The following functions are useful when spot-checking your results:

both_nums() { git log | grep -e '^commit' -e '\\[Perforce change'; }

cl2commit() { both_nums | grep -B1 "change \$1" | head -1 | cut -d' ' -f 2; }

commit2cl() { both_nums | grep -A1 "commit \$1" | tail -1 | sed -e 's~^.*change ~~' -e 's~.\$~~'; }

EOH

	exit(1);
	}

