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
use WWW::Shorten::TinyURL;

our $available = Thread::Semaphore->new(1);

our ($q_svc, $q_db, $q_irc, $q_mir, $q_stats);

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
    $self->{poll_count} = 1;
    $self->{mirroring} = 1;
    
    if ($available->down_nb()) {
        # start TCP servers
        my $service = tcp_server undef, $self->{port}, sub { $self->_cb_accept(@_, 0); };
        my $nodesvc = tcp_server "127.0.0.1", $self->{port}+1, sub { $self->_node_accept(@_, 0); };
        my $github = tcp_server undef, $self->{port}+2, sub { $self->_gh_accept(@_); };
        
        # thread queue check timer
        my $timer = AnyEvent->timer(interval => .5, cb => sub { $self->_cb_queue(@_); });
        
        # initial poll, all sources, after 60 seconds
        my $poll_init = AnyEvent->timer(after => 60, cb => sub { $q_db->enqueue(['svc', 'poll']); });
        # poll git sources every 5 minutes, starting after 360 seconds (5 minutes later), triggered by _gh_read()
        my $poll_git = AnyEvent->timer(after => 360, interval => 300, cb => sub { if ($self->{poll_count}) { --$self->{poll_count}; $q_db->enqueue(['svc', 'poll', 'git']); } });
        # poll abs sources every 30 minutes, starting after 1860 seconds (30 minutes later)
        my $poll_abs = AnyEvent->timer(after => 1860, interval => 1800, cb => sub { $q_db->enqueue(['svc', 'poll', 'abs']); });
        
        # get number of packages ready to be built
        $q_db->enqueue(['svc', 'ready_list']);
        
        # enter event loop
        $self->{condvar}->wait;
        
        # shutdown
        undef $timer;
        undef $poll_abs;
        $service->cancel;
        while (my ($key, $value) = each %clients) {
            $value->{handle}->destroy;
        }
        $available->up();
    }
    
    print "SvcRunEnd\n";
    return 0;
}

# callback for the queue timer
sub _cb_queue {
    my ($self) = @_;
    
    # dequeue next message
    my $msg = $q_svc->dequeue_nb();
    return unless $msg;
    
    my ($from, $order) = @{$msg};
    $order =~ s/\!// if ($from eq 'irc');
    print "Service: got $order from $from\n";
    
    # run named method with provided args
    if ($self->can($order)) {
        $self->$order(@{$msg}[2..$#{$msg}]);
    } else {
        print "Service: no method: $order\n";
    }
}

################################################################################
# Orders

# ACK json back to build client
# sender: Database
sub ack {
    my ($self, $arch, $cn, $data) = @_;
    my $handle = $self->{clientsref}->{"builder/$cn"};
                
    $handle->push_write(json => $data) if defined $handle;
}

# push json out to admin interface
# sender: Database
sub admin {
    my ($self, $data) = @_;
    my $handle = $self->{clientsref}->{"admin/nodejs"};
    
    if (defined $handle) {
        $handle->push_write(json => $data);
        $handle->push_write("\000");
    }
}

# populate our architectures list, set stop status
# sender: Database
sub arches {
    my ($self, $list) = @_;
    undef $self->{arch};
    foreach my $arch (split(/ /, $list)) {
        $self->{arch}->{$arch} = $arch;
        $self->{$arch} = 'stop' unless defined $self->{$arch};
    }
    print "SVC: now serving architectures: " . join(' ', sort keys %{$self->{arch}}) . "\n";
}

# repo command for farmer
#  - command    - add/insert/remove/delete/move/power
#  - arg        - pkgname/filename
# sender: Datbase
sub farm {
    my ($self, $command, $arch, $repo, $arg) = @_;
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
# sender: Database
sub force {
    my ($self, $data) = @_;
    foreach my $oucn (keys %{$self->{clientsref}}) {
        next if (!($oucn =~ m/builder\/.*/));
        my $builder = $self->{clients}->{$self->{clientsref}->{"$oucn"}};
        next unless $builder->{state} eq 'idle';
        if (grep {$_ eq $data->{arch}} @{$builder->{available}}) {
            $q_irc->enqueue(['svc', 'privmsg', "[force] builder: $builder->{cn} ($data->{arch}) - package: $data->{pkgbase}"]);
            print "   -> next for $builder->{cn} ($data->{arch}): $data->{pkgbase}\n";
            $builder->{handle}->push_write(json => $data);
            $builder->{state} = 'building';
            $builder->{pkgbase} = $data->{pkgbase};
            $builder->{arch} = $data->{arch};
            return;
        }
    }
    $q_irc->enqueue(['svc', 'privmsg', "[force] no idle builder available for $data->{pkgbase}"]);
}

# list connected clients
# sender: IRC
sub list {
    my ($self) = @_;
    $q_irc->enqueue(['svc', 'privmsg', "[list] Connected clients:"]);
    foreach my $oucn (sort keys %{$self->{clientsref}}) {
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
        $q_irc->enqueue(['svc', 'privmsg', "[list]  - [" . join(' ', @arches) . "] $builder->{cn}: $builder->{state} $info"]);
    }
}

# tell builder(s) to run idle maintenance now
# sender: IRC
sub maint {
    my ($self, $cn) = @_;
    
    if ($cn) {
        if (my $handle = $self->{clientsref}->{"builder/$cn"}) {
            $handle->push_write(json => {command => 'maint'});
            $q_irc->enqueue(['svc', 'privmsg', "[maint] Requested maintenance run on $cn."]);
        } else {
            $q_irc->enqueue(['svc', 'privmsg', "[maint] No builder named $cn."]);
        }
    } else {
        foreach my $oucn (keys %{$self->{clientsref}}) {
            next if (!($oucn =~ m/builder\/.*/));
            my $handle = $self->{clientsref}->{$oucn};
            $handle->push_write(json => {command => 'maint'});
        }
        $q_irc->enqueue(['svc', 'privmsg', "[maint] Requested maintenance run on all builders."]);
    }
}

# enable/disable mirroring after building for an architecture is finished
# sender: IRC
sub mirroring {
    my ($self, $status) = @_;
    
    if ($status) {
        if ($status eq 'on') {
            $self->{mirroring} = 1;
        } elsif ($status eq 'off') {
            $self->{mirroring} = 0;
        } else {
            $q_irc->enqueue(['svc', 'privmsg', "[mirroring] usage: !mirroring [on|off]"]);
        }
    }
    $q_irc->enqueue(['svc', 'privmsg', sprintf("[miroring] Mirroring is %s", $self->{mirroring} ? "on" : "off")]);
}

# next package response
# sender: Database
sub next_pkg {
    my ($self, $arch, $cn, $data) = @_;
    my $handle = $self->{clientsref}->{"builder/$cn"};
    my $builder = $self->{clients}->{$handle};
    
    if ($data->{pkgbase} ne "FAIL") {
        $q_irc->enqueue(['svc', 'privmsg', "[new] builder: $cn ($arch) - package: $data->{pkgbase}"]);
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
        print "SVC: next_pkg: something bad happened, got FAIL for $cn\n";
    }
}

# push a start on enabled arches
# sender: Database
sub push_build {
    my ($self) = @_;
    
    # push to available builders
    foreach my $oucn (keys %{$self->{clientsref}}) {
        next if (!($oucn =~ m/builder\/.*/));
        my $builder = $self->{clients}->{$self->{clientsref}->{"$oucn"}};
        next if ($builder->{state} ne 'idle');
        
        # get a package to build in order of listed available architectures for the builder
        foreach my $arch (@{$builder->{available}}) {
            # skip stopped architecture
            next if ($self->{$arch} ne 'start');
            # calculate available packages based on highmem
            my $total = $builder->{highmem} ? $self->{ready}->{$arch}->{total} : $self->{ready}->{$arch}->{total} - $self->{ready}->{$arch}->{highmem};
            # skip arch if no packages are available
            next if ($total == 0);
            
            # get next package
            $builder->{state} = 'check';
            $builder->{arch} = $arch;
            $q_db->enqueue(['svc', 'next_pkg', $arch, $builder->{cn}, $builder->{highmem}]);
            $self->{ready}->{$arch}->{total}--;
            $self->{ready}->{$arch}->{highmem}-- if $builder->{highmem} && $self->{ready}->{$arch}->{highmem} > 0;
            last;
        }
    }
}

# quit service thread
# sender: Server
sub quit {
    my ($self) = @_;
    
    $self->{condvar}->broadcast;
    return;
}

# store information on number of packages ready to build for each architecture
# sender: Database
sub ready {
    my ($self, $info) = @_;
    
    $self->{ready} = $info;
    
    # check if builders are done if total is 0 and arch is started
    foreach my $arch (keys %{$self->{arch}}) {
        next unless $self->{ready}->{$arch}->{total} == 0;
        $self->_check_complete($arch) if ($self->{$arch} eq 'start');
    }
    
    # start any available builders based on the new information
    $self->push_build();
}

# mark an architecture as available to build
# sender: Database, Internal
sub start {
    my ($self, $arch) = @_;
    
    # no such architecture
    if (!$self->{$arch}) {
        $q_irc->enqueue(['svc', 'privmsg', "[start] No such architecture $arch"]);    
        
    # start when held for mirroring, switch to hold-start
    } elsif ($self->{$arch} eq 'hold-start' || $self->{$arch} eq 'hold-stop') {
        $q_irc->enqueue(['svc', 'privmsg', "[start] Holding $arch, will start when hold is released"]);
        $self->{$arch} = 'hold-start';
        
    # start but no packages available for that architecture
    } elsif ($self->{ready}->{$arch}->{total} && $self->{ready}->{$arch}->{total} == 0) {
        $q_irc->enqueue(['svc', 'privmsg', "[start] No packages available for $arch, not starting"]);
        
    # architecture already started
    } elsif ($self->{$arch} eq 'start') {
        $q_irc->enqueue(['svc', 'privmsg', "[start] $arch is already started"]);
        
    # otherwise, start the architecture
    } else {
        $q_irc->enqueue(['svc', 'privmsg', "[start] Starting $arch"]);
        $self->{$arch} = 'start';
    }
}

# print out status of architectures
# sender: IRC
sub status {
    my ($self) = @_;
    foreach my $arch (sort keys %{$self->{arch}}) {
        $q_irc->enqueue(['svc', 'privmsg', "[status] $arch: " . $self->{$arch}]);
    }
}

# mark an architecture as not available to build
# sender: Database, Internal
sub stop {
    my ($self, $arch) = @_;
    
    if ($arch eq 'all') {
        foreach my $a (keys %{$self->{arch}}) {
            next if ($self->{$a} eq 'stop');
            if ($self->{$a} eq 'hold-start' || $self->{$a} eq 'hold-stop') {
                $self->{$a} = 'hold-stop';
                print "[stop] Holding $arch, will stop when hold is released\n";
            } else {
                $self->{$a} = 'stop';
                print "[stop] Stopping $arch\n";
            }
        }
        return;
    }
    
    # no such architecture
    if (!$self->{$arch}) {
        $q_irc->enqueue(['svc', 'privmsg', "[stop] No such architecture $arch"]);
        
    # stop when held for mirroring, switch to hold-stop
    } elsif ($self->{$arch} eq 'hold-start' || $self->{$arch} eq 'hold-stop') {
        $q_irc->enqueue(['svc', 'privmsg', "[stop] Holding $arch, will stop when hold is released"]);
        $self->{$arch} = 'hold-stop';
        
    # architecture already stopped
    } elsif ($self->{$arch} eq 'stop') {
        $q_irc->enqueue(['svc', 'privmsg', "[stop] $arch is already stopped"]);
        
    # otherwise, stop the architecture
    } else {
        $q_irc->enqueue(['svc', 'privmsg', "[stop] Stopping $arch"]);
        $self->{$arch} = 'stop';
    }
    
}

# rsync push to farmer complete, set farmer ready
# sender: Mirror
sub sync {
    my ($self, $cn) = @_;
    my $handle = $self->{clientsref}->{"farmer/$cn"};
    my $farmer = $self->{clients}->{$handle};
    
    $farmer->{ready} = 1;
    $handle->push_write(json => {command => 'sync'});
}

# remove hold on architecture, start or stop depending on status
# sender: Mirror
sub unhold {
    my ($self, $arch) = @_;
    
    if ($self->{$arch} eq 'hold-stop') {
        $q_irc->enqueue(['svc', 'privmsg', "[unhold] Stopping $arch"]);
        $self->{$arch} = 'stop';
    } elsif ($self->{$arch} eq 'hold-start') {
        if ($self->{ready}->{$arch}->{total} && $self->{ready}->{$arch}->{total} == 0) {
            $q_irc->enqueue(['svc', 'privmsg', "[unhold] No packages available for $arch, stopping"]);
            $self->{$arch} = 'stop';
        } else {
            $q_irc->enqueue(['svc', 'privmsg', "[unhold] Starting $arch"]);
            $self->{$arch} = 'start';
            $self->push_build();
        }
    }
}

################################################################################
# Internal

# callback for accepting a new connection
sub _cb_accept {
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
                                            verify_cb                   => sub { $self->_cb_verify_cb(@_); }
                                            },
                            keepalive   => 1,
                            no_delay    => 1,
                            rtimeout    => 3, # 3 seconds to authenticate with SSL before destruction
                            rbuf_max    => 0, # disable reading until SSL auth (DDoS prevention)
                            on_rtimeout => sub { $h->destroy; },
                            on_error    => sub { $self->_cb_error(@_); },
                            on_starttls => sub { $self->_cb_starttls(@_); }
                            ;
    
    print "[SVC] new client connection from $address\n";
    $self->{clients}->{$h} = $h;
}

# callback on socket error
sub _cb_error {
    my ($self, $handle, $fatal, $message) = @_;
    
    if ($fatal) {
        print "fatal ";
        if (defined $self->{clients}->{$handle}->{cn}) {    # delete our OU/CN reference if it exists
            $q_irc->enqueue(['svc', 'privmsg', "[SVC] $self->{clients}->{$handle}->{ou}/$self->{clients}->{$handle}->{cn} disconnected: $message"]);
            if ($self->{clients}->{$handle}->{ou} eq "builder") {
                $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $self->{clients}->{$handle}->{cn}, state => 'disconnect' } }]);
            }
            if (defined $self->{clients}->{$handle}->{file}) {      # close out file if it's open
                close $self->{clients}->{$handle}->{file};
            }
            if ($self->{clients}->{$handle}->{ou} eq "builder" && $self->{clients}->{$handle}->{state} eq "building") {
                print "   -> releasing package: $self->{clients}->{$handle}->{cn} ($self->{clients}->{$handle}->{arch}) $self->{clients}->{$handle}->{pkgbase}\n";
                $q_irc->enqueue(['svc', 'privmsg', "[released] $self->{clients}->{$handle}->{cn} ($self->{clients}->{$handle}->{arch}) $self->{clients}->{$handle}->{pkgbase}"]);
                $q_db->enqueue(['svc', 'pkg_release', $self->{clients}->{$handle}->{arch}, $self->{clients}->{$handle}->{cn}, { arch => $self->{clients}->{$handle}->{arch}, pkgbase => $self->{clients}->{$handle}->{pkgbase} }]);
            }
            delete $self->{clientsref}->{"$self->{clients}->{$handle}->{ou}/$self->{clients}->{$handle}->{cn}"};
        }
        delete $self->{clients}->{$handle};
    }
    print "error from $handle->{peername} - $message\n";
}

# callback for reading json data
sub _cb_read {
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
                    $q_db->enqueue(['svc', 'pkg_add', $data->{arch}, $client->{cn}, $data]);
                }
                
                # build for top-level package is complete
                #  - arch       => architecture built
                #  - pkgbase    => top level package name
                case "done" {
                    print "   -> package done: $client->{cn} ($data->{arch}) $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc', 'privmsg', "[\0033done\003] $client->{cn} ($data->{arch}) $data->{pkgbase}"]);
                    $q_db->enqueue(['svc', 'pkg_done', $data->{arch}, $data->{pkgbase}]);
                    $handle->push_write(json => $data); # ACK via original hash
                    if ($client->{state} ne 'manual') {
                        $client->{state} = 'idle';
                        undef $client->{pkgbase};
                        undef $client->{arch};
                    }
                    
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'package', package => { state => 'done', arch => $data->{arch}, package => $data->{pkgbase} } }]);
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $client->{cn}, state => 'idle' } }]);
                }
                
                # build failed for package
                #  - arch       => architecture built
                #  - pkgbase    => top level package name
                case "fail" {
                    print "   -> package fail: $client->{cn} ($data->{arch}) $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc', 'privmsg', "[\0034fail\003] $client->{cn} ($data->{arch}) $data->{pkgbase}"]);
                    $q_db->enqueue(['svc', 'pkg_fail', $data->{arch}, $data->{pkgbase}]);
                    $handle->push_write(json => $data); # ACK via original hash
                    undef $client->{pkgbase};
                    undef $client->{arch};
                    $client->{state} = 'idle';
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
                    $handle->on_read(sub { $self->_cb_readfile(@_); });
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
                    $q_db->enqueue(['svc', 'pkg_prep', $data->{arch}, $data, $client->{cn}]);
                }
                
                # release build from client
                #  - arch       => architecture built
                #  - pkgbase    => top level package name
                case "release" {
                    print "   -> releasing package: $client->{cn} ($data->{arch}) $data->{pkgbase}\n";
                    $q_irc->enqueue(['svc', 'privmsg', "[released] $client->{cn} ($data->{arch}) $data->{pkgbase}"]);
                    $q_db->enqueue(['svc', 'pkg_release', $data->{arch}, $client->{cn}, $data]);
                    $handle->push_write(json => $data); # ACK via original hash
                    $client->{state} = 'idle';
                    undef $client->{pkgbase};
                    undef $client->{arch};
                    
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'package', package => { state => 'release', arch => $data->{arch}, package => $data->{pkgbase} } }]);
                    $q_svc->enqueue(['svc', 'admin', { command => 'update', type => 'builder', builder => { name => $client->{cn}, state => 'idle' } }]);
                }
                
                # system statistics packet
                #  - ts         => timestamp
                #  - type       => type of data
                #  - value      => data value
                case "stats" {
                    my $pkg = '';
                    my $arch = '';
                    if ($client->{state} eq 'building') {
                        $pkg = $client->{pkgbase};
                        $arch = $client->{arch};
                    }
                    $q_stats->enqueue(['svc', 'log_stat', $client->{cn}, $data->{ts}, $data->{data}, $pkg, $arch]);
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
                # power command ACK
                #  - data       => message to print to IRC
                case "power" {
                    $q_irc->enqueue(['svc', 'privmsg', $data->{data}]);
                }
                
                # sync farmer - rsync push
                #  - address    => address to push to
                case "sync" {
                    $q_mir->enqueue(['svc', 'sync', $data->{address}, $client->{cn}]);
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
sub _cb_readfile {
    my ($self, $handle) = @_;
    
    $handle->unshift_read(chunk => 4, sub {             # data stream chunks are prefixed by a 4-byte N pack'd length
        my ($handle, $data) = @_;
        my $len = unpack "N", $data;
        if ($len == 0) {                                # zero length = end of stream, switch back to json parsing
            close $self->{clients}->{$handle}->{file};
            undef $self->{clients}->{$handle}->{file};
            $handle->on_read(sub { $handle->push_read(json => sub { $self->_cb_read(@_); }) });
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

# callback on whether ssl auth succeeded
sub _cb_starttls {
    my ($self, $handle, $success, $error) = @_;
    
    if ($success) {
        $handle->rtimeout(300);     # stop auto-destruct, reset for 5 minute ping timeout
        $handle->on_rtimeout(sub { my $h = shift; $self->_cb_error($h, 1, 'read timeout'); $h->destroy; });
        undef $handle->{rbuf_max};  # enable read buffer
        $handle->on_read(sub { $handle->push_read(json => sub { $self->_cb_read(@_); }) });  # set read callback
        return;
    }
    
    # kill the connection, bad ssl auth
    $handle->destroy;
}

# callback that handles peer certificate verification
sub _cb_verify_cb {
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
                    $self->_cb_error($oldhandle, 1, 'duplicate client disconnect');
                    $oldhandle->destroy;
                }
                $q_irc->enqueue(['svc', 'privmsg', "[SVC] verified ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert))]);
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
    
    $q_irc->enqueue(['svc', 'privmsg', "[SVC] failed verification for $ref->{peername}: ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert))]);
    return 0;
}

# check if all builders are done for an architecture, trigger mirror sync
sub _check_complete {
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
        $q_irc->enqueue(['svc', 'privmsg', "[complete] found no package to issue for $arch, mirroring"]);
        $q_mir->enqueue(['svc', 'queue', $arch]) if ($self->{mirroring});
        $self->{$arch} = 'hold-stop';
    }
}

# callback for accepting GitHub WebHook connection
sub _gh_accept {
    my ($self, $fh, $address) = @_;
    return unless $fh;
    
    # only accept connections from defined GitHub public service IPs
    if ($self->_gh_check($address)) {
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
                            on_read     => sub { $h->push_read(regex => qr<\015\012\015\012payload=>, undef, qr<^.*[^\015\012]>, sub { $self->_gh_read(@_); })}
                            ;
    print "[SVC] Accepted GitHub connection from $address\n";
};

# validate GitHub WebHook connecting IP address against given list
sub _gh_check {
    my ($self, $address) = @_;
    
    my @allowed = ("207.97.227.253/32", "50.57.128.197/32", "108.171.174.178/32", "50.57.231.61/32", "204.232.175.64/27", "192.30.252.0/22");
    foreach my $cidr (@allowed) {
        my ($host, $net) = split(/\//, $cidr);
        return 0 if !((unpack('N', pack('C4', (split '\.', $address))) & ((2**$net)-1)<<(32-$net)) ^ (unpack('N', pack('C4', (split '\.', $host))) & ((2**$net)-1)<<(32-$net)));
    }
    return 1;
}

# read GitHub POST request
sub _gh_read {
    my ($self, $h, $data) = @_;
    if ($data =~ /Content-Length: (.*)\015?\012/) {
        $h->push_read(chunk => $1 - 8,
            sub {
                my ($h, $data) = @_;
                
                $data =~ s/\+/\%20/g;
                $data =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
                my $json = decode_json $data;
                foreach my $commit (@{$json->{commits}}) {
                    $q_irc->enqueue(['svc', 'pubmsg', "[$json->{repository}->{name}] <" . makeashorterlink($commit->{url}) . "> $commit->{author}->{name}: $commit->{message} "]);
                    $self->{poll_count} = 2 if ($json->{repository}->{name} eq "PKGBUILDs");
                }
                $h->destroy;
            });
    } else {
        $h->destroy;
    }
}

# callback for accepting internal nodejs connection (only one allowed)
sub _node_accept {
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
                            on_error    => sub { $self->_cb_error(@_); },
                            on_read     => sub { $h->push_read(json => sub { $self->_cb_read(@_); }) }
                            ;
    
    $q_irc->enqueue(['svc', 'privmsg', "[SVC] NodeJS accepted on $address"]);
    my %client = ( handle   => $h,              # connection handle - must be preserved
                   ip       => $address,        # dotted quad ip address
                   ou       => "admin",         # OU = admin
                   cn       => "nodejs" );      # CN = nodejs
    $self->{clients}->{$h} = \%client;
    $self->{clientsref}->{"admin/nodejs"} = $h;
}

1;
