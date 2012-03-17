#!/usr/bin/perl -w
#
# PlugBuild external client server
#

use strict;

package ALARM::Build::Service;
use Thread::Queue;
use Thread::Semaphore;
use Switch;
use AnyEvent;
use AnyEvent::TLS;
use AnyEvent::Handle;
use AnyEvent::Socket;
use JSON::XS;

our $available = Thread::Semaphore->new(1);

our ($q_svc, $q_db, $q_irc, $q_mir);

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
        my $service = tcp_server undef, $self->{port}, sub { $self->cb_accept(@_, 0); };
        my $nodesvc = tcp_server "127.0.0.1", $self->{port}+1, sub { $self->node_accept(@_, 0); };
        my $timer = AnyEvent->timer(interval => .5, cb => sub { $self->cb_queue(@_); });
        $self->{condvar}->wait;
        
        # shutdown
        undef $timer;
        $service->cancel;
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

# callback for accepting internal nodejs connection (only one allowed)
sub node_accept {
    my ($self, $fh, $address) = @_;
    return unless $fh;
    
    # purge any previous nodejs connection
    if (defined $self->{clientsref}->{"admin/nodejs"}) {
        print "[SVC] dropping previous nodejs connection\n";
        my $h_old = $self->{clientsref}->{"admin/nodejs"};
        delete $self->{clientsref}->{"admin/nodejs"};
        delete $self->{clients}->{$h_old};
        $h_old->destroy;
    }
    
    my $h;
    $h = new AnyEvent::Handle
                            fh          => $fh,
                            peername    => $address,
                            keepalive   => 1,
                            no_delay    => 1,
                            on_error    => sub { $self->cb_error(@_); },
                            on_read     => sub { $h->push_read(json => sub { $self->cb_read(@_); }) }
                            ;
    
    $q_irc->enqueue(['svc', 'print', "[SVC] NodeJS accepted on $address"]);
    my %client = ( handle   => $h,              # connection handle - must be preserved
                   ip       => $address,        # dotted quad ip address
                   ou       => "admin",         # OU = admin
                   cn       => "nodejs" );      # CN = nodejs
    $self->{clients}->{$h} = \%client;
    $self->{clientsref}->{"admin/nodejs"} = $h;
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
                               ou       => $orgunit,            # OU from cert - currently one of: armv5, armv7
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
        if (defined $self->{clients}->{$handle}->{cn}) {    # delete our OU/CN reference if it exists
            $q_irc->enqueue(['svc', 'print', "[SVC] $self->{clients}->{$handle}->{ou}/$self->{clients}->{$handle}->{cn} disconnected: $message"]);
            if ($self->{clients}->{$handle}->{ou} eq "armv5" || $self->{clients}->{$handle}->{ou} eq "armv7") {
                $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { fqn => "$self->{clients}->{$handle}->{cn}/$self->{clients}->{$handle}->{ou}", state => 'disconnect' } }]);
            }
            if (defined $self->{clients}->{$handle}->{file}) {      # close out file if it's open
                close $self->{clients}->{$handle}->{file};
            }
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
        $handle->on_read(sub { $handle->push_read(json => sub { $self->cb_read(@_); }) });  # set read callback
        return;
    }
    
    # kill the connection, bad ssl auth
    $handle->destroy;
}

# callback for reading json data
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
                #  - pkgver     => package version
                #  - pkgrel     => release number
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
                    $q_irc->enqueue(['svc', 'print', "[\0033done\003] $client->{ou}/$client->{cn} $data->{pkgbase}"]);
                    $q_db->enqueue(['svc', 'done', $client->{ou}, $data->{pkgbase}]);
                    $handle->push_write(json => $data); # ACK via original hash
                    if ($client->{state} ne 'manual') {
                        $client->{state} = 'idle';
                        $self->push_next($client->{ou});
                    }
                    
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'package', package => { state => 'done', arch => $client->{ou}, package => $data->{pkgbase} } }]);
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { fqn => "$client->{ou}/$client->{cn}", state => 'idle' } }]);
                }
                
                # build failed for package
                #  - pkgbase    => top level package name
                case "fail" {
                    print "   -> package fail: $client->{ou}/$client->{cn} $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc','print',"[\0034fail\003] $client->{ou}/$client->{cn} $data->{pkgbase}"]);
                    $q_db->enqueue(['svc','fail',$client->{ou},$data->{pkgbase}]);
                    $handle->push_write(json => $data); # ACK via original hash
                    $client->{state} = 'idle';
                    $self->push_next($client->{ou});
                    
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'package', package => { state => 'fail', arch => $client->{ou}, package => $data->{pkgbase} } }]);
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { fqn => "$client->{ou}/$client->{cn}", state => 'idle' } }]);
                }
                
                # open file for writing, change read callback to get raw data instead of json
                #  - type       => 'pkg' or 'log'
                #  - filename   => filename to be uploaded
                case "open" {
                    print "   -> $client->{ou}/$client->{cn}: opening $data->{type} file $data->{filename}\n";
                    my $file;
                    if ($data->{type} eq "pkg") {
                        open $file, ">$self->{in_pkg}/$client->{ou}/$data->{filename}";
                        binmode $file;
                    } elsif ($data->{type} eq "log") {
                        open $file, ">$self->{in_log}/$data->{filename}";
                    }
                    $client->{file} = $file;
                    $handle->on_read(sub { $self->cb_readfile(@_); });
                    $handle->push_write(json => $data); # ACK via original hash
                }
                
                # connection keepalive ping/pong action
                case "ping" {
                    $handle->push_write(json => $data);
                }
                
                # prepare database/repo for incoming new package
                #  - pkgbase    => top level package name
                case "prep" {
                    print "   -> preparing package: $client->{ou}/$client->{cn} $data->{pkgbase}\n";
                    $q_db->enqueue(['svc', 'prep', $client->{ou}, $client->{cn}, $data]);
                }
                
                # release build from client
                #  - pkgbase    => top level package name
                case "release" {
                    print "   -> releasing package: $client->{ou}/$client->{cn} $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc','print',"[released] $client->{ou}/$client->{cn} $data->{pkgbase}"]);
                    $q_db->enqueue(['svc', 'release', $client->{ou}, $client->{cn}, $data]);
                    $handle->push_write(json => $data); # ACK via original hash
                    $client->{state} = 'idle';
                    
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'package', package => { state => 'release', arch => $client->{ou}, package => $data->{pkgbase} } }]);
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { fqn => "$client->{ou}/$client->{cn}", state => 'idle' } }]);
                }
                
                # synchronize client state
                case "sync" {
                    print "   -> synchronizing $client->{ou}/$client->{cn} to $data->{state}\n";
                    $client->{state} = $data->{state};
                    if ($data->{state} eq 'building') {
                        $client->{pkgbase} = $data->{pkgbase};
                        $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { fqn => "$client->{ou}/$client->{cn}", state => 'building', package => $data->{pkgbase} } }]);
                    } else {
                        $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { fqn => "$client->{ou}/$client->{cn}", state => 'idle' } }]);
                    }
                }
            }
        }
        
        # admin client (nodejs)
        case "admin" {
            switch ($data->{command}) {
                # dump package and builder states
                case "dump" {
                    print "[SVC] admin -> dump\n";
                    $q_db->enqueue(['svc', 'dump', $client->{ou}, $client->{cn}, $data]);
                    foreach my $oucn (keys %{$self->{clientsref}}) {
                        next if (!($oucn =~ m/armv.\/.*/));
                        my $builder = $self->{clients}->{$self->{clientsref}->{$oucn}};
                        if ($builder->{state} eq 'idle') {
                            $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { fqn => "$builder->{ou}/$builder->{cn}", state => 'idle' } }]);
                        } else {
                            $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { fqn => "$builder->{ou}/$builder->{cn}", state => 'building', package => $builder->{pkgbase} } }]);
                        }
                    }
                }
                
                # echo the received json back
                case "echo" {
                    print "[SVC] admin -> echo\n";
                    $handle->push_write(json => $data);
                    $handle->push_write("\000");
                }
            }
        }
    }
}

# callback for reading file data
sub cb_readfile {
    my ($self, $handle) = @_;
    
    $handle->unshift_read(chunk => 4, sub {             # data stream chunks are prefixed by a 4-byte N pack'd length
        my ($handle, $data) = @_;
        my $len = unpack "N", $data;
        if ($len == 0) {                                # zero length = end of stream, switch back to json parsing
            close $self->{clients}->{$handle}->{file};
            undef $self->{clients}->{$handle}->{file};
            $handle->on_read(sub { $handle->push_read(json => sub { $self->cb_read(@_); }) });
            $handle->push_write(json => { command => 'uploaded' });
        } else {
            $handle->unshift_read(chunk => $len, sub {  # only buffer specified data length
                my ($handle, $data) = @_;
                my $file = $self->{clients}->{$handle}->{file};
                print $file $data if $file;
            });
        }
    });
}

# callback for the queue timer
sub cb_queue {
    my ($self, $con) = @_;
    my $msg = $q_svc->dequeue_nb();
    if ($msg) {
        my ($from, $order) = @{$msg};
        print "SVC[$from $order]\n";
        $order =~ s/\!// if ($from eq 'irc');
        switch($order){
            case "ack" {
                my ($ou, $cn, $data) = @{$msg}[2,3,4];
                my $handle = $self->{clientsref}->{"$ou/$cn"};
                
                $handle->push_write(json => $data) if defined $handle;
            }
            case "admin" {
                my ($data) = @{$msg}[2];
                my $handle = $self->{clientsref}->{"admin/nodejs"};
                
                if (defined $handle) {
                    $handle->push_write(json => $data);
                    $handle->push_write("\000");
                }
            }
            case "list" {
                $self->list();
            }
            case "next" {
                my ($ou, $cn, $data) = @{$msg}[2,3,4];
                my $handle = $self->{clientsref}->{"$ou/$cn"};
                
                if ($data->{pkgbase} ne "FAIL") {
                    $q_irc->enqueue(['svc','print',"[new] builder: $ou/$cn - package: $data->{pkgbase}"]);
                    print "   -> next for $ou/$cn: $data->{pkgbase}\n";
                    $handle->push_write(json => $data);
                    $self->{clients}->{$handle}->{state} = 'building';
                    $self->{clients}->{$handle}->{pkgbase} = $data->{pkgbase};
                    
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { fqn => "$ou/$cn", state => 'building', package => $data->{pkgbase} } }]);
                } else {
                    $q_irc->enqueue(['svc','print',"[new] found no package to issue $ou/$cn"]);
                    $self->{clients}->{$handle}->{state} = 'idle';
                    undef $self->{clients}->{$handle}->{pkgbase};
                    $self->check_complete($ou);
                }
            }
            case ["start","stop"] {
                my $what = @{$msg}[2];
                if ($what eq '5' || $what eq '7') {
                    $self->push_redlightgreenlight($order, "armv$what");
                } elsif ($what eq 'all') {
                    $self->push_redlightgreenlight($order);
                }
            }
        }
        if ($order eq 'quit' || $order eq 'recycle'){
            $self->{condvar}->broadcast;
            return;
        }
    }
}

# push next packages/stop to builders
sub push_next {
    my ($self, $ou) = @_;
    $self->push_redlightgreenlight("start", $ou);
}

sub push_redlightgreenlight {
    my ($self, $action, $ou) = @_;
    my @builders;
    my $count = 0;
    
    # create list of builders, optionally filtered by OU
    foreach my $oucn (keys %{$self->{clientsref}}) {
        next if ($ou && !($oucn =~ m/$ou\/.*/));
        push @builders, $self->{clients}->{$self->{clientsref}->{"$oucn"}};
    }
    
    # get next package for idle builders
    foreach my $builder (@builders) {
        if ($action eq "start") {
            next if ($builder->{state} ne 'idle');
            $builder->{state} = 'check';
            $q_db->enqueue(['svc', 'next', $builder->{ou}, $builder->{cn}]);
            $count++;
        } elsif ($action eq "stop") {
            next if ($builder->{state} eq 'idle');
            $builder->{handle}->push_write(json => {command => 'stop'});
            $count++;
        }
    }
    
    if (!$count) {
        $q_irc->enqueue(['svc','print',"[$action] no builders to $action"]);
    }
}

# list connected clients to irc
sub list {
    my $self = shift;
    
    if (!(keys %{$self->{clientsref}})) {
        $q_irc->enqueue(['svc','print',"[list] no clients connected"]);
        return;
    }
    
    $q_irc->enqueue(['svc','print',"[list] Connected clients:"]);
    foreach my $oucn (keys %{$self->{clientsref}}) {
        my $pkgbase = $self->{clients}->{$self->{clientsref}->{$oucn}}->{pkgbase} || '';
        $q_irc->enqueue(['svc','print',"[list]  - $oucn: $self->{clients}->{$self->{clientsref}->{$oucn}}->{state} $pkgbase"]);
    }
}

# check if all builders are done for an architecture, trigger mirror sync
sub check_complete {
    my ($self, $arch) = @_;
    my @builders;
    
    # get list of builders for specified arch
    foreach my $oucn (keys %{$self->{clientsref}}) {
        next if (!($oucn =~ m/$arch\/.*/));
        push @builders, $self->{clients}->{$self->{clientsref}->{"$oucn"}};
    }
    
    # determine if all builders are idle
    my $total = 0;
    my $count = 0;
    foreach my $builder (@builders) {
        $total++;
        $count++ if ($builder->{state} eq 'idle');
    }
    if ($total && $count == $total) {
        $q_mir->enqueue(['svc', 'update', $arch]);
    }
}

1;
