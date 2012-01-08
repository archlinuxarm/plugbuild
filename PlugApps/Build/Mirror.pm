#!/usr/bin/perl -w
#
# PlugBuild mirror updater
#

use strict;

package PlugApps::Build::Mirror;
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
    if (ref($self->{mirror}->{address}) eq 'ARRAY') {
        foreach my $mirror (@{$self->{mirror}->{address}}) {
            print "Mirror: rsync -rtl --delete $self->{repo}->{$arch} $mirror\n";
        }
    } elsif (defined $self->{mirror}->{address}) {
        print "Mirror: rsync -rlt --delete $self->{repo}->{$arch} $self->{mirror}->{address}\n";
    }
}

1;
