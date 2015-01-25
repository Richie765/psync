#!/usr/bin/env perl
#!/usr/bin/perl

## no critic (Modules::ProhibitMultiplePackages)

use v5.10.0;
use strict;
use warnings;
no if $] >= 5.018, warnings => "experimental::smartmatch";
use Data::Dumper;

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
## SYNC
##

package Sync;

use Data::Dumper;

use IPC::Open2;
use IPC::Open3;
use File::Copy qw( copy cp );
use File::Compare;
use File::Path qw( make_path );
use File::Basename;

our $helpers;
our $verbose;
our $tag;
our $debug;
our $bytes = 0;

sub spawn_helper {
    my $tree = shift;

    my ($host, $root) = $tree =~ /^(?:(.*):)?(.*)$/;
    
    my ($pid, $wtr, $rdr, $err);

    my $app = basename $0;
    
    my @opts = ();
    if($tag) {
        push @opts, "--tag", $tag;
    }
    
    if ($host) {
        say "Connecting to remote host: $host" if($verbose);
        $pid = open2($rdr, $wtr, "ssh", $host, $app, "--helper", "--passcode=dontrunyourself", "--root=$root", @opts);
    }   
    else {
        $pid = open2($rdr, $wtr, $app, "--helper", "--passcode=dontrunyourself", "--root=$root", @opts);
    } 

    #say Dumper($wtr, $rdr, $err);

    return {
        host => $host,
        root => $root,
        pid => $pid,
        wtr => $wtr,
        rdr => $rdr,
        err => $err,
    };
}

sub command {
    my ($helper, $line) = @_;

    my $wtr = $helpers->[$helper]->{wtr};

    say $wtr $line;
    #say STDERR $line if $debug;

    return result($helper);
}

my $last_result;

sub result {
    my ($helper) = @_;

    my $rdr = $helpers->[$helper]->{rdr};

    my $line = <$rdr>;
    chomp $line;

    #say STDERR $line if $debug;

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
    my $helper = shift;

    my $wtr = $helpers->[$helper]->{wtr};
    my $rdr = $helpers->[$helper]->{rdr};

    my @lines;

    while (my $line = <$rdr>) {
        chomp $line;
        last if $line eq '';
        push @lines, $line;
    }

    return @lines;
}

sub parse_diff {
    my $list = shift;

    my @diff;

    for my $line (@$list) {
        my ($state, $size, $date, $filename) = $line =~ /^(\w+),(\d+),(\d+),(.*)$/;
        push @diff,
            {
            state => $state,
            size => $size,
            date => $date,
            filename => $filename,
            };
    }
    return \@diff;
}

sub get_diff {
    my $helper = shift;

    my @lines = get_lines($helper);
    return parse_diff(\@lines);
}

sub merge_diffs {
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

sub unchanged_files {
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
    my ($merged, $list, $src, $dst) = @_;

    my $src_root = $helpers->[$src]->{root};

    #say "Delete from $src_root";
    
    for my $filename (sort @$list) {

        # delete the file
        
        my $result = command($src, "UNLINK $filename");
        
        if($result) {
            command($src, "DELETE $filename") || die;
            command($dst, "DELETE $filename") || die;
            delete $merged->{$filename};
            say "rm $src_root/$filename" if $verbose;
        }
        else {
            say STDERR "Error deleting $src_root/$filename: $!";
        }
    }
    return;
}

sub deleted_files {
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

sub copy_list_local {
    # Copy a list of files that are both local
    my ($merged, $list, $src, $dst) = @_;

    my $src_root = $helpers->[$src]->{root};
    my $dst_root = $helpers->[$dst]->{root};

    #say "Copy from $src_root to $dst_root";
    
    for my $filename (sort @$list) {

        # Create destination dir if needed
        #

        my $dst_path = "$dst_root/$filename";
        my $dst_dirname = dirname $dst_path;

        if (!-d $dst_dirname) {
            make_path($dst_dirname, {error => \my $error});
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
            say "mkdir $dst_dirname" if $verbose;
        }

        # copy the file
        #
        
        my $result = cp "$src_root/$filename", "$dst_root/$filename";
        
        if($result) {
            command($src, "ADD $filename") || die;
            command($dst, "ADD $filename") || die;
            delete $merged->{$filename};
            say "cp $src_root/$filename $dst_root/$filename" if $verbose;
        }
        else {
            say STDERR "Error copying file $src_root/$filename to $dst_root/$filename: $!";
        }
    }
    
    return;
}

sub copy_list {
    # Copy a list of files that may be remote, using the helpers
    
    my ($merged, $list, $src, $dst) = @_;

    my $src_root = $helpers->[$src]->{root};
    my $dst_root = $helpers->[$dst]->{root};

    for my $filename (sort @$list) {

        # Transfer the file
        
        my $in = $helpers->[$src]->{rdr} || die;
        my $out = $helpers->[$dst]->{wtr} || die;
        
        #binmode $in;
        #binmode $out;
        
        say "transfer $filename" if $debug;

        say "Initating SEND" if $debug;

        if (!command($src, "SEND $filename")) {
            say STDERR "Error sending file $src_root/$filename: $last_result";
            
            # Skip the file
            delete $merged->{$filename};
            next;            
        }
        my $size = $last_result;
        
        say "Initating RECV" if $debug;

        if (!command($dst, "RECV $size,$filename")) {
            say STDERR "Error receiving file $dst_root/$filename: $last_result";
            
            # TODO: Stop the sender
            
            # Skip the file
            delete $merged->{$filename};
            next;            
        }
        
        say "COPY Starting" if $debug;
        
        my $buffer;
        my $blocksize = 1024 * 8; # 8kb
        my $amount;        
        
        while($size) {
            $blocksize = $size if ($blocksize > $size);
            #$size -= sysread($in, $buffer , $blocksize);
            #$amount = sysread($in, $buffer , $blocksize);
            $amount = read($in, $buffer , $blocksize);
            #print "COPY: data: $buffer" if $debug;
            say "COPY LEN: " . length($buffer) . " amount: $amount" if $debug;
            #syswrite $out, $buffer;
            print $out $buffer;
            $size -= $amount;
            $bytes += $amount;
            #say "COPY $amount bytes transferred, $size bytes left";
            say "COPY $size bytes left" if $debug;
        }
        say "COPY Finished" if $debug;
        
        # Verify files

        if (!command(0, "HASH $filename")) {
            say STDERR "Error hashing $src_root/$filename: $last_result";
            next;
        }        
        my $hash0 = $last_result;
        
        # Hash 1
        
        if (!command(1, "HASH $filename")) {
            say STDERR "Error hashing $dst_root/$filename: $last_result";
            next;
        }        
        my $hash1 = $last_result;

        if ($hash0 ne $hash1) {
            say STDERR "Copy failed verification";
            next;
        }
        else {
            say "Hash verification succeded" if $debug;
        }

        # Update metadata

        command($src, "ADD $filename") || die;
        command($dst, "ADD $filename") || die;
        delete $merged->{$filename};
        
        say "cp $src_root/$filename $dst_root/$filename" if $verbose;
    }
    
    return;
}

sub copy_files {
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
    }

    copy_list($merged, \@copylist_0, 0, 1) if(@copylist_0);
    copy_list($merged, \@copylist_1, 1, 0) if(@copylist_1);
    
    return;
}

sub equal_list_local {
    # Compare a list of tiles that are both local
    
    my ($merged, $list) = @_;

    my $src_root = $helpers->[0]->{root};
    my $dst_root = $helpers->[1]->{root};

    say "Compare from $src_root to $dst_root" if $verbose;
    for my $filename (sort @$list) {
        # compare the file
        #

        say "- compare $src_root/$filename $dst_root/$filename" if $verbose;
        
        my $result = compare("$src_root/$filename","$dst_root/$filename");
        
        given ($result) {
            when (-1) { 
                say STDERR "Error comparing $src_root/$filename and $dst_root/$filename: $!";
                # Skip them for now 
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

sub equal_list {
    # Compare a list of files with the use of Helper
    
    my ($merged, $list) = @_;

    my $src_root = $helpers->[0]->{root};
    my $dst_root = $helpers->[1]->{root};

    for my $filename (sort @$list) {
        # compare the file

        say "comp $src_root/$filename $dst_root/$filename" if $verbose;
        
        # Hash 0
        
        if (!command(0, "HASH $filename")) {
            say STDERR "Error hashing $src_root/$filename: $last_result";
            
            # Skip the file
            delete $merged->{$filename};
            next;
        }        
        my $hash0 = $last_result;
        
        # Hash 1
        
        if (!command(1, "HASH $filename")) {
            say STDERR "Error hashing $dst_root/$filename: $last_result";
            
            # Skip the file
            delete $merged->{$filename};
            next;
        }        
        my $hash1 = $last_result;

        say "$filename: $hash0 $hash1" if $debug;

        # Check results

        if ($hash0 eq $hash1) {
            command(0, "ADD $filename") || die;
            command(1, "ADD $filename") || die;
            delete $merged->{$filename};
        }
        else {
             # Files are different
             # Do nothing, handle as conflicts 
        }   
    }
    
    return;
}

sub equal_files {
    my ($merged) = @_;

    my @equal_list;

    for my $filename (keys %$merged) {
        my $item = $merged->{$filename};
        my $state0 = $item->{item0}->{state} || next;
        my $state1 = $item->{item1}->{state} || next;
        my $size0 = $item->{item0}->{size} || next;
        my $size1 = $item->{item1}->{size} || next;
        
        next if ($size0 != $size1);

        if($state0 eq 'new' && $state1 eq 'new') {
            push @equal_list, $filename;
        }
        elsif($state0 eq 'changed' && $state1 eq 'changed') {
            push @equal_list, $filename;
        }
    }

    equal_list($merged, \@equal_list) if(@equal_list);
    
    return;
}

sub conflict_files {
    my ($merged) = @_;

    for my $filename (keys %$merged) {
        my $item = $merged->{$filename};
        my $state0 = $item->{item0}->{state} // "none";
        my $state1 = $item->{item1}->{state} // "none";

        say "Conflict: $filename, $state0, $state1" if $verbose;
    }
    
    return;
}

sub run {
    my ($opt, $args) = @_;

    $verbose = $opt->{verbose};
    $debug = $opt->{debug};
    $tag = $opt->{tag};
    $bytes = 0;

    # Spawn 2 helpers

    local $SIG{PIPE} = sub { say STDERR "Error on remote server."; exit 1; };
    $helpers->[0] = spawn_helper($args->[0]);
    result(0);
    $helpers->[1] = spawn_helper($args->[1]);
    result(1);

    # Get diffs from helpers

    command(0, "GETDIFF") || die;
    command(1, "GETDIFF") || die;

    my $diff0 = get_diff(0);
    my $diff1 = get_diff(1);

    #print Dumper($diff0);
    #print Dumper($diff1);
    #exit;

    my $merged = merge_diffs($diff0, $diff1);
    
    #conflict_files($merged);    


    unchanged_files($merged);

    if (! %$merged) {
        say "Nothing to do." if $verbose;
    }

    #print Dumper($merged);

    # Process files

    deleted_files($merged);
    copy_files($merged);
    equal_files($merged);

    # 
    
    if (! %$merged) {
        #say "All changes merged.";
    }
    else {
        conflict_files($merged);    
    }
    

    # Quit helper processes

    command(0, "QUIT") || die;
    command(1, "QUIT") || die;

    # Wait for termination

    for my $helper (0..1) {
        waitpid( $helpers->[$helper]->{pid}, 0 );
        my $exit_status = $? >> 8;

        #say "Exit status helper $helper: $exit_status";
    }
    
    say "$bytes bytes transferred" if $verbose;
    
    return;
}

##
## HELPER
##

package Helper;

use Data::Dumper;

use File::Find;
use File::Path qw( make_path );
use File::Slurp;
use Digest::SHA;
use File::Basename;

our $root;
our $verbose;
our $debug;
our $state_dir;

sub get_last {
    # Returs the previous state as a hash
    #   The key is the filename
    #   Each element contains { size, date }
    
    my $list;
    my $added;
    my $deleted;

    # Read state if it exists
    
    my @lines = read_file("$state_dir/state", err_mode => 'quiet');
    
    for my $line (@lines) {
        last if !defined $line;

        my ($size, $date, $filename) = $line =~ /^(\d+),(\d+),(.*)$/;
        $list->{$filename} =
            {
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
    # Returs the current state as a hash
    #   The key is the filename
    #   Each element contains { size, date }

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
    my $last = get_last();
    my $current = get_current();
    my @list;

    # new, deleted, changed, unchanged


    # Walk through current

    for my $filename (sort keys %$current) {
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

    for my $filename (sort keys %$last) {
        my $item = $last->{$filename};
        my $current_item = $current->{$filename};
        
        my $state;
        if(!defined $current_item) {
            $item->{filename} = $filename;
            $item->{state} = "deleted";
            push @list, $item;
        }
    }

    # Output

    say "OK";

    for my $item (@list) {
        my $filename = $item->{filename};
        my $size = $item->{size};
        my $date = $item->{date};
        my $state = $item->{state};

        my $line = "$state,$size,$date,$filename";
        say $line;
        #say STDERR $line;
    }

    say "";
    
    return;
}

sub cmd_add {
    my $filename = shift;
        
    # Get file information
    
    my $full_filename = "$root/$filename";
    
    my $size = -s $full_filename;
    my $date = ( stat $full_filename )[9];
    
    # Output to state directory
    
    open my $out, ">>", "$state_dir/added";
    my $line = "$size,$date,$filename";
    #say STDERR $line;
    say $out $line;
    close $out;

    say "OK";
    
    return;
}

sub cmd_unlink {
    my $filename = shift;

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
    my $filename = shift;
        
    # Output to state directory
    
    open my $out, ">>", "$state_dir/deleted";
    my $line = "$filename";
    #say STDERR $line;
    say $out $line;
    close $out;

    say "OK";
    
    return;
}

sub cmd_hash {
    my $filename = shift;


    my $alg = 512;
    my $sha = Digest::SHA->new($alg);
    $sha->addfile("$root/$filename", "b");
    my $digest = $sha->hexdigest;
        
    say "OK $digest";
    
    return;
}

sub cmd_send {
    my $filename = shift;

    #$debug = 1;

    my $size = -s "$root/$filename";
    
    open my $file, "<", "$root/$filename" ## no critic (InputOutput::RequireBriefOpen)
        or die "Cannout open $root/$filename for reading: $!";
    
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
        #$amount = sysread($file, $buffer, $blocksize);
        $amount = read($file, $buffer, $blocksize);
        say STDERR "SEND: LEN: " . length($buffer) if $debug;
        #syswrite(STDOUT, $buffer);
        print $buffer;
        $size -= $amount;
        say STDERR "SEND: $amount bytes transferred, $size bytes left" if $debug; 
    }
    
    say STDERR "SEND DONE" if $debug;
    
    close $file;
    
    return;
}

sub cmd_recv {
    my $param = shift;
    
    #$debug = 1;
    
    my ($size, $filename) = $param =~ /^(\d+),(.*)$/;

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
            say "ERROR Unable to create destinatin directory";
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
        #my $amount = sysread(STDIN, $buffer, $blocksize);
        my $amount = read(STDIN, $buffer, $blocksize);
        $size -= $amount;
        print $file $buffer;
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

    # Verify the root

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
        
        make_path($state_dir, {error => \my $error});

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
            when ("QUIT") { say "OK"; last }
            when ("GETDIFF") { cmd_getdiff() }
            when ("ADD") { cmd_add($params); };
            when ("UNLINK") { cmd_unlink($params); };
            when ("DELETE") { cmd_delete($params); };
            when ("HASH") { cmd_hash($params); };
            when ("SEND") { cmd_send($params); };
            when ("RECV") { cmd_recv($params); };
            default { say "ERROR Unknown command $command" };
        }
    }
    
    return;
}

$|++;   # Flush output after each write
main::main();

__END__
