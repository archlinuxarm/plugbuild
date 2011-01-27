#!/usr/bin/perl -w
use strict;

package PlugApps::Build::Database;
use DBI;
use Thread::Queue;
use Thread::Semaphore;
use Switch;

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
            	if ($self->pkg_add(@{$orders}[2])) {
            		$q_svc->enqueue(['db','add','add','FAIL']);
            	} else {
            		$q_svc->enqueue(['db','add','add','OK']);
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
            		q_irc->enqueue(['db','print','Usage: !rebuild <all|some>']);
            	}
            }
	    case "status" {
		$self->status(@{$orders}[2]);
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
        my $database = $self->{sqlite};
        my $db = DBI->connect("dbi:SQLite:$database", "", "", {RaiseError => 0, AutoCommit => 1});
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
    	$self->{dbh}->do("update package set builder = null where builder = '$builder'");
        my $sql = "select
           p.repo, p.package, p.depends, p.makedepends
           from
           package as p
            left outer join
             ( select 
                 dp.id, dp.package, d.done as 'done'
                 from package_depends dp
                 inner join package as d on (d.id = dp.dependency)
             ) as dp on ( p.id = dp.package)
             group by p.id
            having (count(dp.id) == sum(dp.done) or (p.depends = '' and p.makedepends = '' ) ) and p.done <> 1 and p.fail <> 1 and (p.builder is null or p.builder = '')  limit 1";
#            having (count(dp.id) == sum(dp.done) or (p.depends = '') ) and p.done <> 1 and p.fail <> 1 and (p.builder is null or p.builder = '')  limit 1";
        my $db = $self->{dbh};
        my @next_pkg = $db->selectrow_array($sql);
        return undef if (!$next_pkg[0]);
        $self->{dbh}->do("update package set start = strftime('%s', 'now') where package = '$next_pkg[1]'");
        return \@next_pkg;
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
	my $ret = ($self->{dbh}->selectrow_array("select count(*) from package where done = 1 and fail <> 1"))[0] || 0;
    return $ret;
}

sub failed{
    my $self = shift;
	my $ret = ($self->{dbh}->selectrow_array("select count(*) from package where fail = 1"))[0] || 0;
    return $ret;
}

sub status{
    my ($self,$package) = @_;
    if( defined($package)){
	if( $package ne ''){
	    my $sth = $self->{dbh}->prepare("select package,repo,done,fail,builder,git,abs from package where package = ?");
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
    $self->{dbh}->do("update package set builder = '$builder' where package = '$package'");
}

# set package done
sub pkg_done {
	my $self = shift;
    my $package = shift;
    $self->{dbh}->do("update package set builder = null, done = 1, finish = strftime('%s', 'now') where package = '$package'");
}

# set package fail
sub pkg_fail {
	my $self = shift;
    my $package = shift;
    $self->{dbh}->do("update package set builder = null, fail = 1, finish = strftime('%s', 'now') where package = '$package'");
}

# unfail package or all
sub pkg_unfail {
	my $self = shift;
	my $package = shift;
	if ($package eq "all") {
		$self->{dbh}->do("update package set fail = 0, done = 0 where fail = 1");
	} else {
		$self->{dbh}->do("update package set fail = 0, done = 0 where package = '$package'");
	}
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
	system("git --git-dir='$gitroot/.git' --work-tree='..' pull");
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
			my ($db_pkgver, $db_pkgrel, $db_plugrel) = $self->{dbh}->selectrow_array("select pkgver, pkgrel, plugrel from package where package = '$pkg'");
			$db_plugrel = $db_plugrel || "0";
			my $vars = `./pkgsource.sh $gitroot $repo $pkg`;
			chomp($vars);
			my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends,$plugrel,$noautobuild) = split(/\|/, $vars);
			# new package, different plugrel or version, update, done = 0
			next unless (! defined $db_pkgver || "$plugrel" ne "$db_plugrel" || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel");
			my $is_done = 0;
			# noautobuild set, assume built, done = 1
			$is_done = 1 if ($noautobuild);
			print "$repo/$pkg to $pkgver-$pkgrel-plug$plugrel, done = $is_done\n";
			$self->{dbh}->do("delete from package where package = '$pkg'");
			$self->{dbh}->do("insert into package (done, package, repo, pkgname, provides, pkgver, pkgrel, plugrel, depends, makedepends, git, abs) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0)",
				undef, $is_done, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $plugrel, $depends, $makedepends);
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
			my ($db_pkgver, $db_pkgrel) = $self->{dbh}->selectrow_array("select pkgver, pkgrel from package where package = '$pkg'");
			my $vars = `./pkgsource.sh $absroot $repo $pkg`;
			chomp($vars);
			my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends) = split(/\|/, $vars);
			if ($gitlist{$pkg}) {
				if ("$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel") {
					$q_irc->enqueue(['db','print',"$pkg is out of date in git, current = $db_pkgver-$db_pkgrel, new = $pkgver-$pkgrel"]);
				}
				next;
			}
			# new package, different version, update, done = 0
			next unless (! defined $db_pkgver || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel");
			print "$repo/$pkg to $pkgver-$pkgrel\n";
			$self->{dbh}->do("delete from package where package = '$pkg'");
			$self->{dbh}->do("insert into package (package, repo, pkgname, provides, pkgver, pkgrel, depends, makedepends, git, abs) values (?, ?, ?, ?, ?, ?, ?, ?, 0, 1)",
				undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends);
			# create work unit package
			`tar -zcf "$workroot/$repo-$pkg.tgz" -C "$absroot/$repo" "$pkg" > /dev/null`;
			$abs_count++;
		}
	}
	# prune git/abs in db
	my $rows = $self->{dbh}->selectall_arrayref("select package, git, abs from package");
	foreach my $row (@$rows) {
		my ($pkg, $git, $abs) = @$row;
		next if ($git && $gitlist{$pkg});
		next if ($abs && $abslist{$pkg});
		print "removing $pkg\n";
		$self->{dbh}->do("delete from package where package = '$pkg'");
	}
	
	# build package_name_provides
	$q_irc->enqueue(['db', 'update', "Updated $git_count from git, $abs_count from abs. Rebuilding depends.."]);
	print "building package_name_provides..\n";
	$rows = $self->{dbh}->selectall_arrayref("select id, pkgname, provides from package");
	$self->{dbh}->do("delete from package_name_provides");
	foreach my $row (@$rows) {
		my ($id, $pkgname, $provides) = @$row;
		foreach my $name (split(/ /, $pkgname)) {
			$name =~ s/(<|=|>).*//;
			$self->{dbh}->do("insert into package_name_provides (name, provides, package) values (\"$name\", 0, $id)");
		}
		if ($provides) {
			foreach my $name (split(/ /, $provides)) {
				$name =~ s/(<|=|>).*//;
				$self->{dbh}->do("insert into package_name_provides (name, provides, package) values (\"$name\", 1, $id)");
			}
		}
	}
	
	$self->rebuild_all;
}

sub rebuild_all {
	my $self = shift;
	# build package_depends using depends AND makedepends
	$q_irc->enqueue(['db', 'print', "Rebuilding package_depends with depends and makedepends.."]);
	my $rows = $self->{dbh}->selectall_arrayref("select id, depends, makedepends from package");
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
	my $rows = $self->{dbh}->selectall_arrayref("select id, depends, makedepends from package");
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
