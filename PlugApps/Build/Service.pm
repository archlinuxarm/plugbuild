#!/usr/bin/perl -w
use strict;

package PlugApps::Build::Service;
use Thread::Queue;
use Thread::Semaphore;

use IO::Select;
use IO::Socket;
use Switch;

our $available = Thread::Semaphore->new(1);
my $time=CORE::time();

our ($q_svc,$q_db,$q_irc);

sub new{
    my ($class,$config) = @_;
    
    my $self = $config;
    $self->{socket}=undef;
    $self->{silo}=undef;
    
    bless $self,$class;
    return $self;
}

sub Run {
    my $self = shift;
    my $requests = -1;
    print "SvcRun\n";
    if( $self->open ){
        print "SvcOpen\n";
        my $done = 0;
		## non-blocking next.
		my %wait_next; # will be keyed by builder name
		my %wait_add; # will be keyed by package detail
        while( !$done ){
            ## check queue of messages
            while(my $qm = $q_svc->dequeue_nb()){
                my ($from,$order) = @{$qm};
                switch ($order){
                    case "recycle" {
                        $done = 1;
                        last;
                    }
					case "next" {
						my ($who,$response,$what) = @{$qm}[2,3,4];
						print "   -> builder $who: $response\n";
						my $cs = $wait_next{$who};
						last if (! defined $cs); # bail out if client disconnected early
						print $cs "$response\n";
						if ($response ne "FAIL") {
							$q_irc->enqueue(['svc','print',"[new] builder: $who - package: $response"]);
						} else {
							$q_irc->enqueue(['svc','print',"[new] found no package to issue $who"]);
						}
						delete $wait_next{$who};
					}
					case "add" {
						my ($pkg,$response,$what) = @{$qm}[2,3,4];
						my $cs = $wait_add{$pkg};
						if ($response eq "FAIL") {
							print $cs "FAIL\n";
						} else {
							print $cs "OK\n";
						}
						delete $wait_add{$pkg};
					}
                }
            }
            ## handle clients
            my @ready = $self->{silo}->can_read(0.5);
            foreach my $rh (@ready){
                if( $rh == $self->{socket}){
                    ## new client
                    my $client = $self->{socket}->accept();
                    print "  -> accepted client\n";
                    $self->{silo}->add($client);
                }else{
                    ## process
                    #my $buf = <$rh>;
                    my $buf;
                    recv($rh,$buf,1024,0);
                    if ($buf) {
                        chomp($buf);
                        my ($command, $data) = split(/!/, $buf);
                        switch ($command) {	# <command>!<data>
                            case 'recycle' {
                                if( $data ){
                                    chomp $data;
                                    $q_db->enqueue(['svc','recycle']) if $data eq 'database' || $data eq 'all';
                                    $q_irc->enqueue(['svc','recycle']) if $data eq 'irc' || $data eq 'all';
                                    $q_svc->enqueue(['svc','recycle']) if $data eq 'service' || $data eq 'all';
                                }
                            }
                            case "quit" {	# quit
                                print $rh "OK\n";
                                print "QUIT issued!\n";
                                $q_db->enqueue(['svc','quit']);
                                $q_irc->enqueue(['svc','quit']);
                                $available->down_force(10);
                                $done = 1;
                                #$self->close;
                            }
                            case "build" {	# build
                                print $rh "OK\n";
                                print "Build Ordered\n";
                                #db_create();
                                $q_db->enqueue(['svc','build']);
                            }
                            case "new" {	# new!<builder>
                                if( !exists( $wait_next{$data})){
									$q_db->enqueue(['svc','next',$data]);
									$wait_next{$data}=$rh;
								}
                            }
                            case "add" {	# add!<repo>|<package>|<filename.tar.xz>|<md5sum>
                                print "   -> adding package: $data\n";
								if( !exists( $wait_next{$data})){
									$q_db->enqueue(['svc','add',$data]);
									$wait_add{$data}=$rh;
								}
                            }
                            case "done" {	# done!<package>
                                print "   -> package done: $data\n";
                                $q_irc->enqueue(['svc','print',"[done] $data"]);#irc_priv_print "[done] $data";
                                $q_db->enqueue(['svc','done',$data]);
                                print $rh "OK\n";
                            }
                            case "fail" {	# fail!<package>
                            	$q_db->enqueue(['svc','fail',$data]);
                                print "   ->package fail: $data\n";
                                print $rh "OK\n";
                                $q_irc->enqueue(['svc','print',"[fail] $data"]);
                            }
                        }
                    } else { # client disconnect
                        print "  -> dropped client\n";
						## have to clear out %wait_next
						foreach my $k (keys %wait_next){
							delete $wait_next{$k} if($wait_next{$k} == $rh);
						}
						## have to clear out %wait_add
						foreach my $k (keys %wait_add){
							delete $wait_add{$k} if($wait_add{$k} == $rh);
						}
						## close the socket.
                        $self->{silo}->remove($rh);
                        CORE::close($rh);
                    }
                }
            }
        }
        $self->close;
    }
    print "SvcRunEnd\n";
    return $requests;
}
#open the service socket
sub open{
    my $self = shift;
    if( $available->down_nb() ){
        ## attempt to open the socket for listening
        my $s = new IO::Socket::INET (
            LocalPort => $self->{port},
            Proto => 'tcp',
            Listen => 16,
            Reuse => 1,
        );
        if( $s ){
            $self->{socket} = $s;
            $self->{silo} = new IO::Select($s);
            return 1;
        }else{
            $available->up();
        }
    }
    return undef;
}
# close the service socket
sub close{
    my $self = shift;
    if( $self->{socket} ){
        $self->{socket}->close;
        $self->{silo} = undef;
        $available->up();
    }
    return 1;
}

###
#   seek
sub db_seek_response{
    my $self = shift;
    my ($message,$criteria) = @_;
    my $response;
    while( !$response ){
        my @crap = IO::Select->select(undef,undef,undef,0.25);
        if( $q_svc->pending() >= 1){
            for( my $i=0; $i<$q_svc->pending(); $i++){
                my $msg = $q_svc->peek($i);
                if( $msg->[0] eq 'db'){
                    if( $msg->[1] eq $message){
                        if( $msg->[2] eq $criteria){
                            # this on is for us.
                            $response = $q_svc->extract($i);
                            printf("SvcFind:%s:%s:%s\n",$message,$criteria,join('-',@{$response}));
                            last;
                        }
                    }
                }
            }
        }
    }
    return $response;
}

## proof we're reloading.
sub printTime{
    print $time."\n";
}
# MUST EXIT 1
1;
