#!/usr/bin/perl -w
use strict;

package PlugApps::Build::Database;
use DBI;
use Thread::Queue;
use Thread::Semaphore;
use Switch;
use File::stat;

# we only ever want one instance connected to the database.
# EVER.
our $available = Thread::Semaphore->new(1);

our ($q_svc, $q_db,$q_irc);

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
    ##
    while(my $orders = $q_db->dequeue ){
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
            case "count" { #generally recv'd from irc..
                my $table = @{$orders}[2];
                my $count = $self->count($table);
                $q_irc->enqueue(['db','count',$table,$count]);
            }
            case "percent_done" { #generally recv'd from irc..
                my $table = @{$orders}[2];
                my ($done,$count) = ($self->done(),$self->count('package'));
                $q_irc->enqueue(['db','percent_done',$done,$count]);
            }
            case "percent_failed" { #generally recv'd from irc..
                my $table = @{$orders}[2];
                my ($done,$count) = ($self->failed(),$self->count('package'));
                $q_irc->enqueue(['db','percent_failed',$done,$count]);
            }
            case "next" { #generally recv'd from svc
                my $builder = @{$orders}[2];
                my $next = $self->get_next_package($builder);
                if( $next ){
                    my $pkg = join('-',@{$next}[0,1]).'!'.join(' ',@{$next}[2,3]);
                    printf("DbRespond:next:%s\n",$pkg);
                    $self->pkg_work(@{$next}[1], $builder);
                    $q_svc->enqueue(['db','next',$builder,$pkg]);
                }else{
                    $q_svc->enqueue(['db','next',$builder,'FAIL']);
                }
            }
            case "add" { # from svc
				my $pkg = @{$orders}[2];
            	if ($self->pkg_add($pkg)) {
            		$q_svc->enqueue(['db','add',$pkg,'FAIL']);
            	} else {
            		$q_svc->enqueue(['db','add',$pkg,'OK']);
            	}
            }
            case "unfail" { # from irc
            	$self->pkg_unfail(@{$orders}[2]);
            	$q_irc->enqueue(['db','print',"Unfailed @{$orders}[2]"]);
            }
            case "done" { # from svc
            	$self->pkg_done(@{$orders}[2]);
            }
            case "fail" { # from svc
            	$self->pkg_fail(@{$orders}[2]);
            }
            case "unfuck" { # from irc
            	$self->unfuck();
            	$q_irc->enqueue(['db', 'print', 'operation unfuck in progress, sir!']);
            }
            case "update" { # generally recv'd from irc
            	$self->update();
            	$q_irc->enqueue(['db', 'update', 'done']);
            }
            case "rebuild" {
            	my $target = @{$orders}[2];
            	if ($target eq "all") {
            		$self->rebuild_all();
            	} elsif ($target eq "some") {
            		$self->rebuild_some();
            	} else {
            		$q_irc->enqueue(['db','print','Usage: !rebuild <all|some>']);
            	}
            }
	    case "status" {
		$self->status(@{$orders}[2]);
	    }
	    case "ready" {
		my $target = @{$orders}[2];
		if( $target eq 'detail'){
		    my $ready = $self->ready_detail();
		    $q_irc->enqueue(['db','print',sprintf("Packages waiting to be built: %d",$ready->[0])]);
		    if( $ready->[0] > 1){
			$q_irc->enqueue(['db','print',sprintf("Packages waiting: %s",$ready->[1])]);
		    }
		}else{
		    my $ready = $self->ready();
		    if( defined($ready) ){
			$ready = $ready?$ready:"none";
			$q_irc->enqueue(['db','print',"Packages waiting to be built: $ready"]);
		    }else{
			$q_irc->enqueue(['db','print','ready: unknown error.']);
		    }
		}
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
        my $db = DBI->connect("dbi:mysql:$database", "$user", "$pass", {RaiseError => 0, AutoCommit => 1});
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

sub get_next_package{
    my ($self, $builder) = @_;
    if( defined($self->{dbh}) ){
		# TODO: select architecture for builder
    	$self->{dbh}->do("update armv5 set builder = null where builder = '$builder'");
        my $sql = "select
           p.repo, p.package, p.depends, p.makedepends
           from
           abs as p
            left outer join
             ( select 
                 dp.id, dp.package, d.done as 'done'
                 from package_depends dp
                 inner join armv5 as d on (d.id = dp.dependency)
             ) as dp on (p.id = dp.package)
            left outer join armv5 as a on (a.id = p.id)
            where p.skip = 0 and p.del = 0 and a.done = 0 and a.fail = 0 and a.builder is null group by p.id
            having (count(dp.id) = sum(dp.done) or (p.depends = '' and p.makedepends = '' ) ) limit 1";
#            having (count(dp.id) == sum(dp.done) or (p.depends = '') ) and p.done <> 1 and p.fail <> 1 and (p.builder is null or p.builder = '')  limit 1";
        my $db = $self->{dbh};
        my @next_pkg = $db->selectrow_array($sql);
        return undef if (!$next_pkg[0]);
        $self->{dbh}->do("update package set start = unix_timestamp() where package = '$next_pkg[1]'");
        return \@next_pkg;
    }else{
        return undef;
    }
}

sub ready{
    my $self = shift;
    
    if( defined($self->{dbh}) ){
        my $sql = "select count(*) from (select
           p.repo, p.package, p.depends, p.makedepends
           from
           abs as p
            left outer join
             ( select 
                 dp.id, dp.package, d.done as 'done'
                 from package_depends dp
                 inner join armv5 as d on (d.id = dp.dependency)
             ) as dp on (p.id = dp.package)
            left outer join armv5 as a on (a.id = p.id)
            where p.skip = 0 and p.del = 0 and a.done = 0 and a.fail = 0 and a.builder is null group by p.id
            having (count(dp.id) = sum(dp.done) or (p.depends = '' and p.makedepends = '' ) )) as xx";
#    	my $sql = "
#	    select count(*) from (
#	    select
#           'blank' as crap
#           from
#           package as p
#            left outer join
#             ( select 
#                 dp.id, dp.package, d.done as 'done'
#                 from package_depends dp
#                 inner join package as d on (d.id = dp.dependency)
#             ) as dp on ( p.id = dp.package)
#             group by p.id
#            having (count(dp.id) == sum(dp.done) or (p.depends = '' and p.makedepends = '' ) ) and p.done <> 1 and p.fail <> 1 and (p.builder is null or p.builder = '')
#	    ) as xx";
        my $db = $self->{dbh};
        my @next_pkg = $db->selectrow_array($sql);
        return undef if (!defined($next_pkg[0]));
        return $next_pkg[0];
    }else{
        return undef;
    }
}

sub ready_detail{
    my $self = shift;
    
    if( defined($self->{dbh}) ){
    	my $sql = "select
           p.repo, p.package
           from
           package as p
            left outer join
             ( select 
                 dp.id, dp.package, d.done as 'done'
                 from package_depends dp
                 inner join package as d on (d.id = dp.dependency)
             ) as dp on ( p.id = dp.package)
             group by p.id
            having (count(dp.id) == sum(dp.done) or (p.depends = '' and p.makedepends = '' ) ) and p.done <> 1 and p.fail <> 1 and (p.builder is null or p.builder = '')";
        my $sth = $self->{dbh}->prepare($sql);
        $sth->execute();
	my $res=undef;
	my $cnt=0;
	while( my $row = $sth->fetchrow_arrayref() ){
	    $res.=sprintf(" %s-%s,",$row->[0],$row->[1]);
	    $cnt++;
	}
	return [$cnt,$res];
    }else{
        return undef;
    }
}

sub count{
    my $self = shift;
    
    my $data = shift;
    print "DB-Count $data\n";
	my $ret = ($self->{dbh}->selectrow_array("select count(*) from $data"))[0] || 0;
    print "DB-Count $data : $ret\n";
    return $ret;
}

sub done{
    my $self = shift;
	# TODO: multiple arch
	my $ret = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv5 on (armv5.id = abs.id) where done = 1 and fail = 0"))[0] || 0;
    return $ret;
}

sub failed{
    my $self = shift;
	# TODO: multiple arch
	my $ret = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv5 on (armv5.id = abs.id) where fail = 1"))[0] || 0;
    return $ret;
}

sub status{
    my ($self,$package) = @_;
    if( defined($package)){
	if( $package ne ''){
		# TODO: multiple arch, skip/del flag
	    my $sth = $self->{dbh}->prepare("select package, repo, done, fail, builder, git, abs from abs inner join armv5 on (abs.id = armv5.id) where package = ?");
	    $sth->execute($package);
	    my $ar = $sth->fetchall_arrayref();
	    if( scalar(@{$ar}) ){ # 1 or more
			foreach my $r (@{$ar}){
				my ($name,$repo,$done,$fail,$builder,$git,$abs)= @{$r};
				my $state = (!$done && !$fail?'unbuilt':(!$done&&$fail?'failed':($done && !$fail?'done':'???')));
				if( $builder ne '' && $state eq 'unbuilt'){
					$state = 'building';
				}
				my $source = ($git&&!$abs?'git':(!$git&&$abs?'abs':'indeterminate'));
				my $status= sprintf("Status of package '%s' : repo=>%s, src=>%s, state=>%s",$name,$repo,$source,$state);
				$status .= sprintf(", builder=>%s",$builder) if $state eq 'building';
				# TODO: multiple arch
				my $blocklist = $self->{dbh}->selectall_arrayref("select abs.repo, abs.package, arm.fail from package_name_provides as pn inner join package_depends as pd on (pn.package = pd.package) inner join armv5 as arm on (pd.dependency = arm.id) inner join abs on (arm.id = abs.id) where arm.done = 0 and pn.name = ?", undef, $name);
				if ($blocklist) {
					$status .= ", blocked on: ";
					foreach my $blockrow (@$blocklist) {
						my ($blockrepo, $blockpkg, $blockfail) = @$blockrow;
						$status .= sprintf("%s/%s (%s) ", $blockrepo, $blockpkg, $blockfail?"F":"N");
					}
				}
				$q_irc->enqueue(['db','print',$status]);
			}
	    }else{ # zilch
			$q_irc->enqueue(['db','print','could not find package \''.$package.'\'']);
	    }
	}
    }
    
}

sub pkg_add {
	my $self = shift;
	my $data = shift;
	my ($repo, $package, $filename, $md5sum_sent) = split(/\|/, $data);
    print " -> adding $package\n";

    # verify md5sum
    my $md5sum_file = `md5sum $self->{packaging}->{in_pkg}/$filename`;
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
    print "   -> adding $repo/$package ($filename)..\n";
    system("mv -f $self->{packaging}->{in_pkg}/$filename $self->{packaging}->{repo}->{root}/$repo");
    if ($? >> 8) {
        print "    -> move failed\n";
        return 1;
    }
    system("$self->{packaging}->{archbin}/repo-add -q $self->{packaging}->{repo}->{root}/$repo/$repo.db.tar.gz $self->{packaging}->{repo}->{root}/$repo/$filename");
    if ($? >> 8) {
        print "    -> move failed\n";
        return 1;
    }
     
    return 0;
}

# assign builder to package
sub pkg_work {
	my $self = shift;
    my $package = shift;
    my $builder = shift;
	# TODO: multiple arch
    #$self->{dbh}->do("update package set builder = '$builder' where package = '$package'");
	$self->{dbh}->do("update armv5 inner join abs on (armv5.id = abs.id) set armv5.builder = ? where abs.package = ?", undef, $builder, $package)
}

# set package done
sub pkg_done {
	my $self = shift;
    my $package = shift;
    $self->{dbh}->do("update armv5 inner join abs on (armv5.id = abs.id) set armv5.builder = null, armv5.done = 1, armv5.fail = 0, armv5.finish = unix_timestamp() where abs.package = ?", undef, $package);
}

# set package fail
sub pkg_fail {
	my $self = shift;
    my $package = shift;
    $self->{dbh}->do("update armv5 inner join abs on (armv5.id = abs.id) set armv5.builder = null, armv5.done = 0, armv5.fail = 1, armv5.finish = unix_timestamp() where abs.package = ?", undef, $package);
}

# unfail package or all
sub pkg_unfail {
	my $self = shift;
	my $package = shift;
	if ($package eq "all") {
		$self->{dbh}->do("update armv5 set fail = 0, done = 0, builder = null where fail = 1");
	} else {
		$self->{dbh}->do("update armv5 inner join abs on (armv5.id = abs.id) set armv5.fail = 0, armv5.done = 0, armv5.builder = null where abs.package = ?", undef, $package);
	}
}

sub unfuck {
	my $self = shift;
	my $reporoot = $self->{packaging}->{repo}->{root};
	my $count = 0;
	
	my $rows = $self->{dbh}->selectall_arrayref("select repo, package, pkgname, pkgver, pkgrel from package where done = 0");
	
	foreach my $row (@$rows) {
		my ($repo, $package, $pkgname, $pkgver, $pkgrel) = @$row;
		my $namecount = split(/ /, $pkgname);
		foreach my $name (split(/ /, $pkgname)) {
			my $namebase = "$reporoot/$repo/$name-$pkgver-$pkgrel";
			if (-e "$namebase-arm.pkg.tar.xz") {
				if (stat("$namebase-arm.pkg.tar.xz")->mtime gt "1295325270") {
					$namecount--;
				}
			} elsif (-e "$namebase-any.pkg.tar.xz") {
				if (stat("$namebase-any.pkg.tar.xz")->mtime gt "1295325270") {
					$namecount--;
				}
			} else {
				last;
			}
		}
		if ($namecount == 0) {
			$self->{dbh}->do("update package set fail = 0, done = 1 where package = '$package'");
			$count++;
		}
	}
	$q_irc->enqueue(['db', 'print', "unfucked $count packages"]);
}
		

sub update {
	my $self = shift;
	my (%skiplist, %gitlist, %abslist);
	my $gitroot = $self->{packaging}->{git}->{root};
	my $absroot = $self->{packaging}->{abs}->{root};
	my $workroot = $self->{packaging}->{workroot};
	my $archbin = $self->{packaging}->{archbin};

	$q_irc->enqueue(['db', 'print', 'Updating git..']);
	print "update git..\n";
	system("pushd $gitroot; git pull; popd");
	open FILE, "<$gitroot/packages-to-skip.txt" or die $!;
	while (<FILE>) {
		next if ($_ =~ /(^#.*|^\W.*)/);
		my ($pkg) = (split(/ /, $_))[2];
		chomp($pkg);
		$skiplist{$pkg} = 1;
	}
	close FILE;
	
	# add/update git packages
	print "update git packages..\n";
	my $git_count = 0;
	foreach my $repo (@{$self->{packaging}->{git}->{repos}}) {
		foreach my $pkg (glob("$gitroot/$repo/*")) {
			next unless (-d $pkg);
			$pkg =~ s/^\/.*\///;
			$gitlist{$pkg} = 1;
			my ($db_pkgver, $db_pkgrel, $db_plugrel) = $self->{dbh}->selectrow_array("select pkgver, pkgrel, plugrel from abs where package = ?", undef, $pkg);
			$db_plugrel = $db_plugrel || "0";
			my $vars = `./pkgsource.sh $gitroot $repo $pkg`;
			chomp($vars);
			my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends,$plugrel,$noautobuild) = split(/\|/, $vars);
			# new package, different plugrel or version, update, done = 0
			next unless (defined $plugrel); # no plugrel? no soup!
			next unless (! defined $db_pkgver || "$plugrel" ne "$db_plugrel" || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel");
			my $is_done = 0;
			# noautobuild set, assume built, done = 1
			$is_done = 1 if ($noautobuild);
			print "$repo/$pkg to $pkgver-$pkgrel-plug$plugrel, done = $is_done\n";
			# update abs table
			$self->{dbh}->do("insert into abs (package, repo, pkgname, provides, pkgver, pkgrel, plugrel, depends, makedepends, git, abs, del) values (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, 0)
                              on duplicate key update id = LAST_INSERT_ID(id), repo = ?, pkgname = ?, provides = ?, pkgver = ?, pkgrel = ?, plugrel = ?, depends = ?, makedepends = ?, git = 1, abs = 0, del = 0",
							undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $plugrel, $depends, $makedepends, $repo, $pkgname, $provides, $pkgver, $pkgrel, $plugrel, $depends, $makedepends);
			# update architecture tables
			$self->{dbh}->do("insert into armv5 (id, done, fail) values (LAST_INSERT_ID(), ?, 0)
                              on duplicate key update done = ?, fail = 0",
							undef, $is_done, $is_done);
			# create work unit package
			`tar -zcf "$workroot/$repo-$pkg.tgz" -C "$gitroot/$repo" "$pkg" > /dev/null`;
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
			next unless (-d $pkg);
			$pkg =~ s/^\/.*\///;
			next if ($skiplist{$pkg});
			next if ($pkg =~ /.*\-lts$/);
			$abslist{$pkg} = 1;
			my ($db_pkgver, $db_pkgrel) = $self->{dbh}->selectrow_array("select pkgver, pkgrel from abs where package = ?", undef, $pkg);
			my $vars = `./pkgsource.sh $absroot $repo $pkg`;
			chomp($vars);
			my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends) = split(/\|/, $vars);
			if ($gitlist{$pkg}) {
				if ("$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel") {
					$q_irc->enqueue(['db','print',"$pkg is out of date in git, current = $db_pkgver-$db_pkgrel, new = $pkgver-$pkgrel"]);
				}
				next;
			}
			# skip a bad source
			next if (! defined $pkgver);
			# create work unit here, to repackage abs changes without ver-rel bump
			`tar -zcf "$workroot/$repo-$pkg.tgz" -C "$absroot/$repo" "$pkg" > /dev/null`;
			# new package, different version, update, done = 0
			next unless (! defined $db_pkgver || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel");
			print "$repo/$pkg to $pkgver-$pkgrel\n";
			# update abs table
			$self->{dbh}->do("insert into abs (package, repo, pkgname, provides, pkgver, pkgrel, depends, makedepends, git, abs, del) values (?, ?, ?, ?, ?, ?, ?, ?, 0, 1, 0)
                              on duplicate key update id = LAST_INSERT_ID(id), repo = ?, pkgname = ?, provides = ?, pkgver = ?, pkgrel = ?, depends = ?, makedepends = ?, git = 0, abs = 1, del = 0",
				undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends);
			# update architecture tables
			$self->{dbh}->do("insert into armv5 (id, done, fail) values (LAST_INSERT_ID(), 0, 0) on duplicate key update done = 0, fail = 0");

			# create work unit package
			`tar -zcf "$workroot/$repo-$pkg.tgz" -C "$absroot/$repo" "$pkg" > /dev/null`;
			$abs_count++;
		}
	}
	# prune git/abs in db
	my $rows = $self->{dbh}->selectall_arrayref("select package, git, abs from abs");
	foreach my $row (@$rows) {
		my ($pkg, $git, $abs) = @$row;
		next if ($git && $gitlist{$pkg});
		next if ($abs && $abslist{$pkg});
		print "del flag on $pkg\n";
		$self->{dbh}->do("update abs set del = 1 where package = ?", undef, $pkg);
	}
	
	# build package_name_provides
	$q_irc->enqueue(['db', 'update', "Updated $git_count from git, $abs_count from abs. Rebuilding depends.."]);
	print "building package_name_provides..\n";
	$rows = $self->{dbh}->selectall_arrayref("select id, pkgname, provides from abs where del = 0");
	$self->{dbh}->do("delete from package_name_provides");
	foreach my $row (@$rows) {
		my ($id, $pkgname, $provides) = @$row;
		foreach my $name (split(/ /, $pkgname)) {
			$name =~ s/(<|=|>).*//;
			$self->{dbh}->do("insert into package_name_provides (name, provides, package) values (?, 0, ?)", undef, $name, $id);
		}
		if ($provides) {
			foreach my $name (split(/ /, $provides)) {
				$name =~ s/(<|=|>).*//;
				$self->{dbh}->do("insert into package_name_provides (name, provides, package) values (?, 1, ?)", undef, $name, $id);
			}
		}
	}
	
	$self->rebuild_all;
}

sub rebuild_all {
	my $self = shift;
	# build package_depends using depends AND makedepends
	$q_irc->enqueue(['db', 'print', "Rebuilding package_depends with depends and makedepends.."]);
	my $rows = $self->{dbh}->selectall_arrayref("select id, depends, makedepends from abs where del = 0");
	$self->{dbh}->do("delete from package_depends");
	foreach my $row (@$rows) {
		my ($id, $depends, $makedepends) = @$row;
		next if (!$depends && !$makedepends);
		$depends = "" unless $depends;
		$makedepends = "" unless $makedepends;
		my $statement = "insert into package_depends (dependency, package) select distinct package, $id from package_name_provides where name in (";
		foreach my $name (split(/ /, join(' ', $depends, $makedepends))) {
			$name =~ s/(<|=|>).*//;
			$statement .= "'$name', ";
		}
		$statement =~ s/, $/\)/;
		$self->{dbh}->do("$statement");
	}
	$q_irc->enqueue(['db', 'print', "Rebuild done."]);
}

sub rebuild_some {
	my $self = shift;
	# build package_depends using just depends
	$q_irc->enqueue(['db', 'print', "Rebuilding package_depends with only depends.."]);
	my $rows = $self->{dbh}->selectall_arrayref("select id, depends, makedepends from abs");
	$self->{dbh}->do("delete from package_depends");
	foreach my $row (@$rows) {
		my ($id, $depends, $makedepends) = @$row;
		next if (!$depends);
		$depends = "" unless $depends;
		$makedepends = "" unless $makedepends;
		my $statement = "insert into package_depends (dependency, package) select distinct package, $id from package_name_provides where name in (";
		foreach my $name (split(/ /, $depends)) {
			$name =~ s/(<|=|>).*//;
			$statement .= "'$name', ";
		}
		$statement =~ s/, $/\)/;
		$self->{dbh}->do("$statement");
	}
	$q_irc->enqueue(['db', 'print', "Rebuild done."]);
}

1;
