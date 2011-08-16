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
use JSON::XS;

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
    my %clientsref;
    
    print "SvcRun\n";
    
    $self->{condvar} = AnyEvent->condvar;
    $self->{clients} = \%clients;
    $self->{clientsref} = \%clientsref;
    
    if ($available->down_nb()) {
        # start-up
        my $guard = tcp_server undef, $self->{port}, sub { $self->cb_accept(@_); };
        my $timer = AnyEvent->timer(interval => .5, cb => sub { $self->cb_queue(@_); });
        $self->{condvar}->wait;
        
        # shutdown
        undef $timer;
        $guard->cancel;
        while (my ($key, $value) = each %clients) {
            $value->{handle}->destroy;
        }
        $available->up();
    }
    
    print "SvcRunEnd\n";
    return 0;
}

# callback for accepting a new connection
sub cb_accept {
    my ($self, $fh, $address) = @_;
    return unless $fh;
    
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
                                            verify_cb                   => sub { $self->cb_verify_cb(@_); }
                                            },
                            keepalive   => 1,
                            no_delay    => 1,
                            rtimeout    => 3, # 3 seconds to authenticate with SSL before destruction
                            rbuf_max    => 0, # disable reading until SSL auth (DDoS prevention)
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
    
    # get certificate information
    my $orgunit = Net::SSLeay::X509_NAME_get_text_by_NID(Net::SSLeay::X509_get_subject_name($cert), Net::SSLeay->NID_organizationalUnitName);
    $orgunit =~ s/\W//g;
    my $common = Net::SSLeay::X509_NAME_get_text_by_NID(Net::SSLeay::X509_get_subject_name($cert), Net::SSLeay->NID_commonName);
    $common =~ s/\W//g;
    my @cert_alt = Net::SSLeay::X509_get_subjectAltNames($cert);
    my $ip = AnyEvent::Socket::parse_address $cn;
    
    # verify ip address in client cert subject alt name against connecting ip
    while (my ($type, $name) = splice @cert_alt, 0, 2) {
        if ($type == Net::SSLeay::GEN_IPADD()) {
            if ($ip eq $name) {
                $q_irc->enqueue(['svc', 'print', "[SVC] verified ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert))]);
                my %client = ( handle   => $ref,                # connection handle - must be preserved
                               ip       => $ref->{peername},    # dotted quad ip address
                               ou       => $orgunit,            # OU from cert - currently one of: armv5, armv7, mirror
                               cn       => $common );           # CN from cert - unique client name (previously builder name)
                $self->{clients}->{$ref} = \%client;            # replace into instance's clients hash
                $self->{clientsref}->{"$orgunit/$common"} = $ref;
                return 1;
            }
        }
    }
    
    $q_irc->enqueue(['svc', 'print', "[SVC] failed verification for $ref->{peername}: ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert))]);
    return 0;
}

# callback on socket error
sub cb_error {
    my ($self, $handle, $fatal, $message) = @_;
    
    if ($fatal) {
        print "fatal ";
        if (defined $self->{clients}->{$handle}->{cn}) {
            $q_irc->enqueue(['svc', 'print', "[SVC] $self->{clients}->{$handle}->{ou}/$self->{clients}->{$handle}->{cn} disconnected: $message"]);
            delete $self->{clientsref}->{"$self->{clients}->{$handle}->{ou}/$self->{clients}->{$handle}->{cn}"};
        }
        delete $self->{clients}->{$handle};
    }
    print "error from $handle->{peername} - $message\n";
}

# callback on whether ssl auth succeeded
sub cb_starttls {
    my ($self, $handle, $success, $error) = @_;
    
    if ($success) {
        $handle->rtimeout(0);       # stop auto-destruct
        undef $handle->{rbuf_max};  # enable read buffer
        $handle->on_read(sub { $handle->push_read(json => sub { $self->cb_read(@_); }) });    # set read callback
        return;
    }
    
    # kill the connection, bad ssl auth
    $handle->destroy;
}

# callback for reading data
sub cb_read {
    my ($self, $handle, $data) = @_;
    
    return if (!defined $data);
    
    my $client = $self->{clients}->{$handle};
    
    # switch on OU (client type)
    switch ($client->{ou}) {
        
        # builder client - OU = architecture
        case ["armv5","armv7"] {
            switch ($data->{command}) {
                
                # insert package into repository
                #  - pkgbase    => top level package name
                #  - pkgname    => individual package name
                #  - pkgdesc    => package description
                #  - repo       => repository (core/extra/community/aur)
                #  - filename   => uploaded filename.tar.xz
                #  - md5sum     => md5sum for upload verification
                case "add" {
                    print "   -> adding package: $client->{ou}/$client->{cn} $data->{pkgbase}\n";
                    $q_db->enqueue(['svc', 'add', $client->{ou}, $client->{cn}, $data]);
                }
                
                # build for top-level package is complete
                #  - pkgbase    => top level package name
                case "done" {
                    print "   -> package done: $client->{ou}/$client->{cn} $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc', 'print', "[done] $client->{ou}/$client->{cn} $data->{pkgbase}"]);
                    $q_db->enqueue(['svc', 'done', $client->{ou}, $data->{pkgbase}]);
                    $handle->push_write(json => $data); # ACK via original hash
                }
                
                # build failed for package
                #  - pkgbase    => top level package name
                case "fail" {
                    print "   -> package fail: $client->{ou}/$client->{cn} $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc','print',"[fail] $client->{ou}/$client->{cn} $data"]);
                    $q_db->enqueue(['svc','fail',$client->{ou},$data->{pkgbase}]);
                    $handle->push_write(json => $data); # ACK via original hash
                }
                
                # request for new package
                case "next" {
                    $q_db->enqueue(['svc', 'next', $client->{ou}, $client->{cn}]);
                }
                
                # prepare database/repo for incoming new package
                #  - pkgbase    => top level package name
                case "prep" {
                    print "   -> preparing package: $client->{ou}/$client->{cn} $data->{pkgbase}\n";
                    $q_db->enqueue(['svc', 'prep', $client->{ou}, $client->{cn}, $data]);
                }
            }
        }
        
        # mirror client
        case "mirror" {
            print "TODO\n";
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
                my ($ou, $cn, $data) = @{$msg}[2,3,4];
                my $handle = $self->{clientsref}->{"$ou/$cn"};
                
                print "   -> next for $ou/$cn: $data->{pkgbase}\n";
                $handle->push_write(json => $data);
                if ($data->{pkgbase} ne "FAIL") {
                    $q_irc->enqueue(['svc','print',"[new] builder: $ou/$cn - package: $data->{pkgbase}"]);
                } else {
                    $q_irc->enqueue(['svc','print',"[new] found no package to issue $ou/$cn"]);
                }
            }
            case "ack" {
                my ($ou, $cn, $data) = @{$msg}[2,3,4];
                my $handle = $self->{clientsref}->{"$ou/$cn"};
                
                $handle->push_write(json => $data);
            }
        }
        if ($order eq 'quit' || $order eq 'recycle'){
            $self->{condvar}->broadcast;
            return;
        }
    }
}

1;
