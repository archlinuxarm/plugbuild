#!/usr/bin/perl -w
use strict;

package PlugApps::Build::IRC;
use AnyEvent::IRC::Util qw/parse_irc_msg mk_msg/;
use IO::Socket;
use IO::Select;
use Thread::Queue;
use Thread::Semaphore;
use Switch;

our $available = Thread::Semaphore->new(1);
our ($q_svc, $q_db,$q_irc);

sub new{
    my ($class,$config) = @_;
    my $self = $config;
    
    bless $self, $class;
    return $self;
}

sub Run{
    my $self = shift;
    my $orders = 0;
    print "IrcRun\n";
    if($self->connect){
        my $done = 0;
        my $silo = new IO::Select();
        $silo->add($self->{socket});
        while( !$done ){
            # check the queue
            my $msg = $q_irc->dequeue_nb();
            if( $msg ){
                my ($from,$order) = @{$msg};
                print "IRC[$from $order]\n";
                switch ($order){
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
                if($order eq 'quit'){
                    $available->down_force(10);
                    last;
                }
                last if $order eq 'recycle';
            }
            # handle the socket
            my @ready = $silo->can_read(0.5);
            foreach my $rh (@ready){
                my $buf;
                recv($rh,$buf,1024,0);
                if( $buf ){
                    #print "IRC: $buf";
                    my $prsm = parse_irc_msg($buf);
                    next if !defined($prsm); ## i was getting an undefined..somehow..this should bypass.
                    my %msg = %{$prsm};
                    my $prefix = $msg{prefix} || "";
                    my $command = $msg{command} || "";
                    my @params = @{$msg{params}};
                    if ($prefix eq "" && $command eq "PING") { # ping? pong!
                        print $rh "PONG :@params\n";
                        next;
                    }
                    #print join(',',@params);
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
                            	if ($arg) {
                            		$q_db->enqueue(['irc','unfail',$arg]);
                            	} else {
                            		$self->irc_priv_print("usage: !unfail <package|all>");
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
                            	if ($arg) {
                            		$q_db->enqueue(['irc','status',$arg]);
                            	} else {
                            		$self->irc_priv_print("usage: !status <package>");
                            	}
                            }
                        }
                    }
                }
            }
        }
        
        $self->disconnect;
    }
    print "IrcRunEnd\n";
    return $orders;
}

sub connect{
    my $self = shift;
    if( $available->down_nb() ){
        my $s = IO::Socket::INET->new(
            PeerAddr=>$self->{server},
            PeerPort=>$self->{port},
            Proto=>'tcp'
        );
        #die "irc socket fail: $!\n" unless $s;
        return undef unless $s;
        print $s "PASS :".$self->{nick}.' '.$self->{pass}."\n";
        print $s "USER ".$self->{nick}." hostname ".$self->{server}." :plugbuild server\n";
        print $s "NICK ".$self->{nick}."\n";
        print $s "JOIN #".$self->{channel}."\n";
        print " IRC> should be connected now..\n";
        
        $self->{socket} = $s;
        return 1;
    }
    return undef;
}

sub disconnect{
    my $self = shift;
    if( $self->{socket} ){
        $self->{socket}->close;
        $available->up();
    }
    return 1;
}

sub irc_priv_print{
    my $self = shift;
    my $msg = shift;
    print {$self->{socket}} "PRIVMSG #".$self->{channel}." :$msg\n";
}

1;

__END__
			my $buf = <$rh>;
			my %msg = %{parse_irc_msg($buf)};
			my $prefix = $msg{prefix} || "";
			my $command = $msg{command} || "";
			my @params = @{$msg{params}};
			if ($prefix eq "" && $command eq "PING") { # ping? pong!
				print $rh "PONG :@params\n";
				next;
			}
			if ($params[0] && $params[0] eq $irc_chan && $params[1] && $params[1] =~ /^\!.*/) {
				my ($trigger, $arg) = split(/ /, $params[1], 2);
				switch ($trigger) {
					case "!count" {
						if ($arg) {
							my $count = irc_count($arg);
							if ($count) {
								irc_priv_print "$arg = $count";
							}
						} else {
							irc_priv_print "usage: !count <table>";
						}
					}
					case "!rebuild" {
						my ($pkg, $builder) = split(/ /, $arg, 2);
						if ($pkg) {
							if (irc_rebuild($pkg, $builder)) {
								irc_priv_print "rebuild assignment failed\n";
								irc_priv_print "usage: !rebuild <package> [builder]";
							} else {
								irc_priv_print "$pkg added to work queue";
							}
						} else {
							irc_priv_print "usage: !rebuild <package> <builder>";
						}
					}	
				}
			}
