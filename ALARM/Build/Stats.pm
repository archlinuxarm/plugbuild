#!/usr/bin/perl -w
#
# PlugBuild Statistics and Reporting
#

use strict;

package ALARM::Build::Stats;
use Thread::Queue;
use Thread::Semaphore;
use Switch;
use FindBin qw($Bin);
use Text::CSV;
use RRDTool::OO;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP::TLS;
use Email::Simple;

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
    
    $self->{transport} = Email::Sender::Transport::SMTP::TLS->new(
        host     => $self->{email}->{host},
        port     => $self->{email}->{port},
        username => $self->{email}->{user},
        password => $self->{email}->{pass} );
        
    $self->{condvar} = AnyEvent->condvar;
    $self->{timer} = AnyEvent->timer(interval => .5, cb => sub { $self->_cb_queue(); });
    $self->{condvar}->wait;
    
    print "Stats End\n";
    return -1;
}

# callback for thread queue timer
sub _cb_queue {
    my ($self) = @_;
    
    while (my $msg = $q_stats->dequeue_nb()) {
        my ($from, $order) = @{$msg};
        #print "Stats: got $order from $from\n";
        
        # break out of loop
        if($order eq "quit"){
            $available->down_force(10);
            $self->{condvar}->broadcast;
            return;
        }
        
        # run named method with provided args
        if ($self->can($order)) {
            $self->$order(@{$msg}[2..$#{$msg}]);
        } else {
            print "Stats: no method: $order\n";
        }
    }
}

################################################################################
# Orders

# send email about failed package build
# sender: Service
sub email_fail {
    my ($self, $email, $pkg, $version, $list) = @_;
    
    print "Stats: Sending fail email on $pkg to $email\n";
    
    # build body
    my $body = "Please review the build log and submit corrections for the package:\n\n";
    foreach my $arch (sort @{$list}) {
        $body .= "http://archlinuxarm.org:81/builder/in-log/$pkg-$version-$arch.log.html.gz\n";
    }
    
    # build message
    my $message = Email::Simple->create(
        header  => [ From    => 'Arch Linux ARM Build System <builder@archlinuxarm.org>',
                     To      => $email,
                     Subject => "Your last commit for $pkg failed to build" ],
        body    => $body,
        );
    
    # send message
    sendmail($message, { transport => $self->{transport} }) or print "Stats: Error sending email: $@\n";
}

# log RRD data point
# sender: Service
sub log_stat {
    my ($self, $cn, $ts, $data, $pkg, $arch) = @_;
    
    # open host averaging log
    $self->_log_open_host($cn) unless (defined $self->{host}->{$cn});
    
    # add data point
    $self->{host}->{$cn}->update(time => $ts, values => $data);
    
}

################################################################################
# Internal

# create graphs for all currently tracked hosts
sub _log_graph_host {
    my ($self) = @_;
    
    foreach my $host (keys %{$self->{host}}) {
        # build cdef for combined CPU usage
        my ($cpus) = $self->{dbh}->selectrow_array("select cpus from stat_hosts where name = ?", undef, $host);
        my $cdef_user = "cpu0_user,";
        my $cdef_system = "cpu0_system,";
        my $cdef_wait = "cpu0_wait,";
        for (my $i = 1; $i < $cpus; $i++) {
            $cdef_user .= "cpu" . $i . "_user,+,";
            $cdef_system .= "cpu" . $i . "_system,+,";
            $cdef_wait .= "cpu" . $i . "_wait,+,";
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
            title          => "$host: Average CPU and Max Memory Usage",
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
            draw           => { type    => 'hidden',    dsname  => 'mem',           name    => 'mem',           cfunc     => 'MAX' },
            draw           => { type    => 'area',      color   => '00FF00',        legend  => 'CPU User',      cdef      => $cdef_user },
            draw           => { type    => 'area',      color   => '0000FF',        legend  => 'CPU System',    cdef      => $cdef_system,  stack  => 1 },
            draw           => { type    => 'area',      color   => 'FF0000',        legend  => 'CPU Wait',      cdef      => $cdef_wait,    stack  => 1 },
            draw           => { type    => 'line',      color   => '000000',        legend  => 'Memory',        cdef      => 'mem,10,/' },
        );
    }
}

# create and/or open farm host 7-day averaging log
sub _log_open_host {
    my ($self, $cn) = @_;
    
    $self->{host}->{$cn} = RRDTool::OO->new(file => "$Bin/rrd/$cn.rrd", raise_error => 0);
    
    # RRD file already exists
    return if (-f "$Bin/rrd/$cn.rrd");
    
    # otherwise, create the file
    $self->{host}->{$cn}->create(
        step        => 10,  # 10 second intervals
        data_source => { name   => "cpu0_user",     type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu0_system",   type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu0_wait",     type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu1_user",     type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu1_system",   type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu1_wait",     type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu2_user",     type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu2_system",   type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu2_wait",     type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu3_user",     type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu3_system",   type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "cpu3_wait",     type    => "GAUGE",     min     => 0,   max => 100 },
        data_source => { name   => "mem",           type    => "GAUGE",     min     => 0 },
        data_source => { name   => "eth_r",         type    => "GAUGE",     min     => 0 },
        data_source => { name   => "eth_w",         type    => "GAUGE",     min     => 0 },
        data_source => { name   => "sd_ops_r",      type    => "GAUGE",     min     => 0 },
        data_source => { name   => "sd_ops_w",      type    => "GAUGE",     min     => 0 },
        data_source => { name   => "sd_oct_r",      type    => "GAUGE",     min     => 0 },
        data_source => { name   => "sd_oct_w",      type    => "GAUGE",     min     => 0 },
        archive     => { rows   => 1000,         cpoints    => 60,        cfunc     => "AVERAGE" }, # lower resolution 7 day archive (10 minute averaging)
        archive     => { rows   => 1000,         cpoints    => 60,        cfunc     => "MAX" },
        archive     => { rows   => 480,          cpoints    => 18,        cfunc     => "AVERAGE" }, # higher resolution 1 day archive (3 minute averaging)
        archive     => { rows   => 480,          cpoints    => 18,        cfunc     => "MAX" },
    );
    
}

1;
