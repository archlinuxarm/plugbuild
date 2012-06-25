#!/usr/bin/perl -w
use strict;

package ALARM::Build::Server;
use ALARM::Build::Factory;
use ALARM::Build::Service;
use ALARM::Build::Database;
use ALARM::Build::IRC;
use ALARM::Build::Mirror;

use Config::General qw(ParseConfig);
use Thread::Queue;
use Thread::Semaphore;

my $q_svc = Thread::Queue->new();
$ALARM::Build::Service::q_svc = $q_svc;
$ALARM::Build::Database::q_svc = $q_svc;
$ALARM::Build::IRC::q_svc = $q_svc;
$ALARM::Build::Mirror::q_svc = $q_svc;

my $q_irc = Thread::Queue->new();
$ALARM::Build::Service::q_irc = $q_irc;
$ALARM::Build::Database::q_irc = $q_irc;
$ALARM::Build::IRC::q_irc = $q_irc;
$ALARM::Build::Mirror::q_irc = $q_irc;

my $q_db = Thread::Queue->new();
$ALARM::Build::Service::q_db = $q_db;
$ALARM::Build::Database::q_db = $q_db;
$ALARM::Build::IRC::q_db = $q_db;
$ALARM::Build::Mirror::q_db = $q_db;

my $q_mir = Thread::Queue->new();
$ALARM::Build::Service::q_mir = $q_mir;
$ALARM::Build::Database::q_mir = $q_mir;
$ALARM::Build::IRC::q_mir = $q_mir;
$ALARM::Build::Mirror::q_mir = $q_mir;


sub new{
    my ($class,$config_file) = @_;
    my $self = {config=> undef};
    
    # load the config file we're going to use.
    my %config = ParseConfig($config_file);
    $self->{config} = \%config;
    # set the auto-refresh for the factory
    $ALARM::Build::Factory::refresh = 2;
    # holy art thou...
    bless $self,$class;
    # and... were out
    return $self;
}

sub Run{
    my $self = shift;
    print "SrvRun\n";
    ###
    my $svc = $self->Service;
    my $db = $self->Database;
    my $irc = $self->IRC;
    my $mir = $self->Mirror;
    ###
    print "SrvStart\n";
    my $d = threads->create(sub{  $db->Run(); });
    my $s = threads->create(sub{ $svc->Run(); });
    my $i = threads->create(sub{ $irc->Run(); });
    my $m = threads->create(sub{ $mir->Run(); });
    sleep 1;
    while( threads->list(threads::running) ){
        foreach my $t (threads->list()){
            $t->join() if $t->is_joinable(); 
        }
        if( $ALARM::Build::IRC::available->down_nb()){
            $ALARM::Build::IRC::available->up();
            $irc = $self->IRC;
            threads->create(sub{ $irc->Run(); });
        }
        if( $ALARM::Build::Database::available->down_nb()){
            $ALARM::Build::Database::available->up();
            $db = $self->Database;
            threads->create(sub{ $db->Run(); });
        }
        if( $ALARM::Build::Service::available->down_nb()){
            $ALARM::Build::Service::available->up();
            $svc = $self->Service;
            threads->create(sub{ $svc->Run(); });
        }
        if( $ALARM::Build::Mirror::available->down_nb()){
            $ALARM::Build::Mirror::available->up();
            $svc = $self->Mirror;
            threads->create(sub{ $mir->Run(); });
        }

        sleep 1;
    }
    foreach my $t (threads->list()){
        $t->join();
    }
    print "SrvRunEnd";
}

sub Service{
    my $self = shift;
    return new ALARM::Build::Factory('Service',$self->{config}->{server}->{service});
}

sub Database{
    my $self = shift;
    return new ALARM::Build::Factory('Database',$self->{config}->{server}->{database})
}

sub IRC{
    my $self = shift;
    return new ALARM::Build::Factory('IRC',$self->{config}->{server}->{irc});
}

sub Mirror{
    my $self = shift;
    return new ALARM::Build::Factory('Mirror',$self->{config}->{server}->{database});
}


# MUST EXIT 1
1;
