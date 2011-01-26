#!/usr/bin/perl -w
use strict;
use warnings;
use lib '.';
use threads;
use Getopt::Long;

my $config_file = 'buildserver.conf';
GetOptions('config' => \$config_file);

use PlugApps::Build::Server;
my $server = new PlugApps::Build::Server($config_file);
$server->Run();