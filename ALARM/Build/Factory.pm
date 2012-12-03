#!/usr/bin/perl
use strict;
use lib '.';

package ALARM::Build::Factory;
use ALARM::Build::Service;
use ALARM::Build::Database;
use ALARM::Build::IRC;
use ALARM::Build::Mirror;

sub new{
    my $class = shift;
    my $want = shift;
    
    my $self = undef;
    
    my $full_want = 'ALARM::Build::'.$want;
    # generate path to the module.
    my $want_path = $full_want;
    $want_path =~ s/::/\//g;
    $want_path.='.pm';
    # create/return
    $self = new $full_want(@_);
    
    #bless $self, $full_want;
    return $self;
}



# must return 1
1;