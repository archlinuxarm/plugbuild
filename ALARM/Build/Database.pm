#!/usr/bin/perl -w
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

our ($q_svc, $q_db, $q_irc, $q_mir);

sub new{
    my ($class, $config) = @_;
    
    my $self = $config;
    $self->{dbh}=undef;
    
    bless $self, $class;
    return $self;
}


sub Run{
    my $self = shift;
    my $requests = -1;
    print "DbRun\n";
    
    my $open = $self->connect;
    
    # skip bitmasks
    #  - 0000 = skip package, do not build
    #  - 0001 = build all architectures
    #  - 0010 = build for armv5 only
    #  - 0100 = build for armv7 only
    $self->{skip}->{armv5} = 3;     # 0b0011
    $self->{skip}->{armv7} = 5;     # 0b0101
    
    # thread queue loop
    while (my $orders = $q_db->dequeue) {
        my ($from,$order) = @{$orders};
        print "DB: got $order from $from\n";
        if($order eq "quit"){
            $available->down_force(10);
            last;
        }
        if( $order eq 'recycle'){
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
                my @force = $self->{dbh}->selectrow_array("select done, repo from $arch as a inner join abs on (a.id = abs.id) where package = ?", undef, $pkg);
                if (!defined $force[0]) {
                    $q_irc->enqueue(['db', 'print', "[force] Package $pkg not found."]);
                } elsif ($force[0] eq "1") {
                    $q_irc->enqueue(['db', 'print', "[force] Package $pkg is already done for $arch."]);
                } else {
                    $q_svc->enqueue(['db', 'force', { command => 'next', arch => "$arch", repo => $force[1], pkgbase => $pkg }]);
                }
            }
            case "info" {
                $self->pkg_info(@{$orders}[2]);
            }
            case "percent_done" {
                my $table = @{$orders}[2];
                my ($v5, $v7, $count) = @{$self->done()};
                $q_irc->enqueue(['db','print',"Successful builds: ARMv5: $v5 of $count, ".sprintf("%0.2f%%",($v5/$count)*100)." | ARMv7: $v7 of $count, ".sprintf("%0.2f%%",($v7/$count)*100)]);
            }
            case "percent_failed" {
                my $table = @{$orders}[2];
                my ($v5, $v7, $count) = @{$self->failed()};
                $q_irc->enqueue(['db','print',"Failed builds: ARMv5: $v5 of $count, ".sprintf("%0.2f%%",($v5/$count)*100)." | ARMv7: $v7 of $count, ".sprintf("%0.2f%%",($v7/$count)*100)]);
            }
            case "prune" {
                my $pkg = @{$orders}[2];
                $self->{dbh}->do("update armv5 as a inner join abs on (a.id = abs.id) set done = 0, fail = 0 where package = ?", undef, $pkg);
                $self->{dbh}->do("update armv7 as a inner join abs on (a.id = abs.id) set done = 0, fail = 0 where package = ?", undef, $pkg);
                $self->pkg_prep('armv5', { pkgbase => $pkg });
                $self->pkg_prep('armv7', { pkgbase => $pkg });
            }
            case "ready" {
                if (defined @{$orders}[2]) {
                    my $target = @{$orders}[2];
                    my ($detail,$which) = split(/\s/,$target);
                    if ($target eq 'detail' || $detail eq 'detail') {
                        my $ready = $self->ready_detail($which);
                        $q_irc->enqueue(['db','print',sprintf("Packages waiting to be built: %d",$ready->[0])]);
                        if( $ready->[0] >= 1) {
                            $q_irc->enqueue(['db','print',sprintf("Packages waiting: %s",$ready->[1])]);
                        }
                    }
                } else {
                    my $ready = $self->ready();
                    if( defined($ready->[0]) ){
                        $q_irc->enqueue(['db','print',"Packages waiting to be built: ARMv5: $ready->[0], ARMv7: $ready->[1]"]);
                    }else{
                        $q_irc->enqueue(['db','print','ready: unknown error.']);
                    }
                }
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
            case "skip" {
                $self->pkg_skip(@{$orders}[2], 0);
            }
            case "status" {
                my ($arch, $package) = split(/ /, @{$orders}[2], 2);
                $self->status($arch, $package);
            }
            case "unfail" {
                my ($arch, $package) = split(/ /, @{$orders}[2], 2);
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
                my ($arch, $builder) = @{$orders}[2,3];
                my $next = $self->get_next_package($arch, $builder);
                if ($next) {
                    $self->pkg_work(@{$next}[1], $arch, $builder);
                    $q_svc->enqueue(['db', 'next', $arch, $builder, { command => 'next', arch => $arch, repo => $next->[0], pkgbase => $next->[1] }]);
                } else {
                    $q_svc->enqueue(['db', 'next', $arch, $builder, { command => 'next', pkgbase => "FAIL" }]);
                }
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

sub disconnect {
    my ($self) = @_;
    if( defined($self->{dbh}) ){
        $self->{dbh}->disconnect;
        $available->up;
        $self->{dbh} = undef;
    }
}

sub get_next_package {
    my ($self, $arch, $builder) = @_;
    if (defined($self->{dbh})) {
    	$self->{dbh}->do("update $arch set builder = null where builder = ?", undef, $builder);
        my @next_pkg = $self->{dbh}->selectrow_array("select
            p.repo, p.package, p.depends, p.makedepends
            from abs as p
            join $arch as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
            left outer join (select dp.package as id, max(done) as done from package_depends as dp inner join package_name_provides as pn on (dp.nid = pn.id) inner join $arch as a on (a.id = pn.package) group by id, name) as d on (d.id = p.id)
            where p.skip & ? > 0 and p.del = 0
            group by p.id
            having (count(d.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) ) order by p.importance limit 1",
            undef, $self->{skip}->{$arch});
        return undef if (!$next_pkg[0]);
        return \@next_pkg;
    } else {
        return undef;
    }
}

sub ready {
    my $self = shift;
    
    if (defined($self->{dbh})) {
        my @next_pkg5 = $self->{dbh}->selectrow_array("select count(*) from (
            select
                p.repo, p.package, p.depends, p.makedepends
                from
                abs as p
                    join armv5 as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
                    left outer join (select dp.package as id, max(done) as done from package_depends as dp inner join package_name_provides as pn on (dp.nid = pn.id) inner join armv5 as a on (a.id = pn.package) group by id, name) as d on (d.id = p.id)
                where p.skip & ? > 0 and p.del = 0  
                group by p.id
                having (count(d.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) )
            ) as xx", undef, $self->{skip}->{armv5});
        my @next_pkg7 = $self->{dbh}->selectrow_array("select count(*) from (
            select
                p.repo, p.package, p.depends, p.makedepends
                from
                abs as p
                    join armv7 as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
                    left outer join (select dp.package as id, max(done) as done from package_depends as dp inner join package_name_provides as pn on (dp.nid = pn.id) inner join armv7 as a on (a.id = pn.package) group by id, name) as d on (d.id = p.id)
                where p.skip & ? > 0 and p.del = 0  
                group by p.id
                having (count(d.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) )
            ) as xx", undef, $self->{skip}->{armv7});
        return undef if (!defined($next_pkg5[0]) && !defined($next_pkg7[0]));
        return [$next_pkg5[0], $next_pkg7[0]];
    } else {
        return undef;
    }
}

sub ready_detail {
    my $self = shift;
    my $arch = shift||5;
    
    $arch = (Scalar::Util::looks_like_number($arch))?$arch:5;
    $arch = 'armv'.$arch;
    my $rows = $self->{dbh}->selectall_arrayref("select
        p.repo, p.package, p.depends, p.makedepends
        from
        abs as p
        join $arch as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
        left outer join (select dp.package as id, max(done) as done from package_depends as dp inner join package_name_provides as pn on (dp.nid = pn.id) inner join $arch as a on (a.id = pn.package) group by id, name) as d on (d.id = p.id)
        where p.skip & ? > 0 and p.del = 0
        group by p.id
        having (count(d.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) ) order by p.importance",
        undef, $self->{skip}->{$arch});
	my $res = undef;
	my $cnt = 0;
	foreach my $row (@$rows) {
        my ($repo, $package) = @$row;
	    $res .= sprintf("%s/%s, ", $repo, $package);
	    $cnt++;
	}
    $res =~ s/, $//;
	return [$cnt,$res];
}

sub count {
    my $self = shift;
    
    my $data = shift;
    print "DB-Count $data\n";
    my $ret = ($self->{dbh}->selectrow_array("select count(*) from $data"))[0] || 0;
    print "DB-Count $data : $ret\n";
    return $ret;
}

sub done {
    my $self = shift;
    my $armv5 = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv5 on (armv5.id = abs.id) where done = 1 and fail = 0 and skip & ? > 0 and del = 0", undef, $self->{skip}->{armv5}))[0] || 0;
    my $armv7 = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv7 on (armv7.id = abs.id) where done = 1 and fail = 0 and skip & ? > 0 and del = 0", undef, $self->{skip}->{armv7}))[0] || 0;
    my $abs = ($self->{dbh}->selectrow_array("select count(*) from abs where skip != 0 and del = 0"))[0] || 0;
    return [$armv5, $armv7, $abs];
}

sub failed {
    my $self = shift;
    my $armv5 = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv5 on (armv5.id = abs.id) where fail = 1 and skip & ? > 0 and del = 0", undef, $self->{skip}->{armv5}))[0] || 0;
    my $armv7 = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv7 on (armv7.id = abs.id) where fail = 1 and skip & ? > 0 and del = 0", undef, $self->{skip}->{armv7}))[0] || 0;
    my $abs = ($self->{dbh}->selectrow_array("select count(*) from abs where skip != 0 and del = 0"))[0] || 0;
    return [$armv5, $armv7, $abs];
}

sub status {
    my ($self, $package) = @_;
    if(defined($package) && $package ne '') {
        foreach my $arch ('armv5', 'armv7') {
            my $ar = $self->{dbh}->selectall_arrayref("select package, pkgname, repo, pkgver, pkgrel, done, fail, builder, git, abs, skip, del from abs inner join $arch as a on (abs.id = a.id) where package = ?", undef, $package);
            if( scalar(@{$ar}) ){ # 1 or more
                foreach my $r (@{$ar}){
                    my ($name, $pkgname, $repo, $pkgver, $pkgrel, $done, $fail, $builder, $git, $abs, $skip, $del) = @{$r};
                    
                    my ($repover, $reporel) = $self->{dbh}->selectrow_array("select pkgver, pkgrel from files where del = 0 and arch = ? and pkgbase = ? limit 1", undef, $arch, $package);
                    if (!$repover) {
                        $repover = 0;
                        $reporel = 0;
                    }
                    my $state = (!$done && !$fail?'unbuilt':(!$done&&$fail?'failed':($done && !$fail?'done':'???')));
                    if($builder && $state eq 'unbuilt'){
                        $state = 'building';
                    }
                    $state = "skipped" if !($skip & $self->{skip}->{$arch});
                    $state = "removed" if ($del);
                    my $source = ($git&&!$abs?'git':(!$git&&$abs?'abs':'indeterminate'));
                    my $status = sprintf("[$arch] %s (%s|%s): repo=>%s, src=>%s, state=>%s", $name, "$pkgver-$pkgrel", "$repover-$reporel", $repo, $source, $state);
                    $status .= sprintf(", builder=>%s",$builder) if $state eq 'building';
                    
                    my $names;
                    foreach my $name (split(/ /, $pkgname)) {
                        $names .= "'$name', ";
                    }
                    $names =~ s/, $//;
                    my $blocklist = $self->{dbh}->selectall_arrayref("select abs.repo, abs.package, arm.fail, abs.skip, abs.del from package_name_provides as pn
                                                                     inner join package_depends as pd on (pn.package = pd.package)
                                                                     inner join package_name_provides as pnp on (pd.nid = pnp.id)
                                                                     inner join $arch as arm on (pd.dependency = arm.id)
                                                                     inner join abs on (arm.id = abs.id)
                                                                     where pn.name in ($names) group by pnp.name having max(done) = 0");
                    if (scalar(@{$blocklist})) {
                        $status .= ", blocked on: ";
                        foreach my $blockrow (@$blocklist) {
                            my ($blockrepo, $blockpkg, $blockfail, $blockskip, $blockdel) = @$blockrow;
                            $status .= sprintf("%s/%s (%s) ", $blockrepo, $blockpkg, $blockdel?"D":!$blockskip?"S":$blockfail?"F":"N");
                        }
                    }
                    $q_irc->enqueue(['db','print',$status]);
                }
            }else{ # zilch
                $q_irc->enqueue(['db','print','could not find package \''.$package.'\'']);
                last;
            }
        }
    }
}

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
    $arch = "armv$arch";
    if ($package eq "all") {
        $rows = $self->{dbh}->do("update $arch set fail = 0, done = 0, builder = null where fail = 1");
    } else {
        $rows = $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.fail = 0, a.done = 0, a.builder = null where abs.package = ?", undef, $package);
    }
    if ($rows < 1) {
        $q_irc->enqueue(['db','print',"Couldn't unfail $package for $arch"]);
    } else {
        $q_irc->enqueue(['db','print',"Unfailed $package for $arch"]);
    }
}

# modify package to be (un)skipped
sub pkg_skip {
    my ($self, $pkg, $op) = @_;
    my $rows = $self->{dbh}->do("update abs set skip = ? where package = ?", undef, $op, $pkg);
    if ($rows < 1) {
        $q_irc->enqueue(['db','print',"Couldn't modify $pkg, check the name."]);
    } else {
        $q_irc->enqueue(['db','print',sprintf("%s %s", $op?"Unskipped":"Skipped", $pkg)]);
        if ($op) {
            $self->pkg_prep('armv5', { pkgbase => $pkg });
            $self->pkg_prep('armv7', { pkgbase => $pkg });
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

sub update {
    my $self = shift;
    my (%gitlist, %abslist, %newlist, %dellist);
    my $gitroot = $self->{packaging}->{git}->{root};
    my $absroot = $self->{packaging}->{abs}->{root};
    my $workroot = $self->{packaging}->{workroot};
    my $archbin = $self->{packaging}->{archbin};
    
    my %priority = ( 'core'         => 10,   # default importance (package selection priority)
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
            my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends,$buildarch,$noautobuild) = split(/\|/, $vars);
            
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
            $self->{dbh}->do("insert into abs (package, repo, pkgname, provides, pkgver, pkgrel, plugrel, depends, makedepends, git, abs, skip, del, importance) values (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, 0, ?)
                              on duplicate key update repo = ?, pkgname = ?, provides = ?, pkgver = ?, pkgrel = ?, plugrel = ?, depends = ?, makedepends = ?, git = 1, abs = 0, skip = ?, del = 0, importance = ?",
                              undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $plugrel, $depends, $makedepends, $buildarch, $importance, $repo, $pkgname, $provides, $pkgver, $pkgrel, $plugrel, $depends, $makedepends, $buildarch, $importance);
            
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
            $self->{dbh}->do("insert into armv5 (id, done, fail) values (?, ?, 0)
                              on duplicate key update done = ?, fail = 0",
                              undef, $db_id, $is_done, $is_done);
            $self->{dbh}->do("insert into armv7 (id, done, fail) values (?, ?, 0)
                              on duplicate key update done = ?, fail = 0",
                              undef, $db_id, $is_done, $is_done);
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
            my ($db_repo, $db_pkgver, $db_pkgrel, $db_skip, $db_importance) = $self->{dbh}->selectrow_array("select repo, pkgver, pkgrel, skip, importance from abs where package = ?", undef, $pkg);
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
            $self->{dbh}->do("insert into abs (package, repo, pkgname, provides, pkgver, pkgrel, depends, makedepends, git, abs, skip, del, importance) values (?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?, 0, ?)
                              on duplicate key update repo = ?, pkgname = ?, provides = ?, pkgver = ?, pkgrel = ?, depends = ?, makedepends = ?, git = 0, abs = 1, skip = ?, del = 0, importance = ?",
                              undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends, $is_skip, $importance, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends, $is_skip, $importance);
            
            # new package, different version, update, done = 0
            next unless (! defined $db_pkgver || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel");
            print "$repo/$pkg to $pkgver-$pkgrel\n";
            
            # update architecture tables
            my ($db_id) = $self->{dbh}->selectrow_array("select id from abs where package = ?", undef, $pkg);
            $self->{dbh}->do("insert into armv5 (id, done, fail) values (?, 0, 0) on duplicate key update done = 0, fail = 0", undef, $db_id);
            $self->{dbh}->do("insert into armv7 (id, done, fail) values (?, 0, 0) on duplicate key update done = 0, fail = 0", undef, $db_id);
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
        $self->pkg_prep('armv5', { pkgbase => $pkg });
        $self->pkg_prep('armv7', { pkgbase => $pkg });
    }
    
    # build package_name_provides
    $q_irc->enqueue(['db', 'print', "Building package names.."]);
    print "building package_name_provides..\n";
    my $rows = $self->{dbh}->selectall_arrayref("select id, pkgname, provides from abs where del = 0 and skip != 0");
    $self->{dbh}->do("delete from package_name_provides");
    foreach my $row (@$rows) {
        my ($id, $pkgname, $provides) = @$row;
        foreach my $name (split(/ /, $pkgname)) {
            $name =~ s/(<|=|>).*//;
            $self->{dbh}->do("insert into package_name_provides (name, provides, package) values (?, 0, ?)", undef, $name, $id);
        }
        if ($provides ne "") {
            foreach my $name (split(/ /, $provides)) {
                $name =~ s/(<|=|>).*//;
                $self->{dbh}->do("insert into package_name_provides (name, provides, package) values (?, 1, ?)", undef, $name, $id);
            }
        }
    }
    
    # build package_depends
    $q_irc->enqueue(['db', 'print', "Building package dependencies.."]);
    $rows = $self->{dbh}->selectall_arrayref("select id, pkgname, depends, makedepends from abs where del = 0 and skip != 0");
    $self->{dbh}->do("delete from package_depends");
    foreach my $row (@$rows) {
        my ($id, $db_pkgname, $depends, $makedepends) = @$row;
        next if (!$depends && !$makedepends);
        $depends = "" unless $depends;
        $makedepends = "" unless $makedepends;
        my @pkgname = split(/ /, $db_pkgname);
        my $statement = "insert into package_depends (dependency, package, nid) select distinct package, $id, id from package_name_provides where name in (";
        foreach my $name (split(/ /, join(' ', $depends, $makedepends))) {
            $name =~ s/(<|=|>).*//;
            next if (grep {$_ eq $name} @pkgname);
            $statement .= "'$name', ";
        }
        $statement =~ s/, $/\)/;
        $self->{dbh}->do("$statement");
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
