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
        my $github = tcp_server undef, $self->{port}+2, sub { $self->gh_accept(@_); };
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

# callback for accepting GitHub WebHook connection
sub gh_accept {
    my ($self, $fh, $address) = @_;
    return unless $fh;
    
    # only accept connections from defined GitHub public service IPs
    if (!grep {$_ eq $address} ('207.97.227.253', '50.57.128.197', '108.171.174.178')) {
        close $fh;
        return;
    }
    
    my $h;
    $h = new AnyEvent::Handle
                            fh          => $fh,
                            peername    => $address,
                            keepalive   => 1,
                            no_delay    => 1,
                            on_error    => sub { print "[SVC] GitHub disconnected.\n"; },
                            on_read     => sub { $h->push_read(regex => qr<\015\012\015\012payload=>, undef, qr<^.*[^\015\012]>, sub { $self->gh_read(@_); })}
                            ;
    print "[SVC] Accepted GitHub connection from $address\n";
};

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
                if (defined $self->{clientsref}->{"$orgunit/$common"}) {
                    my $oldhandle = $self->{clientsref}->{"$orgunit/$common"};
                    $self->cb_error($oldhandle, 1, 'duplicate client disconnect');
                    $oldhandle->destroy;
                }
                $q_irc->enqueue(['svc', 'print', "[SVC] verified ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert))]);
                my %client = ( handle   => $ref,                # connection handle - must be preserved
                               ip       => $ref->{peername},    # dotted quad ip address
                               ou       => $orgunit,            # OU from cert - currently one of: builder/admin
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
            if ($self->{clients}->{$handle}->{ou} eq "builder") {
                $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $self->{clients}->{$handle}->{cn}, state => 'disconnect' } }]);
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
        $handle->rtimeout(300);     # stop auto-destruct, reset for 5 minute ping timeout
        $handle->on_rtimeout(sub { my $h = shift; $self->cb_error($h, 1, 'read timeout'); $h->destroy; });
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
        
        # builder client
        case "builder" {
            switch ($data->{command}) {
                
                # insert package into repository
                #  - arch       => architecture built
                #  - pkgbase    => top level package name
                #  - pkgname    => individual package name
                #  - pkgver     => package version
                #  - pkgrel     => release number
                #  - pkgdesc    => package description
                #  - repo       => repository (core/extra/community/aur)
                #  - filename   => uploaded filename.tar.xz
                #  - md5sum     => md5sum for upload verification
                case "add" {
                    print "   -> adding package: $client->{cn} ($data->{arch}) $data->{pkgbase}\n";
                    $q_db->enqueue(['svc', 'add', $data->{arch}, $client->{cn}, $data]);
                }
                
                # build for top-level package is complete
                #  - arch       => architecture built
                #  - pkgbase    => top level package name
                case "done" {
                    print "   -> package done: $client->{cn} ($data->{arch}) $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc', 'print', "[\0033done\003] $client->{cn} ($data->{arch}) $data->{pkgbase}"]);
                    $q_db->enqueue(['svc', 'done', $data->{arch}, $data->{pkgbase}]);
                    $handle->push_write(json => $data); # ACK via original hash
                    if ($client->{state} ne 'manual') {
                        $client->{state} = 'idle';
                        undef $client->{pkgbase};
                        undef $client->{arch};
                        if ($self->{$client->{primary}} eq 'start') {           # if the builder's primary is active, push for packages for that
                            $self->push_builder('start', $client->{primary});
                        } else {                                                # otherwise, the package's arch will still be active so push for that
                            $self->push_builder('start', $data->{arch});
                        }
                    }
                    
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'package', package => { state => 'done', arch => $data->{arch}, package => $data->{pkgbase} } }]);
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $client->{cn}, state => 'idle' } }]);
                }
                
                # build failed for package
                #  - arch       => architecture built
                #  - pkgbase    => top level package name
                case "fail" {
                    print "   -> package fail: $client->{cn} ($data->{arch}) $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc', 'print', "[\0034fail\003] $client->{cn} ($data->{arch}) $data->{pkgbase}"]);
                    $q_db->enqueue(['svc', 'fail', $data->{arch}, $data->{pkgbase}]);
                    $handle->push_write(json => $data); # ACK via original hash
                    undef $client->{pkgbase};
                    undef $client->{arch};
                    $client->{state} = 'idle';
                    if ($self->{$client->{primary}} eq 'start') {               # if the builder's primary is active, push for packages for that
                        $self->push_builder('start', $client->{primary});
                    } else {                                                    # otherwise, the package's arch will still be active so push for that
                        $self->push_builder('start', $data->{arch});
                    }
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'package', package => { state => 'fail', arch => $data->{arch}, package => $data->{pkgbase} } }]);
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $client->{cn}, state => 'idle' } }]);
                }
                
                # open file for writing, change read callback to get raw data instead of json
                #  - arch       => architecture built
                #  - type       => 'pkg' or 'log'
                #  - filename   => filename to be uploaded
                case "open" {
                    print "   -> $client->{cn} ($data->{arch}: opening $data->{type} file $data->{filename}\n";
                    my $file;
                    if ($data->{type} eq "pkg") {
                        open $file, ">$self->{in_pkg}/$data->{arch}/$data->{filename}";
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
                #  - arch       => architecture built
                #  - pkgbase    => top level package name
                case "prep" {
                    print "   -> preparing package: $client->{cn} ($data->{arch}) $data->{pkgbase}\n";
                    $q_db->enqueue(['svc', 'prep', $data->{arch}, $client->{cn}, $data]);
                }
                
                # release build from client
                #  - arch       => architecture built
                #  - pkgbase    => top level package name
                case "release" {
                    print "   -> releasing package: $client->{cn} ($data->{arch}) $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc', 'print', "[released] $client->{cn} ($data->{arch}) $data->{pkgbase}"]);
                    $q_db->enqueue(['svc', 'release', $data->{arch}, $client->{cn}, $data]);
                    $handle->push_write(json => $data); # ACK via original hash
                    $client->{state} = 'idle';
                    undef $client->{pkgbase};
                    undef $client->{arch};
                    
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'package', package => { state => 'release', arch => $data->{arch}, package => $data->{pkgbase} } }]);
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $client->{cn}, state => 'idle' } }]);
                }
                
                # synchronize client state
                case "sync" {
                    print "   -> synchronizing $client->{ou}/$client->{cn} to $data->{state} - primary: $data->{primary}, available: " . join(', ', ref($data->{available}) eq 'ARRAY' ? @{$data->{available}} : $data->{available}) . "\n";
                    $client->{state} = $data->{state};
                    if ($data->{state} eq 'building') {
                        $client->{pkgbase} = $data->{pkgbase};
                        $client->{arch} = $data->{arch};
                        $self->{$data->{arch}} = 'start';
                        $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $client->{cn}, arch => $client->{arch}, state => 'building', package => $data->{pkgbase} } }]);
                    } else {
                        $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $client->{cn}, state => 'idle' } }]);
                    }
                    $client->{primary} = $data->{primary};
                    $client->{available} = $data->{available};
                    $client->{highmem} = $data->{highmem} || 0;
                }
            }
        }
        
        # farmer client
        case "farmer" {
            switch ($data->{command}) {
                # sync farmer - rsync push
                #  - address    => address to push to
                case "sync" {
                    $q_mir->enqueue(['svc', 'push', $data->{address}, $client->{cn}]);
                    $client->{ready} = 0;
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
                        next if (!($oucn =~ m/builder\/.*/));
                        my $builder = $self->{clients}->{$self->{clientsref}->{$oucn}};
                        if ($builder->{state} eq 'idle') {
                            $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $builder->{cn}, state => 'idle' } }]);
                        } else {
                            $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $builder->{cn}, arch => $builder->{arch}, state => 'building', package => $builder->{pkgbase} } }]);
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

# read GitHub POST request
sub gh_read {
    my ($self, $h, $data) = @_;
    if ($data =~ /Content-Length: (.*)\015?\012/) {
        $h->push_read(chunk => $1 - 8,
            sub {
                my ($h, $data) = @_;
                
                $data =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
                my $json = decode_json $data;
                foreach my $commit (@{$json->{commits}}) {
                    $q_irc->enqueue(['svc', 'print', "[$json->{repository}->{name}] <$commit->{author}->{name}> $commit->{message}", 1]);
                }
                $h->destroy;
            });
    } else {
        $h->destroy;
    }
}

# callback for the queue timer
sub cb_queue {
    my ($self, $con) = @_;
    my $msg = $q_svc->dequeue_nb();
    if ($msg) {
        my ($from, $order) = @{$msg};
        print "SVC[$from $order]\n";
        $order =~ s/\!// if ($from eq 'irc');
        switch($order) {
            ## database orders
            # ACK json back to build client
            case "ack" {
                my ($arch, $cn, $data) = @{$msg}[2,3,4];
                my $handle = $self->{clientsref}->{"builder/$cn"};
                
                $handle->push_write(json => $data) if defined $handle;
            }
            
            # populate our architectures list, set status
            case "arches" {
                undef $self->{arch};
                foreach my $arch (split(/ /, @{$msg}[2])) {
                    $self->{arch}->{$arch} = $arch;
                    $self->{$arch} = 'stop' unless defined $self->{$arch};
                }
                print "SVC: now serving architectures: " . join(' ', sort keys %{$self->{arch}}) . "\n";
            }
            
            # repo command for farmer
            #  - command    - add/insert/remove/delete/move
            #  - architecture
            #  - repo
            #  - arg        - pkgname/filename
            case "farm" {
                my ($command, $arch, $repo, $arg) = @{$msg}[2,3,4,5];
                foreach my $oucn (keys %{$self->{clientsref}}) {
                    next if (!($oucn =~ m/farmer\/.*/));
                    my $farmer = $self->{clients}->{$self->{clientsref}->{"$oucn"}};
                    next unless $farmer->{ready};
                    $farmer->{handle}->push_write(json => { command => $command, 
                                                            arch    => $arch,
                                                            repo    => $repo,
                                                            arg     => $arg });
                }
            }
            
            # force package to build on an idle builder
            case "force" {
                my ($data) = @{$msg}[2];
                foreach my $oucn (keys %{$self->{clientsref}}) {
                    next if (!($oucn =~ m/builder\/.*/));
                    my $builder = $self->{clients}->{$self->{clientsref}->{"$oucn"}};
                    next unless $builder->{state} eq 'idle';
                    if (grep {$_ eq $data->{arch}} @{$builder->{available}}) {
                        $q_irc->enqueue(['svc','print',"[force] builder: $builder->{cn} ($data->{arch}) - package: $data->{pkgbase}"]);
                        print "   -> next for $builder->{cn} ($data->{arch}): $data->{pkgbase}\n";
                        $builder->{handle}->push_write(json => $data);
                        $builder->{state} = 'building';
                        $builder->{pkgbase} = $data->{pkgbase};
                        $builder->{arch} = $data->{arch};
                        return;
                    }
                }
                $q_irc->enqueue(['svc','print',"[force] no idle builder available for $data->{pkgbase}"]);
            }
            # push json out to admin interface
            case "admin" {
                my ($data) = @{$msg}[2];
                my $handle = $self->{clientsref}->{"admin/nodejs"};
                
                if (defined $handle) {
                    $handle->push_write(json => $data);
                    $handle->push_write("\000");
                }
            }
            
            # next package response
            case "next" {
                my ($arch, $cn, $data) = @{$msg}[2,3,4];
                my $handle = $self->{clientsref}->{"builder/$cn"};
                my $builder = $self->{clients}->{$handle};
                
                if ($data->{pkgbase} ne "FAIL") {
                    $q_irc->enqueue(['svc','print',"[new] builder: $cn ($arch) - package: $data->{pkgbase}"]);
                    print "   -> next for $cn ($arch): $data->{pkgbase}\n";
                    $handle->push_write(json => $data);
                    $builder->{state} = 'building';
                    $builder->{pkgbase} = $data->{pkgbase};
                    $builder->{arch} = $arch;
                    
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $cn, arch => $arch, state => 'building', package => $data->{pkgbase} } }]);
                } else {
                    $builder->{state} = 'idle';
                    undef $builder->{pkgbase};
                    undef $builder->{arch};
                    $self->check_complete($arch) if ($self->{$arch} eq 'start');                    # check if all builders are done on this arch
                    if ($builder->{primary} ne $arch && $self->{$builder->{primary}} eq 'start') {  # check if builder's primary is still active
                        $self->push_builder('start', $builder->{primary});                          #  ..and push for a new package
                    } else {                                                                        # otherwise check if an available arch is active
                        my $found = ($builder->{primary} eq $arch) ? 1 : 0;
                        foreach my $test_arch (@{$builder->{available}}) {
                            next if ($test_arch eq $builder->{primary});                            # ignore primary arch, we've tested it if we got here
                            next if ($test_arch ne $arch && !$found);                               # skip arches until we reach the current arch in available list
                            if ($test_arch eq $arch)  {                                             # found last tested arch, skip to next
                                $found = 1;
                                next;
                            }
                            if ($self->{$test_arch} eq 'start') {                                   # push for next arch if it's started
                                $self->push_builder('start', $test_arch);
                                last;
                            }
                        }
                    }
                }
            }
            
            ## IRC orders
            # list connected clients
            case "list" {
                $q_irc->enqueue(['svc', 'print', "[list] Connected clients:"]);
                foreach my $oucn (keys %{$self->{clientsref}}) {
                    next if (!($oucn =~ m/builder\/.*/));
                    my $builder = $self->{clients}->{$self->{clientsref}->{$oucn}};
                    my @arches;
                    foreach my $arch (sort keys %{$self->{arch}}) {
                        if ($arch eq $builder->{primary}) {
                            push @arches, "\0033$arch\003";
                        } elsif (grep {$_ eq $arch} @{$builder->{available}}) {
                            push @arches, "$arch";
                        } else {
                            push @arches, "\0034$arch\003";
                        }
                    }
                    my $info = $builder->{pkgbase} ? "$builder->{arch}/$builder->{pkgbase} " : '';
                    $info .= $builder->{highmem} ? "[highmem]" : '';
                    $q_irc->enqueue(['svc', 'print', "[list]  - [" . join(' ', @arches) . "] $builder->{cn}: $builder->{state} $info"]);
                }
            }
            
            # start or stop building
            case ["start","stop"] {
                my $what = @{$msg}[2];
                if (defined $self->{"armv$what"}) {
                    $self->{"armv$what"} = $order;
                    $self->push_builder($order, "armv$what");
                } elsif ($what eq 'all') {
                    foreach my $arch (sort keys %{$self->{arch}}) {
                        $self->{$arch} = $order;
                    }
                    $self->push_builder($order);
                }
            }
            
            # tell builder(s) to run idle maintenance now
            case "maint" {
                my $cn = @{$msg}[2];
                
                if ($cn) {
                    if (my $handle = $self->{clientsref}->{"builder/$cn"}) {
                        $handle->push_write(json => {command => 'maint'});
                        $q_irc->enqueue(['svc', 'print', "[maint] Requested maintenance run on $cn."]);
                    } else {
                        $q_irc->enqueue(['svc', 'print', "[maint] No builder named $cn."]);
                    }
                } else {
                    foreach my $oucn (keys %{$self->{clientsref}}) {
                        next if (!($oucn =~ m/builder\/.*/));
                        my $handle = $self->{clientsref}->{$oucn};
                        $handle->push_write(json => {command => 'maint'});
                    }
                    $q_irc->enqueue(['svc', 'print', "[maint] Requested maintenance run on all builders."]);
                }
            }
            ## Mirror orders
            # rsync push to farmer complete, set ready
            case "sync" {
                my ($cn) = @{$msg}[2];
                my $handle = $self->{clientsref}->{"farmer/$cn"};
                my $farmer = $self->{clients}->{$handle};
                
                $farmer->{ready} = 1;
                $handle->push_write(json => {command => 'sync'});
            }
        }
        if ($order eq 'quit' || $order eq 'recycle'){
            $self->{condvar}->broadcast;
            return;
        }
    }
}

# push next packages/stop to builders
sub push_builder {
    my ($self, $action, $arch) = @_;
    my $count = 0;
    
    # create list of builders
    foreach my $oucn (keys %{$self->{clientsref}}) {
        next if (!($oucn =~ m/builder\/.*/));
        my $builder = $self->{clients}->{$self->{clientsref}->{"$oucn"}};
        
        my $use_arch = $builder->{primary};     # set to use builder's primary arch
        if (defined $arch) {                    # though if we're starting only a specific arch..
            if (grep {$_ eq $arch} @{$builder->{available}}) {
                $use_arch = $arch;              # and it's available, so we can use it
            } else {
                next;                           # unless it isn't, so we check the next builder
            }
        }                                       # otherwise, using the primary arch
        
        if ($action eq "start") {
            next if ($builder->{state} ne 'idle');
            $builder->{state} = 'check';
            $builder->{arch} = $use_arch;
            $q_db->enqueue(['svc', 'next', $use_arch, $builder->{cn}, $builder->{highmem}]);
            $count++;
        } elsif ($action eq "stop") {
            next if ($builder->{state} eq 'idle');
            next if ($arch && $builder->{arch} ne $arch);
            $builder->{handle}->push_write(json => {command => 'stop'});
            $count++;
        }
    }
    
    if (!$count) {
        $q_irc->enqueue(['svc','print',"[$action] no builders to $action"]);
    }
}

# check if all builders are done for an architecture, trigger mirror sync
sub check_complete {
    my ($self, $arch) = @_;
    my $total = 0;
    my $count = 0;
    
    # get list of builders for specified arch
    foreach my $oucn (keys %{$self->{clientsref}}) {
        next if (!($oucn =~ m/builder\/.*/));
        my $builder = $self->{clients}->{$self->{clientsref}->{"$oucn"}};
        
        # determine if all builders are idle or if they're building a different arch
        $total++;
        $count++ if ($builder->{state} eq 'idle' || ($builder->{state} ne 'idle' && $builder->{arch} ne $arch));
    }
    if ($total && $count == $total) {
        $q_irc->enqueue(['svc','print',"[complete] found no package to issue for $arch, mirroring"]);
        $q_mir->enqueue(['svc', 'update', $arch]);
        $self->{$arch} = 'stop';
    }
}

1;
