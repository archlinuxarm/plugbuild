#!/usr/bin/perl
use strict;
use lib '.';

package PlugApps::Build::Factory;
use PlugApps::Build::Service;
use PlugApps::Build::Database;
use PlugApps::Build::IRC;

use Module::Refresh;
my $refresher = new Module::Refresh;
our $refresh = 0;

sub new{
    my $class = shift;
    my $want = shift;
    
    my $self = undef;
    
    my $full_want = 'PlugApps::Build::'.$want;
    # generate path to the module.
    my $want_path = $full_want;
    $want_path =~ s/::/\//g;
    $want_path.='.pm';
    # refresh if set.
    $refresher->refresh_module($want_path) if $refresh == 2;
    $refresher->refresh_module_if_modified($want_path) if $refresh == 1;
    # create/return
    $self = new $full_want(@_);
    
    #bless $self, $full_want;
    return $self;
}



# must return 1
1;