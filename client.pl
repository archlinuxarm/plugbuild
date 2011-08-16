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
my $server  = "archlinuxarm.org";
my $port    = 2123;

# chroot location
my $chroot = "/root/chroot";

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
my %files;

# AnyEvent setup
my $condvar = AnyEvent->condvar;
my $h;

# main event loop
con();
$condvar->wait;

# shutdown
$h->destroy;


### control subroutines

# connect
sub con {
    tcp_connect $server, $port, sub {
        my ($fh, $address) = @_;
        die $! unless $fh;
        
        $h = new AnyEvent::Handle
            fh          => $fh,
            tls         => "connect",
            peername    => $address,
            tls_ctx     => {
                            verify          => 1,
                            ca_file         => $ca_file,
                            cert_file       => $cert_file,
                            cert_password   => $password,
                            verify_cb       => sub { cb_verify_cb(@_); }
                            },
            keepalive   => 1,
            no_delay    => 1,
            rtimeout    => 3, # 3 seconds to authenticate with SSL before destruction
            on_rtimeout => sub { $h->destroy; $condvar->broadcast; },
            on_error    => sub { cb_error(@_); },
            on_starttls => sub { cb_starttls(@_); }
            ;
    };
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
        $condvar->broadcast;
    }
    print "error from $handle->{peername} - $message\n";
}

# callback on whether ssl auth succeeded
sub cb_starttls {
    my ($handle, $success, $error) = @_;
    
    if ($success) {
        $handle->rtimeout(0);   # stop auto-destruct
        $handle->on_read(sub { $handle->push_read(json => sub { cb_read(@_); }) });    # set read callback
        $handle->push_write(json => { command => 'next' }); # RM: push build
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
                print "ACK: $state->{command}\n";
                $handle->push_write(json => { command => 'next'}); # RM: push build
            }
        }
        case "next" {
            if ($data->{pkgbase} eq "FAIL") { # RM: push build
                $condvar->broadcast;
            } else {
                $state = $data;
                build_start($data->{repo}, $data->{pkgbase});
            }
        }
        case "prep" {
            cb_add();
        }
    }
}

sub build_start {
    my ($repo, $pkgbase) = @_;
    
    my $pid = fork();
    if (!defined $pid) {
        print "error: can't fork\n";
        $condvar->broadcast;
        return;
    } elsif ($pid) {
        $child = AnyEvent->child(pid => $pid, cb => \&build_finish);
        return;
    }
    
    # set child thread process group
    setpgrp;
    
	# sanitize workspace
	chdir "$Bin";
	`rm -rf $workroot; mkdir $workroot`;
	`rm -rf $pkgdest; mkdir $pkgdest`;

	# download/extract workunit
	chdir "$workroot";
	system("wget $workurl/$repo-$pkgbase.tgz");
	system("tar -zxf $workroot/$repo-$pkgbase.tgz");
	
	# build package
	chdir "$workroot/$pkgbase";
	`sed -i "/^options=/s/force//" PKGBUILD`;
	print " -> PKGDEST='$pkgdest' $makepkg\n";
    exec("mkarchroot -u $chroot/root; PKGDEST='$pkgdest' $makepkg") or print "couldn't exec: $!";
}

sub build_finish {
    my ($pid, $status) = @_;
    
    # build failed
	if ($status) {
        # upload log
        my ($logfile) = glob("$chroot/copy/build/*-build.log");
        if ($logfile) {
            print " -> uploading $logfile\n";
            my $result = `curl --form uploaded=\@$logfile --form press=Upload http://archlinuxarm.org:81/builder/uplog.php`;
            if ($result eq "FAIL") {
                print "    -> failed\n";
            }
        }
        
        # communicate fail
        $state->{command} = 'fail';
        $h->push_write(json => $state);
    }
	
    # build succeeded
    else {
        # enumerate packages for upload
        foreach my $filename (glob("$pkgdest/*")) {
            $filename =~ s/^\/.*\///;
            next if ($filename eq "");
            my $md5sum_file = `md5sum $pkgdest/$filename`;
            $md5sum_file = (split(/ /, $md5sum_file))[0];
            $files{$filename} = $md5sum_file;
        }
        
        # prepare server for upload
        $state->{command} = 'prep';
        $h->push_write(json => $state);
    }
}

sub cb_add {
    my $data = shift;
    
    # delete successfully uploaded file from our list
    if (defined $data) {
        if ($data->{response} eq "OK") {
            delete $files{$data->{filename}};
        } elsif ($data->{response} eq "FAIL") {
            print " -> failed to upload file, continuing cycle\n";
        }
    }
    
    # upload a file
    if (my ($filename, $md5sum) = each(%files)) {
        # query file for extra information
        my $info = `pacman -Qip $pkgdest/$filename`;
        my ($pkgname) = $info =~ m/Name\s*: (.*)\n?/;
        my ($pkgdesc) = $info =~ m/Description\s*: (.*)\n?/;
        
        # construct message for server
        my %reply = ( command   => "add",
                      pkgbase   => $state->{pkgbase},
                      pkgname   => $pkgname,
                      pkgdesc   => $pkgdesc,
                      repo      => $state->{repo},
                      filename  => $filename,
                      md5sum    => $md5sum );
        
        # upload file
        print " -> uploading $filename ($md5sum)\n";
        while (1) {
            my $result = `curl --retry 5 --form uploaded=\@$pkgdest/$filename --form press=Upload http://archlinuxarm.org:81/builder/uppkg.php`;
            chomp($result);
            if ($result eq "ERROR") {
                print "    -> failed to upload";
            } else {
                last;
            }
        }
        
        # communicate reply
        $h->push_write(json => \%reply);
    }
    
    # finished uploading
    else {
        print " -> finished uploading, sending done\n";
        $state->{command} = 'done';
        $h->push_write(json => $state);
    }
}

