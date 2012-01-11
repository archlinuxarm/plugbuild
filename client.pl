#!/usr/bin/perl
#
# PlugBuild Builder Client
#

use strict;
use FindBin qw($Bin);
use Switch;
use AnyEvent;
use AnyEvent::TLS;
use AnyEvent::Handle;
use AnyEvent::Socket;
use JSON::XS;

####### BEGIN USER CONFIGURATION #######

# plugbuild server
my $server      = "archlinuxarm.org";
my $port        = 2123;

# chroot location
my $chroot      = "/root/chroot";9768144

# SSL certificate info (use $Bin for script execution dir)
my $ca_file     = "$Bin/certs/plugbuild-cacert.pem";    # our CA certificate
my $cert_file   = "$Bin/certs/client.pem";              # combined key and cert pem
my $password    = "sekrit";                             # key password (maybe make this interactive)

######## END USER CONFIGURATION ########

# other variables, probably shouldn't touch these
my $makepkg     = "makechrootpkg -cr $chroot -- -AcsfrL";
my $workroot    = "$Bin/work";
my $pkgdest     = "$Bin/pkgdest";
my $workurl     = "http://archlinuxarm.org/builder/work";

my $state;
my $child;
my $childpid = 0;
my %files;
my $current_filename;
my $current_fh;

# AnyEvent setup
my $condvar = AnyEvent->condvar;
my $h;
my $w = AnyEvent->signal(signal => "INT", cb => sub { bailout(); });
my $timer_retry;

# main event loop
$state->{command} = 'idle';
con();
$condvar->wait;

# shutdown
$h->destroy;


### control subroutines

# SIGINT catcher
sub bailout {
    print "\n\nCaught SIGINT, shutting down..\n";
    if ($state->{command} && $state->{command} ne 'idle') {
        undef $child;
        kill 'TERM', -$childpid if ($childpid);
        
        $state->{command} = 'release';
        $h->on_drain(sub { $condvar->broadcast; });
        $h->push_write(json => $state);
    } else {
        $condvar->broadcast;
    }
}


# connect to service
sub con {
    $h = new AnyEvent::Handle
        connect             => [$server => $port],
        tls                 => "connect",
        tls_ctx             => {
                                verify          => 1,
                                ca_file         => $ca_file,
                                cert_file       => $cert_file,
                                cert_password   => $password,
                                verify_cb       => sub { cb_verify_cb(@_); }
                                },
        keepalive           => 1,
        no_delay            => 1,
        rtimeout            => 3, # 3 seconds to authenticate with SSL before destruction
        wtimeout            => 60,
        on_wtimeout         => sub { $h->push_write(json => { command => 'ping' }); },
        on_rtimeout         => sub { $h->destroy; $condvar->broadcast; },
        on_error            => sub { cb_error(@_); },
        on_starttls         => sub { cb_starttls(@_); },
        on_connect_error    => sub { cb_error($_[0], 0, $_[1]); }
        ;
}

# callback that handles peer certificate verification
sub cb_verify_cb {
    my ($tls, $ref, $cn, $depth, $preverify_ok, $x509_store_ctx, $cert) = @_;
    
	# depth is zero when we're verifying peer certificate
    return $preverify_ok if $depth;
    
    # get certificate information
    my $orgunit = Net::SSLeay::X509_NAME_get_text_by_NID(Net::SSLeay::X509_get_subject_name($cert), Net::SSLeay->NID_organizationalUnitName);
    my $common = Net::SSLeay::X509_NAME_get_text_by_NID(Net::SSLeay::X509_get_subject_name($cert), Net::SSLeay->NID_commonName);
    my @cert_alt = Net::SSLeay::X509_get_subjectAltNames($cert);
    my $ip = AnyEvent::Socket::parse_address $cn;
    
    # verify ip address in client cert subject alt name against connecting ip
    while (my ($type, $name) = splice @cert_alt, 0, 2) {
        if ($type == Net::SSLeay::GEN_IPADD()) {
            if ($ip eq $name) {
                print "verified ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert)) ."\n";
                return 1;
            }
        }
    }
    
    print "failed verification for $ref->{peername}: ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert)) ."\n";
    return 0;
}

# callback on socket error
sub cb_error {
    my ($handle, $fatal, $message) = @_;
    
    if ($fatal) {
        print "fatal ";
    }
    print "error from $handle->{peername} - $message\n";
    $timer_retry = AnyEvent->timer(after => 10, cb => sub { con(); });
}

# callback on whether ssl auth succeeded
sub cb_starttls {
    my ($handle, $success, $error) = @_;
    
    if ($success) {
        $handle->rtimeout(0);   # stop auto-destruct
        $handle->on_read(sub { $handle->push_read(json => sub { cb_read(@_); }) });    # set read callback
        my %reply = (command => 'sync');
        if ($state->{command} eq 'idle') {
            $reply{state} = 'idle';
        } else {
            $reply{state} = 'building';
            $reply{pkgbase} = $state->{pkgbase};
        }
        $handle->push_write(json => \%reply);
        return;
    }
    
    # kill the client, bad ssl auth
    $condvar->broadcast;
}

# callback for reading data
sub cb_read {
    my ($handle, $data) = @_;
    
    return if (!defined $data);
    
    switch ($data->{command}) {
        case "add" {
            cb_add($data);
        }
        case ["done", "fail"] {
            if ($state->{command} eq $data->{command} && $state->{pkgbase} eq $data->{pkgbase}) {
                print "ACK: $state->{command}, setting idle\n";
                $state->{command} = 'idle';
            }
        }
        case "next" {
            if ($state->{command} && $state->{command} ne "idle") { # this shouldn't happen, but just in case..
                $data->{command} = 'release';
                $h->push_write(json => $data);
            } else {
                $state = $data;
                foreach my $file (keys %files) {                    # ensure there aren't lingering files
                    delete $files{$file};
                }
                undef $current_filename;
                build_start($data->{repo}, $data->{pkgbase});
            }
        }
        case "open" {
            $handle->on_drain(sub { cb_upload(@_); });
            cb_upload();
        }
        case "prep" {
            my $filename = $current_filename;
            $filename =~ s/^\/.*\///;
            my %reply = ( command   => "open",
                          type      => "pkg",
                          filename  => $filename);
            $handle->push_write(json => \%reply);
        }
        case "release" {
            $state->{command} = 'idle';
        }
        case "stop" {
            if ($state->{command} && $state->{command} ne "idle") { # also shouldn't happen
                undef $child;
                kill 'TERM', -$childpid if ($childpid);
                foreach my $file (%files) {
                    delete $files{$file};
                }
                undef $current_filename;
                $state->{command} = 'release';
                $h->push_write(json => $state);
                $childpid = 0;
            }
        }
        case "uploaded" {
            if ($state->{command} eq "fail") { # we're done, just uploaded a log
                $handle->push_write(json => $state);
                delete $files{$current_filename};
                undef $current_filename;
            } else {
                cb_add();
            }
        }
    }
}

sub build_start {
    my ($repo, $pkgbase) = @_;
    
    $childpid = fork();
    if (!defined $childpid) {
        print "error: can't fork\n";
        $condvar->broadcast;
        return;
    } elsif ($childpid) {
        $child = AnyEvent->child(pid => $childpid, cb => \&build_finish);
        return;
    }
    
    # set child thread process group for efficient killing
    setpgrp;
    
    # sanitize workspace
    chdir "$Bin";
    `rm -rf $workroot; mkdir $workroot`;
    `rm -rf $pkgdest; mkdir $pkgdest`;
    
    # download/extract workunit
    chdir "$workroot";
    system("wget $workurl/$repo-$pkgbase.tgz");
    system("tar -zxf $workroot/$repo-$pkgbase.tgz");
    
    # strip lingering illegal force option
    chdir "$workroot/$pkgbase";
    `sed -i "/^options=/s/force//" PKGBUILD`;
    
    # rebuild sources in case of old/bad checksums
    print " -> Rebuild sources\n";
    system("makepkg -g --asroot >> PKGBUILD");
    
    # build package, replace perl process with mkarchroot
    print " -> PKGDEST='$pkgdest' $makepkg\n";
    exec("mkarchroot -u $chroot/root; PKGDEST='$pkgdest' $makepkg") or print "couldn't exec: $!";
}

sub build_finish {
    my ($pid, $status) = @_;
    my %reply;
    
    $childpid = 0;
    
    # build failed
	if ($status) {
        # set fail state
        $state->{command} = 'fail';

        # check for log file
        my ($logfile) = glob("$chroot/copy/build/*-package.log") ||
                        glob("$chroot/copy/build/*-check.log")   ||
                        glob("$chroot/copy/build/*-build.log");
        if ($logfile) { # set log file in upload file list
            $files{$logfile} = 0;
            $current_filename = $logfile;
            $logfile =~ s/^\/.*\///;
            %reply = ( command   => "open",
                       type      => "log",
                       filename  => $logfile);
            $h->push_write(json => \%reply);
        } else {        # no log, communicate failure
            $h->push_write(json => $state);
        }
        
    }
	
    # build succeeded
    else {
        # enumerate packages for upload
        foreach my $filename (glob("$pkgdest/*")) {
            #$filename =~ s/^\/.*\///;
            next if ($filename eq "");
            my $md5sum_file = `md5sum $filename`;
            $md5sum_file = (split(/ /, $md5sum_file))[0];
            $files{$filename} = $md5sum_file;
            $current_filename = $filename;
        }
        
        # prepare server for upload
        $state->{command} = 'prep';
        $h->push_write(json => $state);
    }
}

sub cb_upload {
    if ($current_fh) {
        my ($data, $bytes);
        $bytes = read $current_fh, $data, 65536;
        if ($bytes) {
            $bytes = pack "N", $bytes;
            $data = $bytes . $data;
            $h->push_write($data);
        } else {
            print "-> sending zero\n";
            $bytes = pack "N", $bytes;
            undef $h->{on_drain};   # stop drain event
            $h->push_write($bytes);
            close $current_fh;
            undef $current_fh;
        }
    } else {
        print "-> opening $current_filename\n";
        open $current_fh, "<$current_filename";
        binmode $current_fh if ($state->{command} ne 'fail');
    }
}

sub cb_add {
    my $data = shift;
    
    # add just uploaded file
    if (!defined $data) {
        my $filename = $current_filename;
        $filename =~ s/^\/.*\///;
        my $md5sum = $files{$current_filename};
        # query file for extra information
        my $info = `tar -xOf $current_filename .PKGINFO 2>&1`;
        my ($pkgname) = $info =~ m/pkgname = (.*)\n?/;
        my ($pkgver) = $info =~ m/pkgver = (.*)\n?/;
        my $pkgrel;
        ($pkgver, $pkgrel) = split(/-/, $pkgver, 2);
        my ($pkgdesc) = $info =~ m/pkgdesc = (.*)\n?/;
        
        # construct message for server
        my %reply = ( command   => "add",
                      pkgbase   => $state->{pkgbase},
                      pkgname   => $pkgname,
                      pkgver    => $pkgver,
                      pkgrel    => $pkgrel,
                      pkgdesc   => $pkgdesc,
                      repo      => $state->{repo},
                      filename  => $filename,
                      md5sum    => $md5sum );
                
        # communicate reply
        $h->push_write(json => \%reply);
        return;
    }
    
    # delete successfully uploaded file from our list (or not)
    if ($data->{response} eq "OK") {
        delete $files{$current_filename};
        undef $current_filename;
    } elsif ($data->{response} eq "FAIL") {
        print " -> failed to upload file, trying again..\n";
    }
    
    # start next file uploading or send done
    if (!$current_filename && (my ($filename, $md5sum) = each(%files))) {
        $current_filename = $filename;
    }
    if ($current_filename) {
        my $filename = $current_filename;
        $filename =~ s/^\/.*\///;
        my %reply = ( command   => "open",
                      type      => "pkg",
                      filename  => $filename);
        $h->push_write(json => \%reply);
    } else {
        print " -> finished uploading, sending done\n";
        $state->{command} = 'done';
        $h->push_write(json => $state);
    }
}

