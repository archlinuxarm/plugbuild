#!/usr/bin/perl
#
# PlugBuild Build System Farm Manager
#

use strict;
use FindBin qw($Bin);
use Config::General qw(ParseConfig);
use Switch;
use AnyEvent;
use AnyEvent::TLS;
use AnyEvent::Handle;
use AnyEvent::Socket;
use JSON::XS;

my %config = ParseConfig("$Bin/farmer.conf");

# AnyEvent setup
my $condvar = AnyEvent->condvar;
my $plugbuild;
my $w = AnyEvent->signal(signal => "INT", cb => sub { $condvar->broadcast; });
my $timer_retry;

# main event loop
con();
$condvar->wait;

# shutdown
$plugbuild->destroy;


### control subroutines

# connect to service
sub con {
    $plugbuild = new AnyEvent::Handle
        connect             => [$config{server} => $config{port}],
        tls                 => "connect",
        tls_ctx             => {
                                verify          => 1,
                                ca_file         => $config{ca_file},
                                cert_file       => $config{cert_file},
                                cert_password   => $config{password},
                                verify_cb       => sub { cb_verify_cb(@_); }
                                },
        keepalive           => 1,
        no_delay            => 1,
        rtimeout            => 3, # 3 seconds to authenticate with SSL before destruction
        wtimeout            => 60,
        on_wtimeout         => sub { $plugbuild->push_write(json => { command => 'ping' }); },
        on_rtimeout         => sub { $plugbuild->destroy; $condvar->broadcast; },
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
        $handle->push_write(json => {command => 'sync', address => $config{rsync}});
        return;
    }
    
    # kill the client, bad ssl auth
    $condvar->broadcast;
}

# callback for reading data
sub cb_read {
    my ($handle, $data) = @_;
    
    return if (!defined $data);
    
    my $arch = $data->{arch};
    my $repo = $data->{repo};
    my $arg  = $data->{arg};
    switch ($data->{command}) {
        # repo-add package file
        case "add" {
            system("repo-add -q $config{$arch}/$repo/$repo.db.tar.gz $config{$arch}/$repo/$arg");
        }
        
        # delete package file and signature from filesystem
        case "delete" {
            system("rm -f $config{$arch}/$repo/$arg");
            system("rm -f $config{$arch}/$repo/$arg.sig");
        }
        
        # move package and signature from incoming directory into repository
        case "insert" {
            system("mv -f $config{incoming}/$arch/$arg $config{$arch}/$repo");
            system("mv -f $config{incoming}/$arch/$arg.sig $config{$arch}/$repo");
        }
        
        # move package and signature between repositories
        case "move" {
            my ($oldrepo, $newrepo) = @{$repo};
            system("mv $config{$arch}/$oldrepo/$arg $config{$arch}/$newrepo/$arg");
            system("mv $config{$arch}/$oldrepo/$arg.sig $config{$arch}/$newrepo/$arg.sig");
        }
        
        # repo-remove package
        case "remove" {
            system("repo-remove -q $config{$arch}/$repo/$repo.db.tar.gz $arg");
        }
        
        # sync ACK
        case "sync" {
            print "-> Local repositories synchronized.\n";
        }
    }
}
