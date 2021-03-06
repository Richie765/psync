#!/usr/bin/env perl
#!/usr/bin/perl

## no critic (Modules::ProhibitMultiplePackages)

use v5.10.0;
use strict;
use warnings;
no if $] >= 5.018, warnings => "experimental::smartmatch";
use autodie;

use Getopt::Long;

sub usage {
    print << "EOF"
Usage: psync [-dv] [long options...] <root_1> <root_2>

    --tag <tagname>  Metadata Tag, optional

    -h --help        Show this help
    -v --verbose     Verbose
    -d --debug       Debug output

EOF
}

sub usage_error {
    my $msg = shift;

    say STDERR $msg;
    usage();

    exit 1;
}

sub main {
    # Get arguments

    my $opt = {};

    GetOptions ($opt,
        "help|h",
        "verbose|v",
        "debug|d",
        "tag=s",

        # Helper related parameters

        "helper",
        "passcode=s",
        "root=s"
    ) or usage_error("Error in command line arguments");

    if($opt->{help}) {
        usage();
        exit;
    }

    # Validate Arguments

    if ($opt->{helper}) {
        usage_error("No options allowed") if @ARGV;
        usage_error("Don't use helper mode") if (!$opt->{passcode} || $opt->{passcode} ne "dontrunyourself");
    }
    else {
        usage_error("Need to specify two roots") unless @ARGV == 2;
    }

    # Run

    if ($opt->{helper}) {
        Helper::run($opt, \@ARGV);
    }
    else {
        Sync::run($opt, \@ARGV);
    }
    
    return;
}

##
## SYNC - This package does the actual syncing work
##

package Sync;

use autodie;

use File::Basename;
use File::Compare;
use File::Copy qw( copy cp );
use File::Path qw( make_path );
use IPC::Open2;

our $helpers;
our $verbose;
our $tag;
our $debug;
our $bytes = 0;

sub spawn_helper {
    # Spawns a helper process, through ssh if needed

    my ($tree) = @_;

    my ($host, $root) = $tree =~ /^(?:(.*):)?(.*)$/;
    
    my ($pid, $wtr, $rdr);

    my $app = basename $0;

    my @opts = ( "--helper", "--passcode=dontrunyourself", "--root=$root" );

    if($tag) {
        push @opts, "--tag", $tag;
    }
    
    if ($host) {
        say "Connecting to remote host: $host" if($verbose);
        $pid = open2($rdr, $wtr, "ssh", $host, $app, @opts);
    }   
    else {
        $pid = open2($rdr, $wtr, $app, @opts);
    } 

    #binmode $rdr;
    #binmode $wtr;

    return {
        host => $host,
        root => $root,
        pid => $pid,
        wtr => $wtr,
        rdr => $rdr,
    };
}

sub command {
    # Sends a command to a remote helper and returns true if successful

    my ($helper, $command) = @_;

    my $wtr = $helpers->[$helper]->{wtr};

    say $wtr $command;

    # TODO Check return value say

    return result($helper);
}

my $last_result;

sub result {
    # Read result from a helper, return true if ok

    my ($helper) = @_;

    my $rdr = $helpers->[$helper]->{rdr};

    my $line = <$rdr>;
    die "Got no result, connection lost?" if(!defined($line)); # not caught by autodie

    chomp $line;

    my $status;
    
    ($status, $last_result) = $line =~ /^(OK|ERROR)(?: (.*))?$/;

    given ($status) {
        when ('OK') { 
            return 1;
        }
        when ('ERROR') { 
            say STDERR $last_result;
            return 0;
        }
    }

    die "Unexpected response: $line";
}

sub get_lines {
    # Reads multiple lines from the remote helper, stops when a blank line is received

    my ($helper) = @_;

    my $rdr = $helpers->[$helper]->{rdr};

    my @lines;

    while (my $line = <$rdr>) {
        chomp $line;
        return @lines if $line eq '';
        push @lines, $line;
    }

    die "Unexpected end of input, connection lost?"; # not caught by autodie
}

sub parse_diff {
    # Parses the diff lines into an array of hash

    my ($list) = @_;

    my @diff;

    for my $line (@$list) {
        my ($state, $size, $date, $filename) = $line =~ /^(\w+),(\d+),(\d+),(.*)$/;
        push @diff, {
            state => $state,
            size => $size,
            date => $date,
            filename => $filename,
        };
    }
    return \@diff;
}

sub get_diff {
    # Receive diff from helper, parse and return

    my ($helper) = @_;

    my @lines = get_lines($helper);

    return parse_diff(\@lines);
}

sub merge_diffs {
    # Merge two diffs into one structure, indexed by filename

    my ($diff0, $diff1) = @_;

    my $merged;

    # Insert diff0

    for my $item0 (@$diff0) {
        my $filename = $item0->{filename};

        $merged->{$filename}->{item0} = $item0;
    }

    # Insert diff1

    for my $item1 (@$diff1) {
        my $filename = $item1->{filename};

        $merged->{$filename}->{item1} = $item1;
    }

    return $merged;
}

sub rootname {
    # Usage:
    #   my $rootname = rootname($root);
    #
    # Returns
    #   A string like: root_1 (for $root == 0)

    my ($root) = @_;

    return "root_" . ($root + 1);
}

sub unchanged_files {
    # Skip files that are unchanged on both sides

    my ($merged) = @_;

    for my $filename (keys %$merged) {
        my $item = $merged->{$filename};
        my $state0 = $item->{item0}->{state} // "none";
        my $state1 = $item->{item1}->{state} // "none";

        if($state0 eq 'unchanged' && $state1 eq 'unchanged') {
            delete $merged->{$filename};
        }
    }
    return;
}

sub delete_list {
    # Delete the specified list of files from $src
    # Then update 'deleted' metadata on both the source and destination

    my ($merged, $list, $src, $dst) = @_;

    my $src_rootname = rootname($src);

    say "Deleting from $src_rootname" if $verbose;
    
    for my $filename (sort @$list) {
        say "- delete $filename" if $verbose;

        # delete the file
        
        my $result = command($src, "UNLINK $filename");
        
        if($result) {
            command($src, "DELETE $filename") || die;
            command($dst, "DELETE $filename") || die;
            delete $merged->{$filename};
        }
        else {
            say STDERR "- Error deleting $filename";
            delete $merged->{$filename};
        }
    }

    return;
}

sub delete_files {
    # Create a list of files that need to be deleted, then delete them

    my ($merged) = @_;

    my @delete_list_0;
    my @delete_list_1;

    for my $filename (keys %$merged) {
        my $item = $merged->{$filename};
        my $state0 = $item->{item0}->{state} // "none";
        my $state1 = $item->{item1}->{state} // "none";

        if($state0 eq 'unchanged' && $state1 eq 'deleted') {
            push @delete_list_0, $filename;
        }
        elsif($state0 eq 'deleted' && $state1 eq 'unchanged') {
            push @delete_list_1, $filename;
        }
    }

    delete_list($merged, \@delete_list_0, 0, 1) if(@delete_list_0);
    delete_list($merged, \@delete_list_1, 1, 0) if(@delete_list_1);
    
    return;
}

sub copy_file_local {
    # Copy a file where src and dst are both local
    #
    # Return
    #   true on success
    #
    # TODO Not used yet, implement in copy_list

    my ($filename, $src, $dst) = @_;

    my $src_root = $helpers->[$src]->{root};
    my $dst_root = $helpers->[$dst]->{root};
    
    my $dst_path = "$dst_root/$filename";
    my $dst_dirname = dirname $dst_path;

    if (!-d $dst_dirname) {
        say "make_path $dst_dirname" if $debug;

        make_path($dst_dirname, { error => \my $error });

        if (@$error) {
            for my $diag (@$error) {
                my ($file, $message) = %$diag;

                if ($file eq '') {
                    say STDERR "Error creating directory $dst_dirname: $message";
                }
                else {
                    say STDERR "Error unlinking $file: $message";
                }
            }
        }
    }

    # copy the file
    #
    
    my $result = cp "$src_root/$filename", "$dst_root/$filename";
            
    return $result;
}

sub copy_file {
    # Copy a single file with the use of Helper
    #
    # Return
    #   true on success
    
    my ($filename, $src, $dst) = @_;
    
    ##
    say "Initiating SEND" if $debug;
    ##

    if (!command($src, "SEND $filename")) {
        say STDERR "Initiate SEND failed: $last_result";
        
        return;
    }
    my $size = $last_result;
    
    ##
    say "Initiating RECV" if $debug;
    ##

    if (!command($dst, "RECV $size,$filename")) {
        say STDERR "Initiate RECV failed: $last_result";
        
        return;            
    }
    
    ##
    say "Starting COPY" if $debug;
    ##
    
    my $in = $helpers->[$src]->{rdr} || die;
    my $out = $helpers->[$dst]->{wtr} || die;
    
    my $blocksize = 1024 * 8; # 8kb
    my $buffer;
    
    while($size) {
        $blocksize = $size if ($blocksize > $size);

        my $amount = read($in, $buffer, $blocksize);
        die "Read Error" if(! defined($amount));

        my $result = print $out $buffer;
        die "Write Error" if(!$result); # autodie doesn't work with print

        $size -= $amount;
        $bytes += $amount;

        say "COPY $size bytes left" if $debug;
    }

    ##
    say "COPY Finished" if $debug;
    ##

    return 1;
}

sub copy_list {
    # Copy a list of files that may be remote, using the helpers
    
    my ($merged, $list, $src, $dst) = @_;

    my $src_rootname = rootname($src);
    my $dst_rootname = rootname($dst);
    
    say "Copying files: $src_rootname -> $dst_rootname" if $verbose;

    for my $filename (sort @$list) {
        say "- copy $filename" if $verbose;

        # Transfer the file
        
        copy_file($filename, $src, $dst)
            || die;

        # Verify file

        # TODO Make verification optional through a command-line switch

        my $result = compare_file($filename, $src, $dst);

        # Check result

        given ($result) {
            when (-1) { 
                # Couldn't compare, skip it
                say STDERR "Warning: Skipping file because it couldn't be compared";

                delete $merged->{$filename};
            }
            when (1) {
                say STDERR "Copy verification failed";
                return;
            }
            when (0) {
                # Files are equal
                say "Copy verification succeded" if $debug;

                command($src, "ADD $filename") || die;
                command($dst, "ADD $filename") || die;

                delete $merged->{$filename};
            }
        }
    }
    
    return;
}

sub copy_files {
    # Create a list of files that need to be copied, then copy them

    my ($merged) = @_;

    my @copylist_0;  # copy 0 -> 1
    my @copylist_1;  # copy 1 -> 0

    for my $filename (keys %$merged) {
        my $item = $merged->{$filename};
        my $state0 = $item->{item0}->{state} // "none";
        my $state1 = $item->{item1}->{state} // "none";

        if($state0 eq 'new' && $state1 eq 'none') {
            push @copylist_0, $filename;
        }
        elsif($state0 eq 'none' && $state1 eq 'new') {
            push @copylist_1, $filename;
        }
        elsif($state0 eq 'changed' && $state1 eq 'unchanged') {
            push @copylist_0, $filename;
        }
        elsif($state0 eq 'unchanged' && $state1 eq 'changed') {
            push @copylist_1, $filename;
        }

        # Following 4 cases are for example possible when one of the roots
        # is completely emptied, and then reset with a new sync.
        # I guess is's just fine to handle them here.

        elsif($state0 eq 'changed' && $state1 eq 'none') {
            push @copylist_0, $filename;
        }
        elsif($state0 eq 'none' && $state1 eq 'changed') {
            push @copylist_1, $filename;
        }
        elsif($state0 eq 'unchanged' && $state1 eq 'none') {
            push @copylist_0, $filename;
        }
        elsif($state0 eq 'none' && $state1 eq 'unchanged') {
            push @copylist_1, $filename;
        }
    }

    copy_list($merged, \@copylist_0, 0, 1) if(@copylist_0);
    copy_list($merged, \@copylist_1, 1, 0) if(@copylist_1);
    
    return;
}

sub compare_file_local {
    # Compare two files that are both local
    #
    # Returns
    #   -1  - Couldn't compare files
    #   1   - Files are different
    #   0   - Files are equal
    #
    # TODO Not used yet, implement in compare_list
    
    my ($filename, $src, $dst) = @_;

    my $src_root = $helpers->[$src]->{root};
    my $dst_root = $helpers->[$dst]->{root};

        
    my $result = compare("$src_root/$filename","$dst_root/$filename");

    if($result == -1) {
        say STDERR "Couldn't compare $src_root/$filename and $dst_root/$filename: $!";
    }        
    
    return $result;
}

sub compare_file {
    # Compare a single file with the use of Helper
    #
    # Returns
    #   -1  - Couldn't compare files
    #   1   - Files are different
    #   0   - Files are equal
    
    my ($filename, $src, $dst) = @_;

    my $src_root = $helpers->[$src]->{root};
    my $dst_root = $helpers->[$dst]->{root};

    # Hash $src
    
    if (!command($src, "HASH $filename")) {
        say STDERR "Error hashing $src_root/$filename: $last_result";
        
        return -1;
    }
    my $src_hash = $last_result;
    
    # Hash $dst
    
    if (!command($dst, "HASH $filename")) {
        say STDERR "Error hashing $dst_root/$filename: $last_result";
        
        return -1;
    }        
    my $dst_hash = $last_result;

    # Check result

    say "$filename: $src_hash $dst_hash" if $debug;

    if ($src_hash ne $dst_hash) {
        # Different
        return 1;
    }

    # Equal

    return 0;
}

sub compare_list {
    # Compare a list of files.
    # If the file is equal, remove from $merged hash and notify both sides.
    
    my ($merged, $list) = @_;

    for my $filename (sort @$list) {
        # compare the file

        say "comp $filename" if $verbose;
        
        my $result = compare_file($filename, 0, 1);

        # Check result

        given ($result) {
            when (-1) { 
                # Couldn't compare, skip it
                say STDERR "Warning: Skipping file because it couldn't be compared";

                delete $merged->{$filename};
            }
            when (1) {
                 # Files are different
                 # Do nothing, handle as conflicts 
            }
            when (0) {
                # Files are equal
                command(0, "ADD $filename") || die;
                command(1, "ADD $filename") || die;

                delete $merged->{$filename};
            }
        }
    }
    
    return;
}

sub compare_files {
    # Create a list of files that might be equal and need to be compared

    my ($merged) = @_;

    my @compare_list;

    for my $filename (keys %$merged) {
        my $item = $merged->{$filename};
        my $state0 = $item->{item0}->{state} || next;
        my $state1 = $item->{item1}->{state} || next;
        my $size0 = $item->{item0}->{size} || next;
        my $size1 = $item->{item1}->{size} || next;
        
        next if ($size0 != $size1);

        if($state0 eq 'new' && $state1 eq 'new') {
            push @compare_list, $filename;
        }
        elsif($state0 eq 'changed' && $state1 eq 'changed') {
            push @compare_list, $filename;
        }
    }

    compare_list($merged, \@compare_list) if(@compare_list);
    
    return;
}

sub conflict_files {
    # Everything that remains is a conflict, show a list

    my ($merged) = @_;

    say "Conflicts:";

    for my $filename (keys %$merged) {
        my $item = $merged->{$filename};
        my $state0 = $item->{item0}->{state} // "none";
        my $state1 = $item->{item1}->{state} // "none";

        say "- $filename ($state0, $state1)";
    }
    
    return;
}

sub run {
    my ($opt, $args) = @_;

    $verbose = $opt->{verbose};
    $debug = $opt->{debug};
    $tag = $opt->{tag};
    $bytes = 0;

    # Spawn helpers for both sides

    local $SIG{PIPE} = sub { say STDERR "Connection to helper lost."; exit 1; };

    $helpers->[0] = spawn_helper($args->[0]);
    result(0);
    $helpers->[1] = spawn_helper($args->[1]);
    result(1);

    # Get diffs from helpers

    command(0, "GETDIFF") || die;
    command(1, "GETDIFF") || die;

    my $diff0 = get_diff(0);
    my $diff1 = get_diff(1);

    # Merge both diffs into a single structure

    my $merged = merge_diffs($diff0, $diff1);
    
    # Skip unchanged files

    unchanged_files($merged);

    # Process files

    if (%$merged) {
        delete_files($merged);
        copy_files($merged);
        compare_files($merged);
    }
    else {
        say "Nothing to do." if $verbose;
    }
    
    # Show conflicts
    
    if (%$merged) {
        conflict_files($merged);    
    }
    else {
        #say "All changes merged.";
    }
    
    ##
    say "Quitting Helpers" if $debug;
    ##

    command(0, "QUIT") || die;
    command(1, "QUIT") || die;

    # Wait for termination

    for my $helper (0..1) {
        waitpid( $helpers->[$helper]->{pid}, 0 );
        # my $exit_status = $? >> 8;

        # say "Exit status helper $helper: $exit_status";
    }
    
    say "$bytes bytes transferred" if $verbose;
    
    return;
}

##
## HELPER
##

package Helper;

use autodie;

use Digest::SHA;
use File::Basename;
use File::Find;
use File::Path qw( make_path );
use File::Slurp;

our $root;
our $verbose;
our $debug;
our $state_dir;

sub get_last {
    # Get list of files at time of last sync.
    # NOTE: If added and/or deleted state files exist, they will be merged into state and deleted
    #
    # Usage
    #   my $last = get_last();
    # Returns
    #   $last->{filename} -> { size, data }
    
    my $list;
    my $added;
    my $deleted;

    # Read state if it exists
    
    my @lines = read_file("$state_dir/state", err_mode => 'quiet');
    
    for my $line (@lines) {
        last if !defined $line;

        my ($size, $date, $filename) = $line =~ /^(\d+),(\d+),(.*)$/;
        $list->{$filename} = {
            size => $size,
            date => $date,
        };
    }
    
    # Merge added if exists

    @lines = read_file("$state_dir/added", err_mode => 'quiet');
    
    for my $line (@lines) {
        last if !defined $line;

        $added = 1;

        my ($size, $date, $filename) = $line =~ /^(\d+),(\d+),(.*)$/;

        $list->{$filename}->{size} = $size;
        $list->{$filename}->{date} = $date;
    }
    
    # Merge deleted
    
    @lines = read_file("$state_dir/deleted", err_mode => 'quiet');
    
    for my $filename (@lines) {
        last if !defined $filename;
        
        chomp $filename;

        $deleted = 1;

        delete $list->{$filename};
        #say STDERR "Deleted from list: $filename";
    }
    
    # Output new state if needed

    if($added || $deleted) {
        @lines = ();

        for my $filename (sort keys %$list) {
            my $item = $list->{$filename};
            my $size = $item->{size};
            my $date = $item->{date};
            
            my $line = "$size,$date,$filename\n";

            push @lines, $line;
        }
        
        write_file("$state_dir/state", \@lines) || die "Unable to write to $state_dir/state";
        
        if($added) {
            unlink("$state_dir/added") || die "Unable to delete $state_dir/added: $!";
        }
        
        if($deleted) {
            unlink("$state_dir/deleted") || die "Unable to delete $state_dir/deleted: $!";
        }
    }

    return $list;
}

sub get_current {
    # Get the current list of files.
    #
    # Usage
    #   my $current = get_current();
    # Returns
    #   $current->{filename} -> { size, data }

    my $list;

    my $wanted = sub {
        my $filename = $File::Find::name;

        return unless (-f $filename);

        my $size = -s $filename;
        my $date = ( stat $filename )[9];
        $filename =~ s/^$root//;
        $filename =~ s/^\/+//;

        my $item = {
            size => $size,
            date => $date,
        };

        $list->{$filename} = $item;
    };

    my $preprocess = sub {
        my $dir = $File::Find::dir;
        #print STDERR Dumper(\@_);
        return grep { $_ ne '.psync' } @_;
    };

    find({ wanted => $wanted, preprocess => $preprocess, no_chdir => 1 }, $root);

    return $list;
}

sub cmd_getdiff {
    # Output the diff files since the last sync
    # Each line is in the following format:
    #
    # $state,$size,$date,$filename
    #
    # $state is one of: new, deleted, changed, unchanged
    #
    # The list will be preceeded by a line with "OK" and terminated by a blank line.
    #
    # Usage:
    #   cmd_diff();

    my $last = get_last();
    my $current = get_current();

    my @list;

    # Walk through current

    for my $filename (keys %$current) {
        my $item = $current->{$filename};
        my $last_item = $last->{$filename};
        
        my $state;

        if(!defined $last_item) {
            $state = "new";
        }
        elsif ($item->{size} != $last_item->{size}) {
            $state = "changed";
        }
        elsif ($item->{date} != $last_item->{date}) {
            $state = "changed";
        }
        else {
            $state = "unchanged";
        }
        
        $item->{filename} = $filename;
        $item->{state} = $state;

        push @list, $item;
    }

    # Walk through last

    for my $filename (keys %$last) {
        my $item = $last->{$filename};
        my $current_item = $current->{$filename};
        
        if(!defined $current_item) {
            $item->{filename} = $filename;
            $item->{state} = "deleted";

            push @list, $item;
        }
    }

    # Output

    say "OK";

    for my $item (@list) {
        my $state = $item->{state};
        my $size = $item->{size};
        my $date = $item->{date};
        my $filename = $item->{filename};

        my $line = "$state,$size,$date,$filename";

        say $line;
    }

    say "";
    
    return;
}

sub cmd_add {
    # Add a line of information of the specified file into the 'added' state file
    # The information has the following format:
    #
    # $size,$date,$filename
    #
    # Usage:
    #   cmd_add($filename);

    my ($filename) = @_;
        
    # Get file information
    
    my $full_filename = "$root/$filename";
    
    my $size = -s $full_filename;
    my $date = ( stat $full_filename )[9];

    my $line = "$size,$date,$filename";
    
    # Output to state directory
    
    open my $out, ">>", "$state_dir/added";
    say $out $line;
    close $out;

    say "OK";
    
    return;
}

sub cmd_unlink {
    # Unlink the a file.
    #
    # Usage:
    #   cmd_unlink($filename);

    my ($filename) = @_;

    my $result = unlink "$root/$filename";
    
    if($result) {
        say "OK";
    }
    else {
        say "ERROR $!";
    }
    
    return;
}

sub cmd_delete {
    # Add a line of information of the specified deleted file into the 'deleted' state file
    # The information has the following format:
    #
    # $filename
    #
    # Usage:
    #   cmd_delete($filename);

    my ($filename) = @_;

    my $line = "$filename";
        
    # Output to state directory
    
    open my $out, ">>", "$state_dir/deleted";
    say $out $line;
    close $out;

    say "OK";
    
    return;
}

sub cmd_hash {
    # Returns a SHA512 digest of a file.
    #
    # Usage:
    #   cmd_hash($filename);

    my ($filename) = @_;

    my $alg = 512;
    my $sha = Digest::SHA->new($alg);
    $sha->addfile("$root/$filename", "b");
    my $digest = $sha->hexdigest;
        
    say "OK $digest";
    
    return;
}

sub cmd_send {
    # Send the specified file.
    #
    # Usage:
    #   cmd_send($filename);

    my ($filename) = @_;

    #$debug = 1;

    my $size = -s "$root/$filename";
    
    open my $file, "<", "$root/$filename"; ## no critic (InputOutput::RequireBriefOpen)

    if(!$file) {
        say "ERROR Cannot open $root/$filename for reading: $!";
        return;
    }
    
    say "OK $size";
    #sleep 1;
        
    #binmode $file;
    #binmode STDOUT;
        
    my $buffer;
    my $blocksize = 1024 * 8;
    my $amount;
    
    say STDERR "SEND: size = $size" if $debug;
    
    while ($size) {
        $blocksize = $size if ($blocksize > $size);

        $amount = read($file, $buffer, $blocksize);
        die "Read Error" if(! defined $amount);
        say STDERR "SEND: LEN: " . length($buffer) if $debug;

        my $result = print $buffer;
        die "Write Error" if(!$result); # autodie doesn't work with print

        $size -= $amount;
        say STDERR "SEND: $amount bytes transferred, $size bytes left" if $debug; 
    }
    
    say STDERR "SEND DONE" if $debug;
    
    close $file;
    
    return;
}

sub cmd_recv {
    # Receive the specified file. The path will be created if needed.
    #
    # Usage:
    #   cmd_recv($size, $filename);

    my ($size, $filename) = @_;
    
    # Create destination dir if needed
    #

    my $dst_path = "$root/$filename";
    my $dst_dirname = dirname $dst_path;

    if (!-d $dst_dirname) {
        make_path($dst_dirname, {error => \my $error});

        if (@$error) {
            for my $diag (@$error) {
                my ($file, $message) = %$diag;

                if ($file eq '') {
                    say STDERR "Error creating directory $dst_dirname: $message" if $debug;
                }
                else {
                    say STDERR "Error unlinking $file: $message" if $debug;
                }
            }

            # TODO Add proper error message

            say "ERROR Unable to create destination directory $dst_dirname";
            return;
        }
        say STDERR "mkdir $dst_dirname" if $verbose;
    }
    
    # Generate the temp-name

    my $basename = basename $filename;
    
    my $tempname = "$dst_dirname/.${basename}.$$";
    
    #say STDERR "Tempname: $tempname";
    
    # Receive the file

    open(my $file, ">", "$tempname") ## no critic (InputOutput::RequireBriefOpen)
        || die "Cannot open $root/$tempname for writing: $!";

    #binmode $file;
    
    say "OK";
    
    my $buffer;
    my $blocksize = 1024 * 8;
    
    #binmode STDIN;
    
    while ($size) {
        $blocksize = $size if ($blocksize > $size);

        my $amount = read(STDIN, $buffer, $blocksize);
        die "Read Error" if(! defined($amount));

        $size -= $amount;

        my $result = print $file $buffer;
        die "Write Error" if(!$result); # autodie doesn't work with print

        say STDERR "RECV: $size bytes left $amount bytes received" if $debug; 
    }
    
    #say STDERR "RECV: Too many bytes received" if $size;
    say STDERR "RECV: finished" if $debug; 
    
    close $file;
    
    # Rename the file
    
    if (-f "$dst_path") {
        if (! unlink "$dst_path" ) {
            die "Cannot delete: $dst_path: $!";    
        }
    }
    
    if (! rename "$tempname", "$dst_path" ) {
        die "Cannot rename: $tempname to $dst_path: $!";    
    }
    
    return;
}

sub run {
    my ($opt, $args) = @_;

    # Verify the root exists

    $root = $opt->{root};
    $tag = $opt->{tag};

    if(!$root) {
        say STDERR "ERROR Root not set $root";
        exit 1;
    }

    if(!-d $root) {
        say STDERR "ERROR Root dir not found $root";
        exit 1;
    }

    # Determine State Directory
    
    $state_dir = "$root/.psync";
    $state_dir .="/$tag" if($tag);
    
    # Create state directory if needed

    if (! -d $state_dir) {
        say STDERR "- mkdir $state_dir" if ($debug);
        
        make_path($state_dir, { error => \my $error });

        if (@$error) {
            for my $diag (@$error) {
                my ($file, $message) = %$diag;

                if ($file eq '') {
                    say STDERR "ERROR general error: $message";
                    exit 1;
                }
                else {
                    say STDERR "ERROR problem unlinking $file: $message";
                    exit 1;
                }
            }
        }
    }

    # Ready to accept commands

    say "OK";

    # Command loop

    while (my $line = <STDIN>) {  ## no critic(InputOutput::ProhibitExplicitStdin)
        chomp $line;
        my ($command, $params) = $line =~ /^(\w+)(?: (.+))?$/;

        $debug = 0;

        given (uc $command) {
            when ("QUIT") { say "OK"; return; }
            when ("GETDIFF") { cmd_getdiff() }
            when ("ADD") { cmd_add($params); };
            when ("UNLINK") { cmd_unlink($params); };   # filename
            when ("DELETE") { cmd_delete($params); };   # filename
            when ("HASH") { cmd_hash($params); };       # filename
            when ("SEND") { cmd_send($params); };       # filename
            when ("RECV") { 
                my ($size, $filename) = $params =~ /^(\d+),(.*)$/;

                cmd_recv($size, $filename); 
            };
            default { say "ERROR Unknown command $command" };
        }
    }

    say STDERR "Unexpected End of Input, terminating helper"; # not caught by autodie
    
    return;
}

$|++;   # Flush output after each write
main::main();

__END__
