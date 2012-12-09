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
use RRDTool::OO;

# set timezone for graphs
$ENV{TZ}="MST";

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
    while (my $msg = $q_stats->dequeue_nb()) {
        my ($from, $order) = @{$msg};
        switch ($order){
            case "quit" {
                $available->down_force(10);
                $self->{condvar}->broadcast;
            }
            
            # service orders
            case "stats" {
                $self->log_stat(@{$msg}[2..7]);
            }
        }
    }
}

# farm host 7-day averaging log
sub log_open_host {
    my ($self, $cn) = @_;
    
    $self->{host}->{$cn} = RRDTool::OO->new(file => "$Bin/rrd/$cn.rrd", raise_error => 0);
    
    # RRD file already exists
    return if (-f "$Bin/rrd/$cn.rrd");
    
    # otherwise, create the file
    $self->{host}->{$cn}->create(
        step        => 10,  # 10 second intervals
        data_source => { name   => "cpu0_user",     type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu0_system",   type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu0_wait",     type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu1_user",     type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu1_system",   type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu1_wait",     type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu2_user",     type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu2_system",   type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu2_wait",     type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu3_user",     type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu3_system",   type    => "GAUGE",     min     => 0 },
        data_source => { name   => "cpu3_wait",     type    => "GAUGE",     min     => 0 },
        data_source => { name   => "mem",           type    => "GAUGE",     min     => 0 },
        data_source => { name   => "eth_r",         type    => "GAUGE",     min     => 0 },
        data_source => { name   => "eth_w",         type    => "GAUGE",     min     => 0 },
        data_source => { name   => "sd_ops_r",      type    => "GAUGE",     min     => 0 },
        data_source => { name   => "sd_ops_w",      type    => "GAUGE",     min     => 0 },
        data_source => { name   => "sd_oct_r",      type    => "GAUGE",     min     => 0 },
        data_source => { name   => "sd_oct_w",      type    => "GAUGE",     min     => 0 },
        archive     => { rows   => 1000,         cpoints    => 60,        cfunc     => "AVERAGE" });
    
}

sub log_stat {
    my ($self, $cn, $ts, $data, $pkg, $arch) = @_;
    
    # open host averaging log
    $self->log_open_host($cn) if (!defined $self->{$cn});
    
    # add data point
    $self->{host}->{$cn}->update(time => $ts, values => $data);
    
    # store package data
    #if ($pkg ne '') {
    #    $self->{dbh}->do("insert into stats (package, host, ts, $type) values ((select id from abs where package = ?), (select id from stat_hosts where name = ?), ?, ?)
    #                      on duplicate key update $type = ?", undef, $pkg, $cn, $ts, $value, $value);
    #}
}

sub log_graph_host {
    foreach my $host (keys %{$self->{host}}) {
        # build cdef for combined CPU usage
        my ($cpus) = $self->{dbh}->selectrow_array("select cpus from stat_hosts where name = ?", undef, $host);
        my $cdef_user = "cpu0_user,";
        my $cdef_system = "cpu0_system,";
        my $cdef_wait = "cpu0_wait,";
        for (my $i = 1; $i < $cpus; $i++) {
            $cdef_user .= "cpu" . $i . "_user,+";
            $cdef_system .= "cpu" . $i . "_system,+";
            $cdef_wait .= "cpu" . $i . "_wait,+";
        }
        $cdef_user .= "$cpus,/";
        $cdef_system .= "$cpus,/";
        $cdef_wait .= "$cpus,/";
        
        # create graph
        $self->{host}->{$host}->graph(
            image          => "$self->{packaging}->{imageroot}/$host.png",
            start          => '-1w',
            width          => 1000,
            height         => 200,
            y_grid         => '25:4',
            x_grid         => 'HOUR:12:DAY:1:DAY:1:86400:%A',
            slope_mode     => undef,
            title          => "$host Average CPU and Memory Usage",
            vertical_label => 'Percentage',
            draw           => { type    => 'hidden',    dsname  => 'cpu0_user',     name    => 'cpu0_user',     cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu1_user',     name    => 'cpu1_user',     cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu2_user',     name    => 'cpu2_user',     cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu3_user',     name    => 'cpu3_user',     cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu0_system',   name    => 'cpu0_system',   cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu1_system',   name    => 'cpu1_system',   cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu2_system',   name    => 'cpu2_system',   cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu3_system',   name    => 'cpu3_system',   cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu0_wait',     name    => 'cpu0_wait',     cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu1_wait',     name    => 'cpu1_wait',     cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu2_wait',     name    => 'cpu2_wait',     cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'cpu3_wait',     name    => 'cpu3_wait',     cfunc     => 'AVERAGE' },
            draw           => { type    => 'hidden',    dsname  => 'mem',           name    => 'mem',           cfunc     => 'AVERAGE' },
            draw           => { type    => 'area',      color   => '00FF00',        legend  => 'CPU User',      cdef      => $cdef_user },
            draw           => { type    => 'area',      color   => '0000FF',        legend  => 'CPU System',    cdef      => $cdef_system,  stack  => 1 },
            draw           => { type    => 'area',      color   => 'FF0000',        legend  => 'CPU Wait',      cdef      => $cdef_wait,    stack  => 1 },
            draw           => { type    => 'line',      color   => '000000',        legend  => 'Memory',        cdef      => 'mem,10,/' },
        );
    }
}

1;
