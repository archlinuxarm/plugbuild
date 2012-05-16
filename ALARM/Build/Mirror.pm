#!/usr/bin/perl -w
#
# PlugBuild mirror updater
#

use strict;

package ALARM::Build::Mirror;
use Thread::Queue;
use Thread::Semaphore;
use Switch;

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
    
	return if (! $available->down_nb());
    print "Mirror Run\n";
    
    # get mirror list
    $q_db->enqueue(['mir'
    
    while(my $msg = $q_mir->dequeue ){
        my ($from,$order) = @{$msg};
        print "Mirror: got $order from $from\n";
        switch ($order) {
            case "quit" {
                $available->down_force(10);
                last;
            }
            case "recycle" {
                last;
            }
            
            # database orders
            case "mirrors" {
                my @mirrors;
                foreach my $row (@{@{$msg}[2]}) {
                    my ($mirror) = @$row;
                    push @mirrors, $mirror;
                }
                $self->{mirrors} = \@mirrors;
            }
            
            # service orders
            case "update" {
                my $arch = @{$msg}[2];
                $self->update($arch);
            }
        }
    }

    print "Mirror End\n";
    return -1;
}

sub update {
    my ($self, $arch) = @_;
    print "Mirror: updating $arch\n";
    foreach my $mirror (@{$self->{mirrors}}) {
        system("rsync -rlt --delete $self->{repo}->{$arch} $mirror");
        if ($? >> 8) {
            $q_irc->enqueue(['svc','print',"[mirror] failed to mirror to $mirror: $!"]);
        }
    }
    $q_irc->enqueue(['svc','print',"[mirror] finished mirroring $arch"]);
}

1;
