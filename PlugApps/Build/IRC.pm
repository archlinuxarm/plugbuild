#!/usr/bin/perl -w
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
    my $orders = 0;
    print "IrcRun\n";
	
	# set up irc client
	$self->{condvar} = AnyEvent->condvar;
	my $con = new AnyEvent::IRC::Client;
	
	# enable ssl connection (config option)
	$con->enable_ssl() if ($self->{ssl});
	
	# register event callbacks
	$con->reg_cb(connect	=> sub { $self->cb_connect(@_); });
	$con->reg_cb(disconnect	=> sub { $self->cb_disconnect(@_); });
	$con->reg_cb(registered	=> sub { $self->cb_registered(@_); });
	$con->reg_cb(publicmsg	=> sub { $self->cb_publicmsg(@_); });
	
	# arm thread queue timer
	$self->{queue_timer} = AnyEvent->timer(after => .5, cb => sub { cb_queue($con); });
	
	# connect, loop
	$self->connect($con);
	$self->{condvar}->wait;
    print "IrcRunEnd\n";
    return $orders;
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
    print {$self->{socket}} "PRIVMSG #".$self->{channel}." :$msg\n";
}

# callback for socket connection - sleep and reconnect on error
sub cb_connect {
	my ($self, $con, $error) = @_;
	if (defined $error) {
		$available->up();
		warn "IRC: connect error: $error\n";
		$self->{irc_timer} = AnyEvent->timer(after => 15, cb => sub { $self->connect($con); });
	}
}

# callback for socket disconnect - sleep and reconnect
sub cb_disconnect {
	my ($self, $con, $reason) = @_;
	warn "IRC: disconnected: $reason\n";
	return if ($reason eq "shutdown");
	$available->up();
	$self->{irc_timer} = AnyEvent->timer(after => 15, cb => sub { $self->connect($con); });
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
			case "!recycle" {
				if($arg){
					$q_irc->enqueue(['irc','recycle']) if $arg eq 'irc' || $arg eq 'all';
					$q_db->enqueue(['irc','recycle']) if $arg eq 'database' || $arg eq 'all';
					$q_svc->enqueue(['irc','recycle']) if $arg eq 'service' || $arg eq 'all';
				}else{
					$self->irc_priv_print("usage: !recycle <irc|database|service|all>");
				}
			}
			case "!ready" {
				$q_db->enqueue(['irc','ready',$arg]);
			}
			case "!unfuck" {
				$q_db->enqueue(['irc','unfuck']);
			}
			case "!update" {
				$q_db->enqueue(['irc','update']);
			}
			case "!done" {
				$q_db->enqueue(['irc','percent_done',$arg]);
			}
			case "!failed" {
				$q_db->enqueue(['irc','percent_failed',$arg]);
			}
			case "!count" {
				if ($arg) {
					$q_db->enqueue(['irc','count',$arg]);
				} else {
					$self->irc_priv_print("usage: !count <table>");
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
			case "!rebuild" {
				if ($arg) {
					$q_db->enqueue(['irc','rebuild',$arg]);
				} else {
					$self->irc_priv_print("usage: !rebuild <all|some>");
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
			case "!skip" {
				if ($arg) {
					$q_db->enqueue(['irc','skip',$arg]);
				} else {
					$self->irc_priv_print("usage: !skip <package>");
				}
			}
			case "!unskip" {
				if ($arg) {
					$q_db->enqueue(['irc','unskip',$arg]);
				} else {
					$self->irc_priv_print("usage: !unskip <package>");
				}
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
			case "count" {
				my ($tbl,$cnt) = @{$msg}[2,3];
				$self->irc_priv_print("$tbl has $cnt");
			}
			case "percent_done" {
				my ($done,$cnt) = @{$msg}[2,3];
				$self->irc_priv_print("Successful builds: $done of $cnt, ".sprintf("%0.2f%%",($done/$cnt)*100));
			}
			case "percent_failed" {
				my ($done,$cnt) = @{$msg}[2,3];
				$self->irc_priv_print("Failed builds: $done of $cnt, ".sprintf("%0.2f%%",($done/$cnt)*100));
			}
			case "new" {
				my ($builder,$package) = @{$msg}[2,3];
				$self->irc_priv_print("$builder");
			}
			case "update" {
				my ($status) = @{$msg}[2];
				$self->irc_priv_print("Update: $status");
			}
			case "print" {
				my ($data) = @{$msg}[2];
				$self->irc_priv_print("$data");
			}
			else {
				$self->irc_priv_print("$order from $from");
			}
		}
		if ($order eq 'quit' || $order eq 'recycle'){
			$con->disconnect("shutdown");
			$self->{condvar}->broadcast;
			return;
		}
	}
	
	# re-arm the timer
	$self->{queue_timer} = AnyEvent->timer(after => .5, cb => sub { cb_queue($con); });
}

1;
