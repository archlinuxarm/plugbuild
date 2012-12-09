#!/usr/bin/perl -w
#
# MySQL and repository database management
#

use strict;

package ALARM::Build::Database;
use DBI;
use Thread::Queue;
use Thread::Semaphore;
use threads::shared;
use Switch;
use File::stat;
use HTTP::Tiny;
use JSON::XS;
use Scalar::Util;

# we only ever want one instance connected to the database.
# EVER.
our $available = Thread::Semaphore->new(1);

our ($q_svc, $q_db, $q_irc, $q_mir, $q_stats);

sub new{
    my ($class, $config) = @_;
    
    my $self = $config;
    $self->{dbh}=undef;
    
    bless $self, $class;
    return $self;
}


sub Run {
    my $self = shift;
    my $requests = -1;
    print "DbRun\n";
    
    my $open = $self->connect;
    
    # load architectures and skip bitmasks
    $self->rehash();
    
    # thread queue loop
    while (my $orders = $q_db->dequeue) {
        my ($from,$order) = @{$orders};
        print "DB: got $order from $from\n";
        if($order eq "quit"){
            $available->down_force(10);
            last;
        }
        switch ($order) {
            # irc orders
            case "aur_check" {
                $self->aur_check();
            }
            case "continue" {
                if (defined $self->{dellist}) {
                    $self->update_continue();
                } else {
                    $q_irc->enqueue(['db','print',"No pending update."]);
                }
            }
            case "count" {
                my $table = @{$orders}[2];
                my $count = $self->count($table);
                $q_irc->enqueue(['db','print',"$table has $count"]);
            }
            case "deselect" {
                my ($arch, $pkg) = @{$orders}[2,3];
                $self->pkg_select($arch, $pkg, 0);
            }
            case "done_pub" {
                my $rows = $self->{dbh}->selectall_arrayref("select arch, count(*) from files where del = 0 group by arch order by arch");
                my $result = "Available packages: ";
                foreach my $row (@$rows) {
                    my ($arch, $count) = @$row;
                    $result .= "$count for $arch, ";
                }
                $result =~ s/, $//;
                $q_irc->enqueue(['db', 'print', $result, 1]);
            }
            case "force" {
                my ($arch, $pkg) = @{$orders}[2,3];
                if (!$self->{arch}->{$arch}) {  # determine if we were given shorthand arch string or not
                    $arch = "armv$arch";
                    if (!$self->{arch}->{$arch}) {
                        $q_irc->enqueue(['db', 'print', "usage: !force <arch> <package>"]);
                        return;
                    }
                }
                my @force = $self->{dbh}->selectrow_array("select done, repo from $arch as a inner join abs on (a.id = abs.id) where package = ?", undef, $pkg);
                if (!defined $force[0]) {
                    $q_irc->enqueue(['db', 'print', "[force] Package $pkg not found."]);
                } elsif ($force[0] eq "1") {
                    $q_irc->enqueue(['db', 'print', "[force] Package $pkg is already done for $arch."]);
                } else {
                    $q_svc->enqueue(['db', 'force', { command => 'next', arch => "$arch", repo => $force[1], pkgbase => $pkg }]);
                }
            }
            case "highmem" {
                my ($pkg) = @{$orders}[2];
                my $rows = $self->{dbh}->do("update abs set highmem = highmem ^ 1 where package = ?", undef, $pkg);
                if ($rows < 1) {
                    $q_irc->enqueue(['db', 'print', "[highmem] No such package named $pkg"]);
                } else {
                    $q_irc->enqueue(['db', 'print', "[highmem] Toggled $pkg"]);
                }
            }
            case "info" {
                $self->pkg_info(@{$orders}[2]);
            }
            case "override" {
                my ($pkg) = @{$orders}[2];
                my $rows = $self->{dbh}->do("update abs set override = override ^ 1 where package = ?", undef, $pkg);
                if ($rows < 1) {
                    $q_irc->enqueue(['db', 'print', "[override] No such package named $pkg"]);
                } else {
                    $q_irc->enqueue(['db', 'print', "[override] Toggled $pkg"]);
                }
            }
            case "percent_done" {
                $self->done();
            }
            case "percent_failed" {
                $self->failed();
            }
            case "prune" {
                my $pkg = @{$orders}[2];
                foreach my $arch (keys %{$self->{arch}}) {
                    $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set done = 0, fail = 0 where package = ?", undef, $pkg);
                    $self->pkg_prep($arch, { pkgbase => $pkg });
                }
            }
            case "ready" {
                my $arch = @{$orders}[2];
                if (defined $arch) {
                    $self->ready_detail($arch);
                } else {
                    $self->ready();
                }
            }
            case "rehash" {
                $self->rehash();
            }
            case "review" {
                if (defined $self->{dellist}) {
                    $self->review();
                } else {
                    $q_irc->enqueue(['db','print',"No review available."]);
                }
            }
            case "search" {
                $self->pkg_search(@{$orders}[2]);
            }
            case "select" {
                my ($arch, $pkg) = @{$orders}[2,3];
                $self->pkg_select($arch, $pkg, 1);
            }
            case "skip" {
                $self->pkg_skip(@{$orders}[2], 0);
            }
            case "status" {
                my ($arch, $package) = split(/ /, @{$orders}[2], 2);
                $self->status($arch, $package);
            }
            case "unfail" {
                my ($arch, $package) = @{$orders}[2,3];
                $self->pkg_unfail($arch, $package);
            }
            case "unskip" {
                $self->pkg_skip(@{$orders}[2], 1);
            }
            case "update" {
            	$self->update();
            }
            
            # service orders
            case "add" {
                my ($arch, $builder, $data) = @{$orders}[2,3,4];
            	if ($self->pkg_add($arch, $data)) {
                    $data->{response} = "FAIL";
            		$q_svc->enqueue(['db', 'ack', $arch, $builder, $data]);
            	} else {
                    $data->{response} = "OK";
            		$q_svc->enqueue(['db', 'ack', $arch, $builder, $data]);
            	}
            }
            case "done" {
                my ($arch, $package) = @{$orders}[2,3];
            	$self->pkg_done($arch, $package);
            }
            case "dump" {
                my ($ou, $cn, $data) = @{$orders}[2,3,4];
                my $rows = shared_clone($self->{dbh}->selectall_hashref(
                    "select package, repo, armv5.done as v5_done, armv5.fail as v5_fail, armv7.done as v7_done, armv7.fail as v7_fail
                     from abs inner join armv5 on (abs.id = armv5.id) inner join armv7 on (abs.id = armv7.id)
                     where del = 0 and skip != 0", "package"));
                $data->{dump} = $rows;
                $q_svc->enqueue(['db', 'admin', $data]);
            }
            case "fail" {
            	my ($arch, $package) = @{$orders}[2,3];
                $self->pkg_fail($arch, $package);
            }
            case "next" {
                my ($arch, $builder, $highmem) = @{$orders}[2,3,4];
                my $next = $self->get_next_package($arch, $builder, $highmem);
                if ($next) {
                    $self->pkg_work(@{$next}[1], $arch, $builder);
                    $q_svc->enqueue(['db', 'next', $arch, $builder, { command => 'next', arch => $arch, repo => $next->[0], pkgbase => $next->[1] }]);
                } else {
                    $q_svc->enqueue(['db', 'next', $arch, $builder, { command => 'next', pkgbase => "FAIL" }]);
                }
            }
            case "poll" {
                $self->poll(@{$orders}[2]);
            }
            case "prep" {
                my ($arch, $builder, $data) = @{$orders}[2,3,4];
                $self->pkg_prep($arch, $data);
                $q_svc->enqueue(['db', 'ack', $arch, $builder, $data]);
            }
            case "release" {
                my ($arch, $builder, $data) = @{$orders}[2,3,4];
                $self->pkg_release($data->{pkgbase}, $arch, $builder);
            }
        }
    }
    ##
    $self->disconnect if $open;
    print "DbRunEnd\n";
    return $requests;
}

# connect to database
sub connect {
    my ($self) = @_;
    if( $available->down_nb ){
        my $database = $self->{mysql};
        my $user = $self->{user};
        my $pass = $self->{pass};
        my $db = DBI->connect("dbi:mysql:$database", "$user", "$pass", {RaiseError => 0, AutoCommit => 1, mysql_auto_reconnect => 1});
        if( defined($db) ){
            # store our handle
            $self->{dbh} = $db;
            return 1;
        }else{
            # $db undef, failed
            $available->up;
        }
    }
    return undef;
}

# disconnect from database
sub disconnect {
    my ($self) = @_;
    if( defined($self->{dbh}) ){
        $self->{dbh}->disconnect;
        $available->up;
        $self->{dbh} = undef;
    }
}

# rehash stored attributes pulled from database
#   skip bitmasks in use:
#    - armv5:  0000 0011 ( 3) - all | v5
#    - armv7:  0000 0101 ( 5) - all | v7
#    - armv6:  0001 0001 (17) - all | v6
sub rehash {
    my $self = shift;
    
    undef $self->{arch};
    undef $self->{skip};
    my $rows = $self->{dbh}->selectall_arrayref("select * from architectures");
    foreach my $row (@$rows) {
        my ($arch, $parent, $skip) = @$row;
        $self->{arch}->{$arch} = $parent || $arch;
        $self->{skip}->{$arch} = int($skip) || 0;
    }
    
    # notify Service of architectures
    $q_svc->enqueue(['db', 'arches', join(' ', keys %{$self->{arch}})]);
}

# get next available package to build
sub get_next_package {
    my ($self, $arch, $builder, $highmem) = @_;
    my $memstr = $highmem?"":"and p.highmem = 0";
    if (defined($self->{dbh})) {
    	$self->{dbh}->do("update $arch set builder = null where builder = ?", undef, $builder);
        my @next_pkg = $self->{dbh}->selectrow_array("select
            p.repo, p.package, p.depends, p.makedepends
            from abs as p
            join $arch as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
            left outer join (select d.id as id, max(done) as done from deps as d inner join names as n on (n.name = d.dep) inner join $arch as a on (a.id = n.package) group by id, name) as d on (d.id = p.id)
            where p.skip & ? > 0 and p.del = 0 $memstr
            group by p.id
            having (count(d.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) ) order by p.importance limit 1",
            undef, $self->{skip}->{$arch});
        return undef if (!$next_pkg[0]);
        return \@next_pkg;
    } else {
        return undef;
    }
}

# return number of packages ready to build
sub ready {
    my $self = shift;
    my $ret = "Packages waiting to be built: ";
    
    foreach my $arch (sort keys %{$self->{arch}}) {
        my $parent = $self->{arch}->{$arch};
        my @next_pkg = $self->{dbh}->selectrow_array("select count(*) from (
            select
                p.repo, p.package, p.depends, p.makedepends
                from
                abs as p
                    join $arch as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
                    left outer join (select d.id as id, max(done) as done from deps as d inner join names as n on (n.name = d.dep) inner join $arch as a on (a.id = n.package) group by id, name) as d on (d.id = p.id)
                where p.skip & ? > 0 and p.del = 0  
                group by p.id
                having (count(d.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) )
            ) as xx", undef, $self->{skip}->{$arch});
        $ret .= "$arch: $next_pkg[0], ";
    }
    $ret =~ s/, $//;
    $q_irc->enqueue(['db', 'print', $ret]);
}

# return names of packages ready to build
sub ready_detail {
    my ($self, $arch) = @_;
    
    # determine if we were given shorthand arch string or not
    if (!$self->{arch}->{$arch}) {
        $arch = "armv$arch";
        if (!$self->{arch}->{$arch}) {
            $q_irc->enqueue(['db', 'print', "usage: !ready [arch]"]);
            return;
        }
    }
    
    my $parent = $self->{arch}->{$arch};
    my $rows = $self->{dbh}->selectall_arrayref("select
        p.repo, p.package, p.depends, p.makedepends
        from
        abs as p
            join $arch as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
            left outer join (select d.id as id, max(done) as done from deps as d inner join names as n on (n.name = d.dep) inner join $arch as a on (a.id = n.package) group by id, name) as d on (d.id = p.id)
        where p.skip & ? > 0 and p.del = 0
        group by p.id
        having (count(d.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) ) order by p.importance",
        undef, $self->{skip}->{$arch});
    
	my $ret = undef;
	my $cnt = 0;
	foreach my $row (@$rows) {
        my ($repo, $package) = @$row;
	    $ret .= "$repo/$package, ";
	    $cnt++;
	}
    $ret =~ s/, $// if $cnt > 0;
    
    $q_irc->enqueue(['db', 'print', "Packages waiting to be built: $cnt"]);
    $q_irc->enqueue(['db', 'print', "Packages waiting: $ret"]) if $cnt > 0;
}

# obsolete: return a count of rows from a table
sub count {
    my $self = shift;
    
    my $data = shift;
    print "DB-Count $data\n";
    my $ret = ($self->{dbh}->selectrow_array("select count(*) from $data"))[0] || 0;
    print "DB-Count $data : $ret\n";
    return $ret;
}

# return number of packages complete for each architecture
sub done {
    my $self = shift;
    my $ret = "Successful builds: ";
    
    foreach my $arch (sort keys %{$self->{arch}}) {
        my $count = ($self->{dbh}->selectrow_array("select count(*) from abs inner join $arch as a on (a.id = abs.id) where done = 1 and fail = 0 and skip & ? > 0 and del = 0", undef, $self->{skip}->{$arch}))[0] || 0;
        my $total = ($self->{dbh}->selectrow_array("select count(*) from abs where skip & ? > 0 and del = 0", undef, $self->{skip}->{$arch}))[0] || 1;
        $ret .= "$arch: $count/$total (" . sprintf("%0.2f%%", ($count/$total)*100) . ") | ";
    }
    $ret =~ s/ \| $//;
    $q_irc->enqueue(['db', 'print', $ret]);
}

# return number of packages that failed to build for each architecture
sub failed {
    my $self = shift;
    my $ret = "Failed builds: ";
    
    foreach my $arch (sort keys %{$self->{arch}}) {
        my $count = ($self->{dbh}->selectrow_array("select count(*) from abs inner join $arch as a on (a.id = abs.id) where fail = 1 and skip & ? > 0 and del = 0", undef, $self->{skip}->{$arch}))[0] || 0;
        my $total = ($self->{dbh}->selectrow_array("select count(*) from abs where skip & ? > 0 and del = 0", undef, $self->{skip}->{$arch}))[0] || 1;
        $ret .= "$arch: $count/$total (" . sprintf("%0.2f%%", ($count/$total)*100) . ") | ";
    }
    $ret =~ s/ \| $//;
    $q_irc->enqueue(['db', 'print', $ret]);
}

# return the current status of a package within the build system
sub status {
    my ($self, $package) = @_;
    my $skipret = undef;
    
    if (defined($package) && $package ne '') {
        foreach my $arch (sort keys %{$self->{arch}}) {
            my @row = $self->{dbh}->selectrow_array("select abs.id, package, pkgname, repo, pkgver, pkgrel, done, fail, builder, git, abs, skip, highmem, override, del, finish - start as time from abs inner join $arch as a on (abs.id = a.id) where package = ?", undef, $package);
            if ($row[0]) { # package found
                my ($id, $name, $pkgname, $repo, $pkgver, $pkgrel, $done, $fail, $builder, $git, $abs, $skip, $highmem, $override, $del, $time) = @row;
                
                # add to combined skipped architecture printout at end
                if (!($skip & $self->{skip}->{$arch})) {
                    $skipret .= "$arch, ";
                    next;
                }
                
                # package removed from repo, print and bail out
                if ($del) {
                    $q_irc->enqueue(['db', 'print', "[status] $repo/$name has been removed."]);
                    return;
                }
                
                # make data human-readable
                my ($repover, $reporel) = $self->{dbh}->selectrow_array("select pkgver, pkgrel from files where del = 0 and arch = ? and pkgbase = ? limit 1", undef, $arch, $package);
                if (!$repover) {
                    $repover = 0;
                    $reporel = 0;
                }
                $highmem = $highmem ? " [highmem]" : "";
                $override = $override ? " [override]" : "";
                my $state = (!$done && !$fail?'unbuilt':(!$done&&$fail?'failed':($done && !$fail?'done':'???')));
                $state = 'building' if ($builder && $state eq 'unbuilt');
                
                my $source = ($git?'git':($abs?'abs':'???'));
                my $s; my $duration = (($s=int($time/86400))?$s."d":'') . (($s=int(($time%86400)/3600))?$s."h":'') . (($s=int(($time%3600)/60))?$s."m":'') . (($s = $time%60)?$s."s":'');
                my $status = "[$arch]$highmem$override $name ($pkgver-$pkgrel|$repover-$reporel): repo=>$repo, src=>$source, state=>$state";
                $status .= ", builder=>$builder" if $state eq 'building';
                $status .= ", time=>$duration" if $state ne 'building';
                
                # generate list of packages blocking this package from building
                my $names;
                foreach my $name (split(/ /, $pkgname)) {
                    $names .= "'$name', ";
                }
                $names =~ s/, $//;
                my $blocklist = $self->{dbh}->selectall_arrayref("select abs.repo, abs.package, a.fail, abs.skip, abs.del from deps as d
                                                                  inner join names as n on (d.dep = n.name)
                                                                  inner join $arch as a on (a.id = n.package)
                                                                  inner join abs on (abs.id = a.id)
                                                                  where d.id = $id group by n.name having max(done) = 0");
                if (scalar(@{$blocklist})) {
                    $status .= ", blocked on: ";
                    foreach my $blockrow (@$blocklist) {
                        my ($blockrepo, $blockpkg, $blockfail, $blockskip, $blockdel) = @$blockrow;
                        $status .= sprintf("%s/%s (%s) ", $blockrepo, $blockpkg, $blockdel?"D":!$blockskip?"S":$blockfail?"F":"N");
                    }
                }
                
                $q_irc->enqueue(['db', 'print', $status]);
            } else {
                $q_irc->enqueue(['db', 'print', "could not find package $package"]);
                last;
            }
        }
        if ($skipret) {
            $skipret =~ s/, $//;
            $q_irc->enqueue(['db', 'print', "[status] $package skipped for $skipret"]);
        }
    }
}

# add a completed package to the repository
sub pkg_add {
    my ($self, $arch, $data) = @_;
    my $repo = $data->{repo};
    my $pkgname = $data->{pkgname};
    my $filename = $data->{filename};
    my $md5sum_sent = $data->{md5sum};
    print " -> adding $pkgname\n";

    # verify md5sum
    my $md5sum_file = `md5sum $self->{packaging}->{in_pkg}/$arch/$filename`;
    if ($? >> 8) {
        print "    -> md5sum failed\n";
        return 1;
    }
    $md5sum_file = (split(/ /, $md5sum_file))[0];
    if ($md5sum_sent ne $md5sum_file) {
        print "    -> md5sum mismatch: $filename $md5sum_sent/$md5sum_file\n";
        return 1;
    }
    
    # move file, repo-add it
    print "   -> adding $arch/$repo/$pkgname ($filename)..\n";
    $q_svc->enqueue(['db', 'farm', 'insert', $arch, $repo, $filename]);
    system("mv -f $self->{packaging}->{in_pkg}/$arch/$filename $self->{packaging}->{repo}->{$arch}/$repo");
    if ($? >> 8) {
        print "    -> move failed\n";
        return 1;
    }
    $q_svc->enqueue(['db', 'farm', 'add', $arch, $repo, $filename]);
    system("$self->{packaging}->{archbin}/repo-add -q $self->{packaging}->{repo}->{$arch}/$repo/$repo.db.tar.gz $self->{packaging}->{repo}->{$arch}/$repo/$filename");
    if ($? >> 8) {
        print "    -> move failed\n";
        return 1;
    }
    
    # add package to file table
    $self->{dbh}->do("insert into files (arch, repo, pkgbase, pkgname, pkgver, pkgrel, pkgdesc, search, filename, md5sum) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     undef, $arch, $repo, $data->{pkgbase}, $pkgname, $data->{pkgver}, $data->{pkgrel}, $data->{pkgdesc}, "$pkgname $data->{pkgdesc}", $filename, $md5sum_sent);
     
    return 0;
}

# prepare files table, remove old files from repo
sub pkg_prep {
    my ($self, $arch, $data) = @_;
    
    my $rows = $self->{dbh}->selectall_arrayref("select repo, pkgname, filename from files where arch = ? and pkgbase = ? and del = 0", undef, $arch, $data->{pkgbase});
    foreach my $row (@$rows) {
        my ($repo, $pkgname, $filename) = @$row;
        
        # remove pkgname from repo.db
        $q_svc->enqueue(['db', 'farm', 'remove', $arch, $repo, $pkgname]);
        system("$self->{packaging}->{archbin}/repo-remove -q $self->{packaging}->{repo}->{$arch}/$repo/$repo.db.tar.gz $pkgname");
        
        # remove file
        $q_svc->enqueue(['db', 'farm', 'delete', $arch, $repo, $filename]);
        system("rm -f $self->{packaging}->{repo}->{$arch}/$repo/$filename");
    }
    
    # flag del on previous entries
    $self->{dbh}->do("update files set del = 1 where arch = ? and pkgbase = ?", undef, $arch, $data->{pkgbase});
}

# relocate packages in the repo, update files tables
sub pkg_relocate {
    my ($self, $pkgbase, $newrepo) = @_;
    
    my $rows = $self->{dbh}->selectall_arrayref("select id, arch, repo, pkgname, filename from files where pkgbase = ? and del = 0", undef, $pkgbase);
    foreach my $row (@$rows) {
        my ($id, $arch, $oldrepo, $pkgname, $filename) = @$row;
        
        # remove from old repo.db
        $q_svc->enqueue(['db', 'farm', 'remove', $arch, $oldrepo, $pkgname]);
        system("$self->{packaging}->{archbin}/repo-remove -q $self->{packaging}->{repo}->{$arch}/$oldrepo/$oldrepo.db.tar.gz $pkgname");
        
        # move file
        $q_svc->enqueue(['db', 'farm', 'move', $arch, [$oldrepo, $newrepo], $filename]);
        system("mv $self->{packaging}->{repo}->{$arch}/$oldrepo/$filename $self->{packaging}->{repo}->{$arch}/$newrepo/$filename");
        
        # add to new repo.db
        $q_svc->enqueue(['db', 'farm', 'add', $arch, $newrepo, $filename]);
        system("$self->{packaging}->{archbin}/repo-add -q $self->{packaging}->{repo}->{$arch}/$newrepo/$newrepo.db.tar.gz $self->{packaging}->{repo}->{$arch}/$newrepo/$filename");
        
        # update files table
        $self->{dbh}->do("update files set repo = ? where id = ?", undef, $newrepo, $id);
    }
}

# assign builder to package
sub pkg_work {
    my ($self, $package, $arch, $builder) = @_;
    $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.builder = ?, a.start = unix_timestamp() where abs.package = ?", undef, $builder, $package)
}

# release builder from package
sub pkg_release {
    my ($self, $package, $arch, $builder) = @_;
    $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.builder = null, a.start = unix_timestamp() where abs.package = ?", undef, $package)
}

# set package done
sub pkg_done {
    my ($self, $arch, $package) = @_;
    $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.builder = null, a.done = 1, a.fail = 0, a.finish = unix_timestamp() where abs.package = ?", undef, $package);
}

# set package fail
sub pkg_fail {
    my ($self, $arch, $package) = @_;
    $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.builder = null, a.done = 0, a.fail = 1, a.finish = unix_timestamp() where abs.package = ?", undef, $package);
}

# unfail package or all
sub pkg_unfail {
    my ($self, $arch, $package) = @_;
    my $rows;
    
    # determine if we were given shorthand arch string or not
    if (!$self->{arch}->{$arch}) {
        $arch = "armv$arch";
        if (!$self->{arch}->{$arch}) {
            $q_irc->enqueue(['db', 'print', "usage: !unfail <arch> <package|all>"]);
            return;
        }
    }
    
    if ($package eq "all") {
        $rows = $self->{dbh}->do("update $arch set fail = 0, done = 0, builder = null where fail = 1");
    } else {
        $rows = $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.fail = 0, a.done = 0, a.builder = null where abs.package = ?", undef, $package);
    }
    if ($rows < 1) {
        $q_irc->enqueue(['db','print',"Couldn't unfail $package for $arch"]);
    } else {
        my ($skip) = $self->{dbh}->selectrow_array("select skip from abs where package = ?", undef, $package);
        if ($skip & $self->{skip}->{$arch}) {        
            $q_irc->enqueue(['db', 'print', "Unfailed $package for $arch"]);
        } else {
            $q_irc->enqueue(['db', 'print', "Unfailed $package for $arch; however, the package is skipped for this architecture."]);
        }
    }
}

# modify package to be (un)skipped
sub pkg_skip {
    my ($self, $pkg, $op) = @_;
    my $rows = $self->{dbh}->do("update abs set skip = $op where package = ?", undef, $pkg);
    if ($rows < 1) {
        $q_irc->enqueue(['db','print',"Couldn't modify $pkg, check the name."]);
    } else {
        $q_irc->enqueue(['db','print',sprintf("%s %s", $op?"Unskipped":"Skipped", $pkg)]);
        if (!$op) {
            foreach my $arch (keys %{$self->{arch}}) {
                $self->pkg_prep($arch, { pkgbase => $pkg });
            }
        }
    }
}

# search packages, public print results to irc
sub pkg_search {
    my ($self, $search) = @_;
    my $return;
    
    $search = "\%$search\%";
    my $rows = $self->{dbh}->selectall_arrayref("select pkgname from files where del = 0 and search like ? group by pkgname limit 10", undef, $search);
    foreach my $row (@$rows) {
        my ($pkgname) = @$row;
        $return .= "$pkgname, ";
    }
    
    if ($return) {
        $return =~ s/, $//;
        $q_irc->enqueue(['db', 'print', "Matching packages: $return", 1]);
    } else {
        $q_irc->enqueue(['db', 'print', "No packages found.", 1]);
    }
}

# package info, public print to irc
sub pkg_info {
    my ($self, $pkg) = @_;
    my $return;
    
    my $rows = $self->{dbh}->selectall_arrayref("select group_concat(arch), repo, pkgbase, pkgname, pkgver, pkgrel, pkgdesc from files where pkgname = ? and del = 0 group by pkgname", undef, $pkg);
    if (!@{$rows}[0]) {
        $q_irc->enqueue(['db', 'print', "No package named $pkg.", 1]);
        return;
    } else {
        my ($arch, $repo, $pkgbase, $pkgname, $pkgver, $pkgrel, $pkgdesc) = @{@{$rows}[0]};
        $arch =~ s/,/, /g;
        $return = "$repo/$pkgname ";
        $return .= "(split from $pkgbase) " if $pkgbase ne $pkgname;
        $return .= "$pkgver-$pkgrel, available for $arch: $pkgdesc";
        $q_irc->enqueue(['db', 'print', $return, 1]);
    }
}

# (de)select package from building for an architecture
sub pkg_select {
    my ($self, $arch, $pkg, $op) = @_;
    my $cmd = $op?"select":"deselect";
    
    # determine if we were given shorthand arch string or not
    if (!$self->{arch}->{$arch}) {
        $arch = "armv$arch";
        if (!$self->{arch}->{$arch}) {
            $q_irc->enqueue(['db', 'print', "usage: !$cmd <arch> <package>"]);
            return;
        }
    }
    
    my ($git) = $self->{dbh}->selectrow_array("select git from abs where package = ?", undef, $pkg);
    if ($git == 1) {
        $q_irc->enqueue(['db', 'print', "[$cmd] $pkg is sourced from git, adjust buildarch value to make changes."]);
        return;
    }
    
    my $bit = $op?'|':'^';
    if ($self->{dbh}->do("update abs set skip = skip $bit ? where package = ?", undef, $self->{skip}->{$arch}, $pkg) < 1) {
        $q_irc->enqueue(['db', 'print', "[$cmd] No package named $pkg"]);
    } else {
        $q_irc->enqueue(['db', 'print', "[$cmd] $pkg $cmd" . "ed for $arch"]);
    }
}

# poll git sources for new packages
sub poll {
    my ($self, $poll_type) = @_;
    
    # parse sources
    my $repos = $self->{dbh}->selectall_arrayref("select id, type, root, sha from sources");
    foreach my $repo (@$repos) {
        my ($id, $type, $root, $sha) = @$repo;
        my @paths;
        
        # check type
        next if (defined $poll_type && $type ne $poll_type);
        
        # pull, get HEAD sha
        my $newsha = `git --work-tree=$root --git-dir=$root/.git pull -q && git --work-tree=$root --git-dir=$root/.git rev-parse HEAD`;
        if ($? >> 8) {
            $q_irc->enqueue(['db','print',"[poll] Failed to poll source ($id) type: $type, root: $root"]);
            next;
        }
        chomp $newsha;
        
        print "[poll] polled $id $type $root $sha -> $newsha\n";
        next if ($sha eq $newsha);  # 
        
        # get changed directories
        if ($type eq 'git') {       # git overlay: repo/package
            @paths = `git --work-tree=$root --git-dir=$root/.git diff --name-only $sha $newsha | cut -d'/' -f-2 | sort -u`;
        } elsif ($type eq 'abs') {  # upstream: package
            @paths = `git --work-tree=$root --git-dir=$root/.git diff --name-only $sha $newsha | cut -d'/' -f-3 | sort -u | egrep '.*/(core|extra|community)-(i686|any)'`;
        } else {                    # skip bad entries
            $q_irc->enqueue(['db','print',"[poll] Unknown source ($id) type: $type, root: $root"]);
            next;
        }
        
        # queue new directory changes (ref=0), or update count reference (ref=2)
        foreach my $path (@paths) {
            my ($pkg, $repo);
            chomp $path;
            if ($type eq 'git') {   # get repo for git overlay packages since it's easy now
                ($repo, $pkg) = split('/', $path, 2);
                next if (!$pkg);    # not a package update, skip
            } elsif ($type eq 'abs') {
                ($pkg, $repo) = $path =~ /([^\/]*)\/repos\/(\w+)/;
            }
            print "[poll] inserting $type, path: $root/$path, package: $pkg, repo: $repo\n";
            $self->{dbh}->do("insert into queue (type, path, package, repo) values (?, ?, ?, ?)
                              on duplicate key update ref = 2",
                              undef, $type, "$root/$path", $pkg, $repo);
        }
        
        # update latest HEAD sha in sources
        $self->{dbh}->do("update sources set sha = ? where id = ?", undef, $newsha, $id);
    }
    
    # process unchanged queue items
    $self->process();
    
    # check changes
    my $changes = $self->{dbh}->selectall_arrayref("select type, path, ref, package, repo from queue where ref != 1");
    foreach my $change (@$changes) {
        my ($type, $path, $ref, $pkg, $repo) = @$change;
        my $hold = 0;
        
        if (! -d $path) {           # directory doesn't exist, flag removed
            $self->{dbh}->do("update queue set hold = 0, del = 1, ref = 1 where path = ?", undef, $path);
            next;
        }
        if ($path =~ /.*\-lts#/) {  # skip LTS packages, remove from queue
            $self->{dbh}->do("delete from queue where path = ?", undef, $path);
            next; 
        }
        
        # source PKGBUILD
        my $vars = `./gitsource.sh $path`;
        chomp($vars);
        if ($vars eq "NULL") {      # skip non-existent/malformed packages
            $self->{dbh}->do("delete from queue where path = ?", undef, $path);
            next;
        }
        my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends,$buildarch,$noautobuild,$highmem) = split(/\|/, $vars);
        
        # warn about git overlay being different and flag hold, or warn of override and remove from queue
        if ($type eq 'abs') {
            my ($db_repo, $db_pkgver, $db_pkgrel, $db_git, $db_skip, $db_override) = $self->{dbh}->selectrow_array("select repo, pkgver, pkgrel, git, skip, override from abs where package = ?", undef, $pkg);
            if (defined $db_git && $db_git == 1) {
                $buildarch = $db_skip;
                my $db_pkgrel_stripped = $db_pkgrel;    # strip any of our fraction pkgrel numbers
                $db_pkgrel_stripped =~ s/\.+.*//;
                if ($db_repo ne $repo) {
                    $q_irc->enqueue(['db', 'print', "[poll] Upcoming: $db_repo/$pkg has been relocated to $repo/$pkg"]);
                }
                if ($db_override == 0 && "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel_stripped") {
                    $q_irc->enqueue(['db', 'print', "[poll] Upcoming: $repo/$pkg is different in overlay, current: $db_pkgver-$db_pkgrel, new: $pkgver-$pkgrel"]);
                    $hold = 1;
                } elsif ($db_override == 1) {
                    $q_irc->enqueue(['db', 'print', "[poll] Override: $repo/$pkg, current: $db_pkgver-$db_pkgrel, new: $pkgver-$pkgrel"]);
                    $self->{dbh}->do("delete from queue where path = ?", undef, $path);
                    next;
                } elsif ("$pkgver-$pkgrel" eq "$db_pkgver-$db_pkgrel_stripped") {
                    $q_irc->enqueue(['db', 'print', "[poll] Detected upstream updates to overlay package with no version bump for $repo/$pkg"]);
                    $self->{dbh}->do("delete from queue where path = ?", undef, $path);
                    next;
                }
            }
        }
        # update queue data
        $self->{dbh}->do("update queue set ref = 1, hold = ?, pkgname = ?, repo = ?, provides = ?, pkgver = ?, pkgrel = ?, depends = ?, makedepends = ?, skip = ?, noautobuild = ?, highmem = ? where path = ?",
                         undef, $hold, $pkgname, $repo, $provides, $pkgver, $pkgrel, $depends, $makedepends, $buildarch, $noautobuild, $highmem, $path);
    }
    
    # bring queue items ref > 1 back to 1 for possible processing next round
    $self->{dbh}->do("update queue set ref = 1 where ref > 1");
}

# process queued packages
sub process {
    my $self = shift;
    my $workroot = $self->{packaging}->{workroot};
    my %priority = ( 'core'         => 10,  # default importance (package selection priority)
                     'extra'        => 20,
                     'community'    => 30,
                     'aur'          => 40,
                     'alarm'        => 50 );
    
    # halt all architectures
    #$q_svc->enqueue(['db', 'stop', 'all']);
    print "[process] halting all architectures\n";
    
    # match holds to git updates, delete upstream holds if satisfied in overlay
    my $rows = $self->{dbh}->selectall_arrayref("select path, queue.repo, queue.package, queue.pkgver, queue.pkgrel, abs.pkgver, abs.pkgrel, queue.skip, override, group_concat(arch) from queue left outer join architectures on queue.skip & architectures.skip > 0 inner join abs on queue.package = abs.package where ref = 1 and hold = 1 group by queue.package");
    my $hold_total = 0;
    foreach my $row (@$rows) {
        my ($path, $repo, $pkg, $pkgver, $pkgrel, $db_pkgver, $db_pkgrel, $skip, $override, $hold_arches) = @$row;
        my ($git_path, $git_pkg, $git_repo, $git_pkgver, $git_pkgrel) = $self->{dbh}->selectrow_array("select path, package, repo, pkgver, pkgrel from queue where type = 'git' and ref = 1 and package = ?", undef, $pkg);
        if (defined $git_pkg) {
            print "[process] matched git package found for $pkg, determining hold status\n";
            
            # ALARM pkgrel bumps are tracked as fractional pkgrel numbers, strip that to determine actual differences
            my $git_pkgrel_stripped = $git_pkgrel;
            $git_pkgrel_stripped =~ s/\.+.*//;
            
            if ("$pkgver-$pkgrel" ne "$git_pkgver-$git_pkgrel_stripped") {
                $q_irc->enqueue(['db', 'print', "[process] Holding $repo/$pkg, version mismatch, overlay: $git_pkgver-$git_pkgrel_stripped, new: $pkgver-$pkgrel"]);
                $self->{dbh}->do("delete from queue where path = ?", undef, $git_path);     # remove bad overlay package from the queue, must be re-committed anyway
            } elsif ($git_repo ne $repo) {
                $q_irc->enqueue(['db', 'print', "[process] Holding $repo/$pkg, repo mismatch, overlay: $git_repo, new: $repo"]);
                $self->{dbh}->do("delete from queue where path = ?", undef, $git_path);     # remove bad overlay package from the queue, must be re-committed anyway
            } else {
                $q_irc->enqueue(['db', 'print', "[process] Removing hold on $repo/$pkg, overlay matches"]);
                print "[process] removing upstream package $pkg since overlay is good\n";
                $self->{dbh}->do("delete from queue where path = ?", undef, $path);         # remove held upstream package from the queue, allows overlay package to go through processing
            }
        } elsif ($override == 1) {
            print "[process] new override on $pkg, dropping hold\n";
            $q_irc->enqueue(['db', 'print', "[process] Override: $repo/$pkg, current: $db_pkgver-$db_pkgrel, new: $pkgver-$pkgrel"]);
            $self->{dbh}->do("delete from queue where path = ?", undef, $path);
        } else {
            $hold_total |= int($skip);  # calculate arches to hold, used at the end
            $q_irc->enqueue(['db', 'print', "[process] Holding $repo/$pkg, current: $db_pkgver-$db_pkgrel, new: $pkgver-$pkgrel, blocking: $hold_arches"]);
        }
    }
    
    # process non-holds into abs and arch tables
    $rows = $self->{dbh}->selectall_arrayref("select * from queue where ref = 1 and hold = 0");
    foreach my $row (@$rows) {
        my ($type,$path,$ref,$hold,$del,$pkg,$repo,$pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends,$skip,$noautobuild,$highmem) = @$row;
        
        # handle deleted package
        if ($del == 1) {
            my ($db_id, $db_git, $db_abs) = $self->{dbh}->selectrow_array("select id, git, abs from abs where package = ?", undef, $pkg);
            if (-d $path) {                 # not actually deleted, reprocess
                $self->{dbh}->do("update queue set ref = 0, del = 0 where path = ?", undef, $path);
                next;
            }
            if ($type eq 'abs') {
                if ($db_git == 1) {         # warn us that upstream has trashed something we track, adjust abs flag
                    $q_irc->enqueue(['db', 'print', "[process] Upstream has removed $repo/$pkg, also tracked in overlay"]);
                    #$self->{dbh}->do("update abs set abs = 0 where package = ?", undef, $pkg);
                    print "[process] mysql: update abs set abs = 0 where package = $pkg\n";
                } else {                    # otherwise trash the package
                    $q_irc->enqueue(['db', 'print', "[process] Deleting $repo/$pkg (upstream)"]);
                    #$self->{dbh}->do("update abs set abs = 0, del = 1 where package = ?", undef, $pkg);
                    #$self->{dbh}->do("delete from names where package = ?", undef, $db_id);
                    #$self->{dbh}->do("delete from deps where id = ?", undef, $db_id);
                    print "[process] mysql: update abs set abs = 0, del = 1 where package = $pkg, delete from names/deps where id = $db_id\n";
                    foreach my $arch (keys %{$self->{arch}}) {
                        #$self->pkg_prep($arch, { pkgbase => $pkg });
                        print "[process] deleting $arch/$pkg\n";
                    }
                }
            } elsif ($type eq 'git') {
                if ($db_abs == 1) {         # switch to abs, no rebuilding but remove any holds to release upstream replacement
                    my ($abs_hold) = $self->{dbh}->selectrow_array("select hold from queue where ref = 1 and hold = 1 and type = 'abs' and package = ?", undef, $pkg);
                    if (defined $abs_hold && $abs_hold == 1) {
                        $self->{dbh}->do("update queue set hold = 0 where type = 'abs' and package = ?", undef, $pkg);
                        $q_irc->enqueue(['db', 'print', "[process] Removing hold on $repo/$pkg, overlay version deleted"]);
                    } else {
                        $q_irc->enqueue(['db', 'print', "[process] Removed overlay of $repo/$pkg, using upstream package"]);
                    }
                    #$self->{dbh}->do("update abs set git = 0 where package = ?", undef, $pkg);
                    print "[process] mysql: update abs set git = 0 where package = $pkg\n";
                } else {                    # otherwise, trash the package
                    $q_irc->enqueue(['db', 'print', "[process] Deleting $repo/$pkg (overlay)"]);
                    #$self->{dbh}->do("update abs set git = 0, abs = 0, del = 1 where package = ?", undef, $pkg);
                    #$self->{dbh}->do("delete from names where package = ?", undef, $db_id);
                    #$self->{dbh}->do("delete from deps where id = ?", undef, $db_id);
                    print "[process] mysql: update abs set git = 0, abs = 0, del = 1 where package = $pkg, delete from names/deps where id = $db_id\n";
                    foreach my $arch (keys %{$self->{arch}}) {
                        #$self->pkg_prep($arch, { pkgbase => $pkg });
                        print "[process] deleting $arch/$pkg\n";
                    }
                }
            }
            $self->{dbh}->do("delete from queue where path = ?", undef, $path);
            next;
        }
        
        # update abs and arch tables if newer
        my ($db_id, $db_repo, $db_pkgver, $db_pkgrel, $db_git, $db_abs, $db_skip, $db_highmem, $db_importance) = $self->{dbh}->selectrow_array("select id, repo, pkgver, pkgrel, git, abs, skip, highmem, importance from abs where package = ?", undef, $pkg);
        my $importance = $priority{$repo};  # set importance
        
        # create work unit
        if ($type eq 'abs') {
            my ($strip) = $path =~ /.*\/([^\/]*)$/;
            #`tar -zcf "$workroot/$repo-$pkg.tgz" -C "$path/.." "$strip" --transform 's,^$strip,$pkg,' > /dev/null`;
            print "[process] work unit: tar -zcf \"$workroot/$repo-$pkg.tgz\" -C \"$path/..\" \"$strip\" --transform 's,^$strip,$pkg,' > /dev/null\n";
        } elsif ($type eq 'git') {
            my ($strip) = $path =~ /(.*)\/[^\/]*$/;
            #`tar -zcf "$workroot/$repo-$pkg.tgz" -C "$strip" "$pkg" > /dev/null`;
            print "[process] work unit: tar -zcf \"$workroot/$repo-$pkg.tgz\" -C \"$strip\" \"$pkg\" > /dev/null\n";
        }
        
        # relocate package if repo has changed
        if (defined $db_repo && $db_repo ne $repo) {
            print "[process] relocating $db_repo/$pkg to $repo\n";
            #$self->pkg_relocate($pkg, $repo);
        }
        
        # update abs table
        my $is_git = $type eq 'git' ? 1 : $db_git;
        my $is_abs = $type eq 'abs' ? 1 : $db_abs;
        my $is_skip = $type eq 'git' ? $skip : defined $db_skip ? $db_skip : 1;
        my $is_highmem = $type eq 'git' ? $highmem : defined $db_highmem ? $db_highmem : 0;
        my $is_done = $noautobuild ? 1 : 0; # noautobuild set, assume built, done = 1
        
        #$self->{dbh}->do("insert into abs (package, repo, pkgname, provides, pkgver, pkgrel, depends, makedepends, git, abs, skip, highmem, del, importance) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
        #                  on duplicate key update repo = ?, pkgname = ?, provides = ?, pkgver = ?, pkgrel = ?, depends = ?, makedepends = ?, git = ?, abs = ?, skip = ?, highmem = ?, del = 0, importance = ?",
        #                  undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends, $is_git, $is_abs, $is_skip, $is_highmem, $importance, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends, $is_git, $is_abs, $is_skip, $is_highmem, $importance);
        print "[process] update abs: $repo/$pkg $pkgver-$pkgrel, git: $is_git, abs: $is_abs skip: $is_skip, highmem: $is_highmem, importance: $importance\n";
        
        # new package, different version, update, done = 0
        if (! defined $db_pkgver || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel") {
            print "[process] $repo/$pkg to $pkgver-$pkgrel\n";
            
            # update architecture tables
            foreach my $arch (keys %{$self->{arch}}) {
                next unless ($self->{skip}->{$arch} & $is_skip);    # don't update skipped architectures
                #$self->{dbh}->do("insert into $arch (id, done, fail) values (?, 0, 0) on duplicate key update done = 0, fail = 0", undef, $db_id);
                print "[process] setting done = 0, fail = 0 on $arch table\n";
            }
        } else {
            foreach my $arch (keys %{$self->{arch}}) {
                my ($fail) = $self->{dbh}->selectrow_array("select fail from $arch where id = ?", undef, $db_id);
                if ($fail == 1) {
                    #$self->{dbh}->do("insert into $arch (id, done, fail) values (?, 0, 0) on duplicate key update done = 0, fail = 0", undef, $db_id);
                    print "[process] detected updates without version bump, unfailing $arch/$pkg\n";
                }
            }
        }
        
        # update dependency tables
        ($db_id) = $self->{dbh}->selectrow_array("select id from abs where package = ?", undef, $pkg);
        #$self->{dbh}->do("delete from names where package = ?", $db_id);
        #$self->{dbh}->do("delete from deps where id = ?", $db_id);
        print "[process] $pkg: delete from names/deps there package/id = $db_id\n";
        my @names = split(/ /, join(' ', $pkgname, $provides));
        my %deps;
        
        # insert package names and provides
        foreach my $name (@names) {
            $name =~ s/(<|=|>).*//;
            next if ($name eq "");
            #$self->{dbh}->do("insert into names values (?, ?)", undef, $name, $db_id);
        }
        print "[process] $pkg names: $pkgname $provides\n";
        
        # insert package dependencies
        if ($depends && $makedepends) {
            $depends = "" unless $depends;
            $makedepends = "" unless $makedepends;
            foreach my $name (split(/ /, join(' ', $depends, $makedepends))) {
                $name =~ s/(<|=|>).*//;
                next if ($name eq "");
                next if (grep {$_ eq $name} @names);
                $deps{$name} = 1;
            }
            #foreach my $dep (keys %deps) {
            #    $self->{dbh}->do("insert into deps values (?, ?)", undef, $id, $dep);
            #}
            print "[process] $pkg deps: $depends $makedepends\n";
        }
        
        # remove package from queue
        $q_irc->enqueue(['db', 'print', "[process] ($type) $repo/$pkg to $pkgver-$pkgrel"]);
        $self->{dbh}->do("delete from queue where path = ?", undef, $path);
    }
    
    # start architectures without holds
    foreach my $arch (keys %{$self->{arch}}) {
        next if ($self->{skip}->{$arch} & $hold_total);
        my ($ready) = $self->{dbh}->selectrow_array("select count(*) from (
            select p.repo, p.package, p.depends, p.makedepends from abs as p
            join $arch as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
            left outer join (select d.id as id, max(done) as done from deps as d inner join names as n on (n.name = d.dep) inner join $arch as a on (a.id = n.package) group by id, name) as d on (d.id = p.id)
            where p.skip & ? > 0 and p.del = 0 group by p.id having (count(d.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) )
            ) as xx", undef, $self->{skip}->{$arch});
        if ($ready > 0) {
            #$q_svc->enqueue(['db', 'start', $arch]);
            print "[process] starting $arch\n";
        }
    }
    
    # push start
    #$q_svc->enqueue(['db', 'push']);
    print "[process] starting available builders\n";
}

# update database with new packages from git and ABS
sub update {
    my $self = shift;
    my (%gitlist, %abslist, %newlist, %dellist);
    my $gitroot = $self->{packaging}->{git}->{root};
    my $absroot = $self->{packaging}->{abs}->{root};
    my $workroot = $self->{packaging}->{workroot};
    my $archbin = $self->{packaging}->{archbin};
    
    my %priority = ( 'core'         => 10,  # default importance (package selection priority)
                     'extra'        => 20,
                     'community'    => 30,
                     'aur'          => 40,
                     'alarm'        => 50 );
    
    $q_irc->enqueue(['db', 'print', 'Updating git..']);
    print "update git..\n";
    system("pushd $gitroot; git pull; popd");
    
    # add/update git packages
    print "update git packages..\n";
    my $git_count = 0;
    foreach my $repo (@{$self->{packaging}->{git}->{repos}}) {
        foreach my $pkg (glob("$gitroot/$repo/*")) {
            next unless (-d $pkg);  # skip non-directories
            $pkg =~ s/^\/.*\///;    # strip leading path
            
            $gitlist{$pkg} = 1;
            my ($db_repo, $db_pkgver, $db_pkgrel, $db_plugrel, $db_importance) = $self->{dbh}->selectrow_array("select repo, pkgver, pkgrel, plugrel, importance from abs where package = ?", undef, $pkg);
            $db_plugrel = $db_plugrel || "0";
            my $vars = `./pkgsource.sh $gitroot $repo $pkg`;
            chomp($vars);
            my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends,$buildarch,$noautobuild,$highmem) = split(/\|/, $vars);
            
            # skip a bad source
            next unless (defined $pkgver);
            
            # set/reset plugrel
            my $plugrel;
            if (defined $db_plugrel && "$pkgver-$pkgrel" eq "$db_pkgver-$db_pkgrel") {
                $plugrel = $db_plugrel;
            } else {
                $plugrel = 0;
            }
            
            # set importance
            my $importance = $priority{$repo};
            
            # relocate package if repo has changed
            if (defined $db_repo && $db_repo ne $repo) {
                print "relocating $db_repo/$pkg to $repo\n";
                $self->pkg_relocate($pkg, $repo);
            }
            
            # update abs table regardless of new version
            $self->{dbh}->do("insert into abs (package, repo, pkgname, provides, pkgver, pkgrel, plugrel, depends, makedepends, git, abs, skip, highmem, del, importance) values (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, 0, ?)
                              on duplicate key update repo = ?, pkgname = ?, provides = ?, pkgver = ?, pkgrel = ?, plugrel = ?, depends = ?, makedepends = ?, git = 1, abs = 0, skip = ?, highmem = ?, del = 0, importance = ?",
                              undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $plugrel, $depends, $makedepends, $buildarch, $highmem, $importance, $repo, $pkgname, $provides, $pkgver, $pkgrel, $plugrel, $depends, $makedepends, $buildarch, $highmem, $importance);
            
            # create work unit package regardless of new version
            `tar -zcf "$workroot/$repo-$pkg.tgz" -C "$gitroot/$repo" "$pkg" > /dev/null`;
            
            # new package, different plugrel or version, done = 0
            next unless (! defined $db_pkgver || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel");
            
            # if new, add to list
            $newlist{$pkg} = 1 if (! defined $db_pkgver);
            
            # noautobuild set, assume built, done = 1
            my $is_done = 0;
            $is_done = 1 if ($noautobuild);
            print "$repo/$pkg to $pkgver-$pkgrel-plug$plugrel, done = $is_done\n";
            
            # update architecture tables
            my ($db_id) = $self->{dbh}->selectrow_array("select id from abs where package = ?", undef, $pkg);
            foreach my $arch (keys %{$self->{arch}}) {
                $self->{dbh}->do("insert into $arch (id, done, fail) values (?, ?, 0)
                                  on duplicate key update done = ?, fail = 0",
                                  undef, $db_id, $is_done, $is_done);
            }
            $git_count++;
        }
    }
    
    # add/update abs packages
    $q_irc->enqueue(['db', 'print', 'Updating abs..']);
    print "update abs packages..\n";
    my $abs_count = 0;
    `ABSROOT=$absroot $archbin/abs`;
    foreach my $repo (@{$self->{packaging}->{abs}->{repos}}) {
        foreach my $pkg (glob("$absroot/$repo/*")) {
            next unless (-d $pkg);          # skip non-directories
            $pkg =~ s/^\/.*\///;            # strip leading path
            next if ($pkg =~ /.*\-lts$/);   # skip Arch LTS packages
            
            $abslist{$pkg} = 1;
            my ($db_repo, $db_pkgver, $db_pkgrel, $db_skip, $db_highmem, $db_importance) = $self->{dbh}->selectrow_array("select repo, pkgver, pkgrel, skip, highmem, importance from abs where package = ?", undef, $pkg);
            my $vars = `./pkgsource.sh $absroot $repo $pkg`;
            chomp($vars);
            my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends) = split(/\|/, $vars);
            if ($gitlist{$pkg}) {
                # ALARM pkgrel bumps are tracked as added decimal numbers, strip that to determine actual differences
                my $db_pkgrel_stripped = $db_pkgrel;
                $db_pkgrel_stripped =~ s/\.+.*//;
                if ("$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel_stripped") {
                    $q_irc->enqueue(['db','print',"$pkg is different in git, git = $db_pkgver-$db_pkgrel, abs = $pkgver-$pkgrel"]);
                }
                if ($db_repo ne $repo) {
                    $q_irc->enqueue(['db', 'print', "$pkg has been relocated in ABS, git = $db_repo, abs = $repo"]);
                }
                # git transition: set abs = 1 on git packages that have an abs counterpart
                $self->{dbh}->do("update abs set abs = 1 where package = ?", undef, $pkg);
                next;
            }
            
            # skip a bad source
            next unless (defined $pkgver);
            
            # create work unit here for non-skipped and new packages, to repackage abs changes without ver-rel bump
            if ((defined $db_skip && $db_skip > 0) || (! defined $db_skip)) {
                `tar -zcf "$workroot/$repo-$pkg.tgz" -C "$absroot/$repo" "$pkg" > /dev/null`;
            }
            
            # if new, add to list
            $newlist{$pkg} = 1 if (! defined $db_pkgver);
            
            # set importance
            my $importance = $priority{$repo};
            
            # relocate package if repo has changed
            if (defined $db_repo && $db_repo ne $repo) {
                print "relocating $db_repo/$pkg to $repo\n";
                $self->pkg_relocate($pkg, $repo);
            }
            
            # update abs table
            my $is_skip = defined $db_skip ? $db_skip : 1;
            my $is_highmem = defined $db_highmem ? $db_highmem : 0;
            $self->{dbh}->do("insert into abs (package, repo, pkgname, provides, pkgver, pkgrel, depends, makedepends, git, abs, skip, highmem, del, importance) values (?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?, ?, 0, ?)
                              on duplicate key update repo = ?, pkgname = ?, provides = ?, pkgver = ?, pkgrel = ?, depends = ?, makedepends = ?, git = 0, abs = 1, skip = ?, highmem = ?, del = 0, importance = ?",
                              undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends, $is_skip, $is_highmem, $importance, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends, $is_skip, $is_highmem, $importance);
            
            # new package, different version, update, done = 0
            next unless (! defined $db_pkgver || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel");
            print "$repo/$pkg to $pkgver-$pkgrel\n";
            
            # update architecture tables
            my ($db_id) = $self->{dbh}->selectrow_array("select id from abs where package = ?", undef, $pkg);
            foreach my $arch (keys %{$self->{arch}}) {
                $self->{dbh}->do("insert into $arch (id, done, fail) values (?, 0, 0) on duplicate key update done = 0, fail = 0", undef, $db_id);
            }
            $abs_count++;
        }
    }
    
    # build package deletion list
    my $rows = $self->{dbh}->selectall_arrayref("select package, git, abs from abs where del = 0");
    foreach my $row (@$rows) {
        my ($pkg, $git, $abs) = @$row;
        next if ($git && $gitlist{$pkg});
        next if ($abs && $abslist{$pkg});
        print "del flag on $pkg\n";
        $dellist{$pkg} = 1;
    }
    
    $q_irc->enqueue(['db', 'print', "Updated $git_count from git, $abs_count from abs. " . scalar(keys %newlist)  . " new, " . scalar(keys %dellist) . " removed."]);
    
    # switch on deletion limit
    if (scalar(keys %dellist) > 10) {
        $self->{dellist} = \%dellist;
        $self->{newlist} = \%newlist;
        $q_irc->enqueue(['db', 'print', "Warning: " . scalar(keys %dellist) . " packages to be deleted : !review and/or !continue"]);
    } else {
        $self->update_continue(\%dellist);
    }
}

# complete the update with package purging and dependency table rebuilding
sub update_continue {
    my ($self, $list) = @_;
    my %dellist;
    
    # use the list provided or pull from self after warning
    if (defined $list) {
        %dellist = %{$list};
    } elsif (defined $self->{dellist}) {
        %dellist = %{$self->{dellist}};
        undef $self->{dellist};
        undef $self->{newlist};
    }
    
    # prune abs table of deleted packages, remove repo files
    foreach my $pkg (keys %dellist) {
        $self->{dbh}->do("update abs set del = 1 where package = ?", undef, $pkg);
        foreach my $arch (keys %{$self->{arch}}) {
            $self->pkg_prep($arch, { pkgbase => $pkg });
        }
    }
    
    # build new dep tables
    $q_irc->enqueue(['db', 'print', "Building dependencies.."]);
    my $rows = $self->{dbh}->selectall_arrayref("select id, pkgname, provides, depends, makedepends from abs where del = 0 and skip != 0");
    $self->{dbh}->do("delete from names");
    $self->{dbh}->do("delete from deps");
    foreach my $row (@$rows) {
        my ($id, $pkgname, $provides, $depends, $makedepends) = @$row;
        my @names = split(/ /, join(' ', $pkgname, $provides));
        my %deps;
        
        # build names table
        foreach my $name (@names) {
            $name =~ s/(<|=|>).*//;
            next if ($name eq "");
            $self->{dbh}->do("insert into names values (?, ?)", undef, $name, $id);
        }
        
        # build deps table
        next if (!$depends && !$makedepends);
        $depends = "" unless $depends;
        $makedepends = "" unless $makedepends;
        foreach my $name (split(/ /, join(' ', $depends, $makedepends))) {
            $name =~ s/(<|=|>).*//;
            next if ($name eq "");
            next if (grep {$_ eq $name} @names);
            $deps{$name} = 1;
        }
        foreach my $dep (keys %deps) {
            $self->{dbh}->do("insert into deps values (?, ?)", undef, $id, $dep);
        }
    }
    $q_irc->enqueue(['db', 'print', "Update complete."]);
}

# print out packages to review for large package removal from ABS
sub review {
    my $self = shift;
    my %newlist = %{$self->{newlist}};
    my %dellist = %{$self->{dellist}};
    my $new = '';
    my $del = '';
    
    foreach my $pkg (keys %newlist) {
        $new .= " $pkg";
    }
    foreach my $pkg (keys %dellist) {
        $del .= " $pkg";
    }
    $q_irc->enqueue(['db', 'print', scalar(keys %newlist) . " new:$new"]);
    $q_irc->enqueue(['db', 'print', scalar(keys %dellist) . " deleted:$del"]);
}

# check AUR package versions
sub aur_check {
    my ($self) = shift;
    my (%aurlist, @request);
    
    push @request, 'http://aur.archlinux.org/rpc.php?type=multiinfo';
    my $rows = $self->{dbh}->selectall_arrayref("select package, pkgver, pkgrel from abs where repo = 'aur' and del = 0");
    foreach my $row (@$rows) {
        my ($pkg, $pkgver, $pkgrel) = @$row;
        $aurlist{$pkg} = "$pkgver-$pkgrel";
        push @request, "arg[]=$pkg";
    }
    my $aur_response = HTTP::Tiny->new->get(join('&', @request));   # send JSON RPC request
    my $aur_json = decode_json($aur_response->{content});           # decode json from HTTP reply
    if ($aur_json->{type} eq "error") {                             # error, results is a string
        print " ---> Error retrieving AUR package information: $aur_json->{results}\n";
    } else {                                                        # all good, results is an array of dictionaries
        foreach my $pkg (@{$aur_json->{results}}) {
            if ($aurlist{$pkg->{Name}} ne $pkg->{Version}) {
                $q_irc->enqueue(['db','print',"$pkg->{Name} is different in git, git = $aurlist{$pkg->{Name}}, aur = $pkg->{Version}"]);
                delete $aurlist{$pkg->{Name}};
            } elsif ($aurlist{$pkg->{Name}}) {
                delete $aurlist{$pkg->{Name}};                      # version checks, remove from list
            }
        }
        if (scalar(keys %aurlist)) {
            my @not_tracked;
            foreach my $pkg (keys %aurlist) {
                push @not_tracked, $pkg;
            }
            $q_irc->enqueue(['db','print',"Packages in AUR repo, but not in AUR: " . join(' ', @not_tracked)]);
        }
    }
}

1;
