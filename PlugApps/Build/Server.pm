#!/usr/bin/perl -w
use strict;

package PlugApps::Build::Server;
use PlugApps::Build::Factory;
use PlugApps::Build::Service;
use PlugApps::Build::Database;
use PlugApps::Build::IRC;
use PlugApps::Build::Mirror;

use Config::General qw(ParseConfig);
use Thread::Queue;
use Thread::Semaphore;

my $q_svc = Thread::Queue->new();
$PlugApps::Build::Service::q_svc = $q_svc;
$PlugApps::Build::Database::q_svc = $q_svc;
$PlugApps::Build::IRC::q_svc = $q_svc;
$PlugApps::Build::Mirror::q_svc = $q_svc;

my $q_irc = Thread::Queue->new();
$PlugApps::Build::Service::q_irc = $q_irc;
$PlugApps::Build::Database::q_irc = $q_irc;
$PlugApps::Build::IRC::q_irc = $q_irc;
$PlugApps::Build::Mirror::q_irc = $q_irc;

my $q_db = Thread::Queue->new();
$PlugApps::Build::Service::q_db = $q_db;
$PlugApps::Build::Database::q_db = $q_db;
$PlugApps::Build::IRC::q_db = $q_db;
$PlugApps::Build::Mirror::q_db = $q_db;

my $q_mir = Thread::Queue->new();
$PlugApps::Build::Service::q_mir = $q_mir;
$PlugApps::Build::Database::q_mir = $q_mir;
$PlugApps::Build::IRC::q_mir = $q_mir;
$PlugApps::Build::Mirror::q_mir = $q_mir;


sub new{
    my ($class,$config_file) = @_;
    my $self = {config=> undef};
    
    # load the config file we're going to use.
    my %config = ParseConfig($config_file);
    $self->{config} = \%config;
    # set the auto-refresh for the factory
    $PlugApps::Build::Factory::refresh = 2;
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
    my $s = threads->create(sub{ $svc->Run(); });
    my $d = threads->create(sub{  $db->Run(); });
    my $i = threads->create(sub{ $irc->Run(); });
    sleep 1;
    while( threads->list(threads::running) ){
        foreach my $t (threads->list()){
            $t->join() if $t->is_joinable(); 
        }
        if( $PlugApps::Build::IRC::available->down_nb()){
            $PlugApps::Build::IRC::available->up();
            $irc = $self->IRC;
            threads->create(sub{ $irc->Run(); });
        }
        if( $PlugApps::Build::Database::available->down_nb()){
            $PlugApps::Build::Database::available->up();
            $db = $self->Database;
            threads->create(sub{ $db->Run(); });
        }
        if( $PlugApps::Build::Service::available->down_nb()){
            $PlugApps::Build::Service::available->up();
            $svc = $self->Service;
            threads->create(sub{ $svc->Run(); });
        }
        if( $PlugApps::Build::Mirror::available->down_nb()){
            $PlugApps::Build::Mirror::available->up();
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
    return new PlugApps::Build::Factory('Service',$self->{config}->{server}->{service},$q_irc,$q_db,$q_mir);
}

sub Database{
    my $self = shift;
    return new PlugApps::Build::Factory('Database',$self->{config}->{server}->{database},$q_svc,$q_irc,$q_mir)
}

sub IRC{
    my $self = shift;
    return new PlugApps::Build::Factory('IRC',$self->{config}->{server}->{irc},$q_svc,$q_db,$q_mir);
}

sub Mirror{
    my $self = shift;
    return new PlugApps::Build::Factory('Mirror',$self->{config}->{server}->{database}->{packaging},$q_svc,$q_db,$q_irc);
}


# MUST EXIT 1
1;

__END__
http://pastie.org/1436459
A
| \
B  C
|   \
C    D