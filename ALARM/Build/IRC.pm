#!/usr/bin/perl -w
#
# PlugBuild IRC Interface
#

use strict;

package ALARM::Build::IRC;
use AnyEvent;
use AnyEvent::IRC::Client;
use Thread::Queue;
use Thread::Semaphore;
use Switch;

our $available = Thread::Semaphore->new(1);
our ($q_svc, $q_db, $q_irc, $q_mir, $q_stats);

sub new {
    my ($class, $config) = @_;
    my $self = $config;
    
    bless $self, $class;
    return $self;
}

sub Run {
    my $self = shift;
    
    return if (! $available->down_nb());
    print "Irc Run\n";
	
    # set up irc client
    $self->{condvar} = AnyEvent->condvar;
    my $con = new AnyEvent::IRC::Client;
    $self->{con} = $con;
    
    # enable ssl connection (config option)
    $con->enable_ssl() if ($self->{ssl});
    
    # register event callbacks
    $con->reg_cb(connect	=> sub { $self->_cb_connect(@_); });
    $con->reg_cb(disconnect	=> sub { $self->_cb_disconnect(@_); });
    $con->reg_cb(registered	=> sub { $self->_cb_registered(@_); });
    $con->reg_cb(publicmsg	=> sub { $self->_cb_publicmsg(@_); });
    
    # arm thread queue timer
    $self->{timer} = AnyEvent->timer(interval => 1, cb => sub { $self->_cb_queue(); });
    
    # connect, loop
    $self->_connect($con);
    $self->{condvar}->wait;
    
    # termination following a broadcast
    print "Irc End\n";
    return 0;
}

################################################################################
# AnyEvent Callbacks

# callback for thread queue timer
sub _cb_queue {
    my ($self) = @_;
    
    # dequeue next message
    my $msg = $q_irc->dequeue_nb();
    return unless $msg;
    
    my ($from, $order) = @{$msg};
    print "IRC: got $order from $from\n";
    
    # run named method with provided args
    if ($self->can($order)) {
        $self->$order(@{$msg}[2..$#{$msg}]);
    } else {
        print "IRC: no method: $order\n";
    }
}

# callback for socket connection - sleep and reconnect on error
sub _cb_connect {
    my ($self, $con, $error) = @_;
    
    if (defined $error) {
        warn "IRC: connect error: $error\n";
        sleep $self->{delay};
        $self->connect($con);
    }
}

# callback for socket disconnect - sleep and reconnect
sub _cb_disconnect {
    my ($self, $con, $reason) = @_;
	
    warn "IRC: disconnected: $reason\n";
    return if ($reason eq "quit");
	if ($reason eq "recycle") {
		$available->up();
		return;
	}
	
    sleep $self->{delay};
    $self->connect($con);
}

# callback for public (channel) messages
sub _cb_publicmsg {
    my ($self, $con, $chan, $buf) = @_;
    
    my %msg = %{$buf};
    my @params = @{$msg{params}};
    
    # private channel commands
    if ($params[0] && $params[0] eq '#'.$self->{channel} && $params[1] && $params[1] =~ /^\!.*/) {
        my ($trigger, $arg) = split(/ /, $params[1], 2);
        switch ($trigger) {
            case "!arch" {
                $q_svc->enqueue(['irc', 'status']);
            }
            case "!aur" {
                $q_db->enqueue(['irc', 'aur_check']);
            }
            case "!continue" {
                $q_db->enqueue(['irc', 'update_continue']);
            }
            case "!deselect" {
                if ($arg) {
                    my ($arch, $pkg) = split(/ /, $arg, 3);
                    if ($arch && $pkg) {
                        $q_db->enqueue(['irc', 'pkg_select', $arch, $pkg, 0]);
                    }
                }else {
                    $self->privmsg("usage: !select <arch> <package>");
                }
            }
            case "!done" {
                $q_db->enqueue(['irc', 'done', $arg]);
            }
            case "!failed" {
                $q_db->enqueue(['irc', 'failed', $arg]);
            }
            case "!force" {
                if ($arg) {
                    my ($arch, $pkg) = split(/ /, $arg, 3);
                    if ($arch && $pkg) {
                        $q_db->enqueue(['irc', 'force', $arch, $pkg]);
                    }
                } else {
                    $self->privmsg("usage: !force <arch> <package>");
                }
            }
            case "!highmem" {
                my ($pkg) = $arg ? split(/ /, $arg, 2) : undef;
                if (!$pkg) {
                    $self->privmsg("usage: !highmem <package>");
                } else {
                    $q_db->enqueue(['irc', 'pkg_highmem', $pkg]);
                }
            }
            case "!list" {
                $q_svc->enqueue(['irc', 'list']);
            }
            case "!maint" {
                $q_svc->enqueue(['irc', 'maint', $arg || undef ]);
            }
            case "!mirroring" {
                my ($status) = $arg ? split(/ /, $arg, 2) : undef;
                $q_svc->enqueue(['irc', 'mirroring', $status]);
            }
            case "!mirrors" {
                $q_mir->enqueue(['irc', 'list']);
            }
            case "!override" {
                if ($arg) {
                    my ($pkg) = split(/ /, $arg, 2);
                    if (!$pkg) {
                        $q_db->enqueue(['irc', 'pkg_override', $pkg]);
                    }
                } else {
                    $self->privmsg("usage: !override <package>");
                }
            }
            case "!poll" {
                my ($type) = $arg ? split(/ /, $arg, 2) : undef;
                $q_db->enqueue(['irc', 'poll', $type]);
            }
            case "!power" {
                if ($arg) {
                    $q_svc->enqueue(['db', 'farm', 'power', '', '', $arg]);
                } else {
                    $self->privmsg("usage: !power <cycle|on|off> <builder#>");
                }
            }
            case "!prune" {
                if ($arg) {
                    my ($arch, $pkg) = split(/ /, $arg, 3);
                    if ($pkg) {
                        $q_db->enqueue(['irc', 'prune', $arch, $pkg]);
                    } else {
                        $q_db->enqueue(['irc', 'prune', 0, $arch]);
                    }
                } else {
                    $self->privmsg("usage: !prune [arch] <package>");
                }
            }
            case "!push" {
                $q_svc->enqueue(['irc', 'push_build']);
            }
            case "!ready" {
                my ($arch) = $arg ? split(/ /, $arg, 2) : undef;
                if ($arch) {
                    $q_db->enqueue(['irc','ready_detail',$arch]);
                } else {
                    $q_db->enqueue(['irc','ready']);
                }
            }
            case "!refresh" {
                $q_mir->enqueue(['irc', 'geoip_refresh']);
            }
            case "!rehash" {
                $q_db->enqueue(['irc', 'rehash']);
            }
            case "!review" {
                $q_db->enqueue(['irc','review']);
            }
            case "!select" {
                if ($arg) {
                    my ($arch, $pkg) = split(/ /, $arg, 3);
                    if ($arch && $pkg) {
                        $q_db->enqueue(['irc', 'pkg_select', $arch, $pkg, 1]);
                    }
                } else {
                    $self->privmsg("usage: !select <arch> <package>");
                }
            }
            case "!skip" {
                if ($arg) {
                    $q_db->enqueue(['irc', 'pkg_skip', $arg, 0]);
                } else {
                    $self->privmsg("usage: !skip <package>");
                }
            }
            case ["!start", "!stop"] {
                if ($arg && ($arg eq '5' || $arg eq '6' || $arg eq '7')) {
                    $q_svc->enqueue(['irc', substr($trigger, 1), "armv$arg", 1]);
                } elsif ($arg && ($arg eq 'all')) {
                    $q_svc->enqueue(['irc', substr($trigger, 1), "armv5", 1]);
                    $q_svc->enqueue(['irc', substr($trigger, 1), "armv6", 1]);
                    $q_svc->enqueue(['irc', substr($trigger, 1), "armv7", 1]);
                } else {
                    $self->privmsg("usage: $trigger <all|5|6|7>");
                }
            }
            case "!status" {
                my $pkg = (split(/ /, $arg, 2))[0];
                if ($pkg) {
                    $q_db->enqueue(['irc', 'status', $pkg]);
                } else {
                    $self->privmsg("usage: !status <package>");
                }
            }
            case "!sync" {
                if ($arg && ($arg eq '5' || $arg eq '6' || $arg eq '7')) {
                    $q_mir->enqueue(['irc', 'queue', "armv$arg"]);
                    $self->privmsg("[sync] queued armv$arg mirror update");
                } elsif ($arg && $arg eq 'os') {
                    $q_mir->enqueue(['irc', 'queue', 'os']);
                    $self->privmsg("[sync] queued rootfs mirror update");
                } else {
                    $q_mir->enqueue(['irc', 'queue', 'armv5']);
                    $q_mir->enqueue(['irc', 'queue', 'armv6']);
                    $q_mir->enqueue(['irc', 'queue', 'armv7']);
                    $self->privmsg("[sync] queued mirror updates");
                }
            }
            case "!unfail" {
                my ($arch, $pkg) = split(/ /, $arg, 2);
                if ($pkg && $arch) {
                    $q_db->enqueue(['irc', 'pkg_unfail', $arch, $pkg]);
                } else {
                    $self->privmsg("usage: !unfail <arch> <package|all>");
                }
            }
            case "!unskip" {
                if ($arg) {
                    $q_db->enqueue(['irc', 'pkg_skip', $arg, 1]);
                } else {
                    $self->privmsg("usage: !unskip <package>");
                }
            }
            case "!update" {
                $q_db->enqueue(['irc','update']);
            }
        }
    
    # public channel commands
    } elsif ($params[0] && $params[0] eq '#'.$self->{pubchan} && $params[1] && $params[1] =~ /^\!.*/) {
        my ($trigger, $arg) = split(/ /, $params[1], 2);
        switch ($trigger) {
            case "!done" {
                $q_db->enqueue(['irc', 'done_pub']);
            }
            case "!info" {      # package information
                if ($arg) {
                    ($arg) = split(/ /, $arg, 2);
                    $arg = substr($arg, 0, 20); # limit to 20 characters
                    $q_db->enqueue(['irc', 'pkg_info', $arg]);
                }
            }
            case "!search" {    # search packages
                if ($arg) {
                    $arg = substr($arg, 0, 20); # limit to 20 characters
                    $q_db->enqueue(['irc', 'search', $arg]);
                }
            }
        }
    }
}

# callback after registered to server
sub _cb_registered {
    my ($self, $con) = @_;
    $con->send_msg(JOIN => '#'.$self->{channel});
    $con->send_msg(JOIN => '#'.$self->{pubchan});
}

################################################################################
# Orders

# print to private channel
# sender: Any
sub privmsg {
    my ($self, $data) = @_;
    $self->_irc_print($data, 0);
}

# print to public channel
# sender: Any
sub pubmsg {
    my ($self, $data) = @_;
    $self->_irc_print($data, 1);
}

# exit irc thread
# sender: Server
sub quit {
    my ($self) = @_;
    
    undef $self->{timer};
    $self->{con}->disconnect('quit');
    $available->down_force(10);
    $self->{condvar}->broadcast;
}

################################################################################
# Internal

# connect to irc
sub _connect {
    my ($self, $con) = @_;
	$con->connect($self->{server}, $self->{port}, {
		nick => $self->{nick},
		user => $self->{user},
		real => $self->{nick},
		password => "$self->{user} $self->{pass}",
		timeout => 20 });
}

# send a message to irc
sub _irc_print {
    my ($self, $msg, $pub) = @_;
    
    # limit message length to first space after 400 characters
    if (length($msg) > 400) {
        my $todo;
        my $i = index($msg, ' ', 400);
        if ($i == -1 || $i == length($msg) || $i > 450) {
            # no nearby space, just chop it
            $todo = "... " . substr($msg, 400);
            $i = 400;
        } else {
            $todo = "... " . substr($msg, $i + 1);
        }
        # enqueue at beginning so followup prints don't smash us
        $q_irc->insert(0, ['irc', $pub ? 'pubmsg' : 'privmsg', $todo]);
        $msg = substr($msg, 0, $i);
    }
    if ($pub) {
        $self->{con}->send_msg(PRIVMSG => '#'.$self->{pubchan}, "$msg");
    } else {
        $self->{con}->send_msg(PRIVMSG => '#'.$self->{channel}, "$msg");
        $q_svc->enqueue(['irc', 'admin', { command => 'update', type => 'console', console => $msg }]);
    }
}

1;
