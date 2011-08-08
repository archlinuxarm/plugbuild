#!/usr/bin/perl -w
#
# PlugBuild external client server
#

use strict;

package PlugApps::Build::Service;
use Thread::Queue;
use Thread::Semaphore;
use Switch;
use AnyEvent;
use AnyEvent::TLS;
use AnyEvent::Handle;
use AnyEvent::Socket;

our $available = Thread::Semaphore->new(1);

our ($q_svc,$q_db,$q_irc);

sub new {
    my ($class,$config) = @_;
    my $self = $config;
    
    bless $self,$class;
    return $self;
}

sub Run {
    my $self = shift;
    my %clients;
    
    print "SvcRun\n";
    
    $self->{condvar} = AnyEvent->condvar;
    $self->{clients} = \%clients;
    
    if ($available->down_nb()) {
        my $guard = tcp_server undef, $self->{port}, sub { $self->cb_accept(); };
        $self->{timer} = AnyEvent->timer(interval => .5, cb => sub { $self->cb_queue(); });
        $self->{condvar}->wait;
        $guard->destroy;
        $available->up();
    }
    
    print "SvcRunEnd\n";
    return 0;
}

# callback for accepting a new connection
sub cb_accept {
    my ($self, $fh, $address) = @_;
    die $! unless $fh;
    
    print "address: $address\n";
    my $h;
    $h = new AnyEvent::Handle
                            fh          => $fh,
                            tls         => "accept",
                            peername    => $address,
                            tls_ctx     => {
                                            verify                      => 1,
                                            verify_require_client_cert  => 1,
                                            ca_file                     => $self->{cacert},
                                            cert_file                   => $self->{cert},
                                            cert_password               => $self->{pass},
                                            verify_cb                   => sub { cb_verify_cb(@_); }
                                            },
                            keepalive   => 1,
                            no_delay    => 1,
                            rtimeout    => 3, # 3 seconds to authenticate with SSL before destruction
                            on_rtimeout => sub { $h->destroy; },
                            on_error    => sub { $self->cb_error(@_); },
                            on_starttls => sub { $self->cb_starttls(@_); }
                            ;
    
    print "[SVC] new client connection from $address\n";
    $self->{clients}->{$h} = $h;
}

# callback that handles peer certificate verification
sub cb_verify_cb {
    my ($self, $tls, $ref, $cn, $depth, $preverify_ok, $x509_store_ctx, $cert) = @_;
    
	# depth is zero when we're verifying peer certificate
    return $preverify_ok if $depth;
    
    # get information i'll use somewhere later..
    my $orgunit = Net::SSLeay::X509_NAME_get_text_by_NID(Net::SSLeay::X509_get_subject_name($cert), Net::SSLeay->NID_organizationalUnitName);
    my $common = Net::SSLeay::X509_NAME_get_text_by_NID(Net::SSLeay::X509_get_subject_name($cert), Net::SSLeay->NID_commonName);
    my @cert_alt = Net::SSLeay::X509_get_subjectAltNames($cert);
    my $ip = AnyEvent::Socket::parse_address $cn;
    
    # verify ip address in client cert subject alt name against connecting ip
    while (my ($type, $name) = splice @cert_alt, 0, 2) {
        if ($type == Net::SSLeay::GEN_IPADD()) {
            if ($ip eq $name) {
                $q_irc->enqueue(['svc', 'print', "[SSL] verified ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert))]);
                $ref->{rtimeout} = 0; # stop the auto-destruct
                return 1;
            }
        }
    }
    
    $q_irc->enqueue(['svc', 'print', "[SSL] failed verification for $ip:". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert))]);
    return 0;
}

# callback on socket error
sub cb_error {
	my ($self, $handle, $fatal, $message) = @_;
    
    if ($fatal) {
        print "fatal ";
        undef $self->{clients}->{$handle};
    }
	print "error from $handle->{peername} - $message\n";
}

# callback on whether ssl auth succeeded
sub cb_starttls {
	my ($self, $handle, $success, $error) = @_;
    
	if ($success) {
        # set read callback now that ssl is good
        $handle->on_read(sub { $self->cb_read(); });
        return;
    }
    
    # kill the connection, bad ssl auth
	$handle->destroy;
}

# callback for reading data
sub cb_read {
	my ($self, $handle) = @_;
    
	my $buf = $handle->rbuf;
    chomp($buf);
    my ($command, $data) = split(/!/, $buf);
    return if (!defined $data);
    switch ($command) {	# <command>!<data>
        case "new" {    # new!<builder>
            $q_db->enqueue(['svc','next',$handle,$data]);
        }
        case "add" {    # add!<repo>|<package>|<filename.tar.xz>|<md5sum>
            print "   -> adding package: $data\n";
            $q_db->enqueue(['svc','add',$handle,$data]);
        }
        case "done" {   # done!<package>
            print "   -> package done: $data\n";
            $q_irc->enqueue(['svc','print',"[done] $data"]);#irc_priv_print "[done] $data";
            $q_db->enqueue(['svc','done',$data]);
            $handle->push_write("OK\n");
        }
        case "fail" {   # fail!<package>
            $q_db->enqueue(['svc','fail',$data]);
            print "   ->package fail: $data\n";
            $handle->push_write("OK\n");
            $q_irc->enqueue(['svc','print',"[fail] $data"]);
        }
    }

}

# callback for the queue timer
sub cb_queue {
    my ($self, $con) = @_;
    my $msg = $q_svc->dequeue_nb();
    if ($msg) {
        my ($from, $order) = @{$msg};
        print "SVC[$from $order]\n";
        switch($order){
            case "next" {
                my ($who,$response,$what) = @{$msg}[2,3,4];
                print "   -> builder $who: $response\n";
                #my $cs = $wait_next{$who};
                #last if (! defined $cs); # bail out if client disconnected early
                #print $cs "$response\n";
                if ($response ne "FAIL") {
                    $q_irc->enqueue(['svc','print',"[new] builder: $who - package: $response"]);
                } else {
                    $q_irc->enqueue(['svc','print',"[new] found no package to issue $who"]);
                }
                #delete $wait_next{$who};
            }
            case "add" {
                my ($pkg,$response,$what) = @{$msg}[2,3,4];
                #my $cs = $wait_add{$pkg};
                #if ($response eq "FAIL") {
                #    print $cs "FAIL\n";
                #} else {
                #    print $cs "OK\n";
                #}
                #delete $wait_add{$pkg};
            }
        }
        if ($order eq 'quit' || $order eq 'recycle'){
            undef $self->{timer};
            $self->{condvar}->broadcast;
            return;
        }
    }
}

1;
