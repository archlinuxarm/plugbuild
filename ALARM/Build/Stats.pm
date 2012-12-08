#!/usr/bin/perl -w
#
# PlugBuild statistics
#

use strict;

package ALARM::Build::Stats;
use Thread::Queue;
use Thread::Semaphore;
use Switch;
use FindBin qw($Bin);
use Text::CSV;
use DBI;

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
    
    return if (! $available->down_nb());
    print "Stats Run\n";
    
    my $db = DBI->connect("dbi:mysql:$self->{mysql}", "$self->{user}", "$self->{pass}", {RaiseError => 0, AutoCommit => 1, mysql_auto_reconnect => 1});
    if (defined $db) {
        $self->{dbh} = $db;
    } else {
        print "Stats: Can't establish MySQL connection, bailing out.\n";
        return -1;
    }
    
    $self->{condvar} = AnyEvent->condvar;
    $self->{timer} = AnyEvent->timer(interval => .5, cb => sub { $self->cb_queue(); });
    $self->{condvar}->wait;
    
    $db->disconnect;
    
    print "Stats End\n";
    return -1;
}

sub cb_queue {
    my ($self) = @_;
    my $msg = $q_stats->dequeue_nb();
    
    if ($msg) {
        my ($from, $order) = @{$msg};
        print "Stats: got $order from $from\n";
        switch ($order){
            case "quit" {
                $available->down_force(10);
                $self->{condvar}->broadcast;
            }
            
            # service orders
            case "stats" {
                my ($cn, $ts, $type, $value) = @{$msg}[2,3,4,5];
                $self->{dbh}->do("insert into stats (host, ts, $type) (select id, ?, ? from stat_hosts where name = ?)", undef, $ts, $value, $cn);
            }
        }
    }
}

1;
