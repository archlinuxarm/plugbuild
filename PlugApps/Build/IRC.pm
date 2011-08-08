#!/usr/bin/perl -w
#
# PlugBuild IRC Interface
#

use strict;

package PlugApps::Build::IRC;
use AnyEvent;
use AnyEvent::IRC::Client;
use Thread::Queue;
use Thread::Semaphore;
use Switch;

our $available = Thread::Semaphore->new(1);
our ($q_svc, $q_db, $q_irc);

sub new {
    my ($class, $config) = @_;
    my $self = $config;
    
    bless $self, $class;
    return $self;
}

sub Run {
    my $self = shift;
    print "IrcRun\n";
    
    # set up irc client
    $self->{condvar} = AnyEvent->condvar;
    my $con = new AnyEvent::IRC::Client;
    $self->{con} = $con;
    
    # enable ssl connection (config option)
    $con->enable_ssl() if ($self->{ssl});
    
    # register event callbacks
    $con->reg_cb(connect	=> sub { $self->cb_connect(@_); });
    $con->reg_cb(disconnect	=> sub { $self->cb_disconnect(@_); });
    $con->reg_cb(registered	=> sub { $self->cb_registered(@_); });
    $con->reg_cb(publicmsg	=> sub { $self->cb_publicmsg(@_); });
    
    # arm thread queue timer
    $self->{timer} = AnyEvent->timer(interval => .5, cb => sub { $self->cb_queue(); });
    
    # connect, loop
    $self->connect($con);
    $self->{condvar}->wait;
    
    # termination following a broadcast
    print "IrcRunEnd\n";
    return 0;
}

# connect to irc
sub connect {
    my ($self, $con) = @_;
    if ($available->down_nb()) {
        $con->connect($self->{server}, $self->{port}, {
            nick => $self->{nick},
            user => $self->{nick},
            real => $self->{nick},
            password => "$self->{nick} $self->{pass}",
            timeout => 20 });
        return 1;
    }
    return undef;
}

# send a line to the build channel
sub irc_priv_print {
    my ($self, $msg) = @_;
    
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
        $q_irc->insert(0, ['irc', 'print', $todo]);
        $msg = substr($msg, 0, $i);
    }
    $self->{con}->send_msg(PRIVMSG => '#'.$self->{channel}, "$msg");
}

# callback for socket connection - sleep and reconnect on error
sub cb_connect {
    my ($self, $con, $error) = @_;
    if (defined $error) {
        $available->up();
        warn "IRC: connect error: $error\n";
        sleep 15;
        $self->connect($con);
    }
}

# callback for socket disconnect - sleep and reconnect
sub cb_disconnect {
    my ($self, $con, $reason) = @_;
    warn "IRC: disconnected: $reason\n";
    return if ($reason eq "quit");
    $available->up();
    return if ($reason eq "recycle");
    sleep 15;
    $self->connect($con);
}

# callback after registered to server
sub cb_registered {
    my ($self, $con) = @_;
    $con->send_msg(JOIN => '#'.$self->{channel});
}

# callback for public (channel) messages
sub cb_publicmsg {
    my ($self, $con, $chan, $buf) = @_;
    
    my %msg = %{$buf};
    my $prefix = $msg{prefix} || "";
    my $command = $msg{command} || "";
    my @params = @{$msg{params}};
    
    if ($params[0] && $params[0] eq '#'.$self->{channel} && $params[1] && $params[1] =~ /^\!.*/) {
        my ($trigger, $arg) = split(/ /, $params[1], 2);
        switch ($trigger) {
            case "!continue" {
                $q_db->enqueue(['irc', 'continue']);
            }
            case "!count" {
                if ($arg) {
                    $q_db->enqueue(['irc','count',$arg]);
                } else {
                    $self->irc_priv_print("usage: !count <table>");
                }
            }
            case "!done" {
                $q_db->enqueue(['irc','percent_done',$arg]);
            }
            case "!failed" {
                $q_db->enqueue(['irc','percent_failed',$arg]);
            }
            case "!ready" {
                $q_db->enqueue(['irc','ready',$arg]);
            }
            case "!recycle" {
                if($arg){
                    $q_irc->enqueue(['irc','recycle']) if $arg eq 'irc' || $arg eq 'all';
                    $q_db->enqueue(['irc','recycle']) if $arg eq 'database' || $arg eq 'all';
                    $q_svc->enqueue(['irc','recycle']) if $arg eq 'service' || $arg eq 'all';
                }else{
                    $self->irc_priv_print("usage: !recycle <irc|database|service|all>");
                }
            }
            case "!review" {
                $q_db->enqueue(['irc','review']);
            }
            case "!skip" {
                if ($arg) {
                    $q_db->enqueue(['irc','skip',$arg]);
                } else {
                    $self->irc_priv_print("usage: !skip <package>");
                }
            }
            case "!status" {
                my ($arch, $pkg) = split(/ /, $arg, 2);
                if ($pkg && ($arch eq "5" || $arch eq "7")) {
                    $q_db->enqueue(['irc','status',$arg]);
                } else {
                    $self->irc_priv_print("usage: !status <5|7> <package>");
                }
            }
            case "!unfail" {
                my ($arch, $pkg) = split(/ /, $arg, 2);
                if ($pkg && ($arch eq "5" || $arch eq "7")) {
                    $q_db->enqueue(['irc','unfail',$arg]);
                } else {
                    $self->irc_priv_print("usage: !unfail <5|7> <package|all>");
                }
            }
            case "!unskip" {
                if ($arg) {
                    $q_db->enqueue(['irc','unskip',$arg]);
                } else {
                    $self->irc_priv_print("usage: !unskip <package>");
                }
            }
            case "!update" {
                $q_db->enqueue(['irc','update']);
            }
        }
    }
}

# callback for the queue timer
sub cb_queue {
    my ($self, $con) = @_;
    my $msg = $q_irc->dequeue_nb();
    if ($msg) {
        my ($from, $order) = @{$msg};
        print "IRC[$from $order]\n";
        switch($order){
            case "print" {
                my ($data) = @{$msg}[2];
                $self->irc_priv_print("$data");
            }
            else {
                $self->irc_priv_print("$order from $from");
            }
        }
        if ($order eq 'quit' || $order eq 'recycle'){
            undef $self->{timer};
            $self->{con}->disconnect($order);
            $self->{condvar}->broadcast;
            return;
        }
    }
}

1;
