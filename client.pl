#!/usr/bin/perl

# plugbuild client #9001

use strict;
use IO::Socket;
use FindBin qw($Bin);

# SET ME! your builder name, architecture (armv5 or armv7)
my $builder = "kevin";
my $arch = "armv5";

# other variables, probably shouldn't touch these
my $makepkg = "PACMAN_OPTS='-f' makepkg -AcsfrL --asroot --noconfirm";
my $workroot = "$Bin/work";
my $pkgdest = "$Bin/pkgdest";
my $workurl = "http://plugboxlinux.org/plugbuild/work";

# talk to server, return its reply
sub talk {
	my $command = shift;
	
	while (1) {
		my $sock = new IO::Socket::INET (
			PeerAddr => 'plugboxlinux.org',
			PeerPort => '2121',
			Proto => 'tcp',
		);
		if (!$sock) {
			print "Could not create socket: $!\n";
			print "Trying again in 10s..\n";
			sleep 10;
			next;
		}
		print " -> command: $command\n";
		print $sock "$command\n";
		my $buf = <$sock>;
		chomp($buf);
		print "    -> reply: $buf\n";
		close($sock);
		return $buf;
	}
}

# see if we have a package installed, returns 0 = yes
sub check_pacman {
	my $package = shift;
	system("pacman -Qs ^$package\$ > /dev/null");
	return $? >> 8;
}

# build a list of packages to reinstall
sub check_deps {
	my $pkgs = shift;
	$pkgs =~ s/\s+$//; # kill leading/trailing spaces
	$pkgs =~ s/^\s+//;
	print " -> checking dependencies: $pkgs\n";
	my @deps = split(/ /, $pkgs);
	my @list;
	foreach my $dep (@deps) {
		$dep =~ s/(<|=|>).*//;
		next if ($dep eq "glibc");
		next if ($dep eq "kernel26");
		next if ($dep eq "perl");
		next if ($dep eq "ghc");
		next if ($dep eq "texlive-core");
		next if ($dep eq "qt");
		next if ($dep eq "mesa-demos");
		next if ($dep eq "openjdk6" || $dep eq "java-runtime" || $dep eq "java-environment");
		next if ($dep eq "ca-certificates-java");
		next if ($dep eq "ca-certificates");
		next if ($dep eq "mono");
		next if ($dep eq "kdelibs");
		if (!check_pacman($dep)) {
			push @list, $dep;
		}
	}
	$pkgs = join(" ", @list);
	print "    -> reinstalling $pkgs..\n";
	system("rm -f /var/cache/pacman/pkg/*; pacman -Syf --noconfirm $pkgs");
	return $? >> 8;
}

# make a loud statement for printing a message
sub holyshitprint {
	my $message = shift;
	print "\n\n\n\n--------------------------------------------------\n-\n-\n-\n\n";
	print "$message\n\n\n\n";
}

my $done = 1;
$SIG{INT} = \&catcher;
sub catcher {
	$SIG{INT} = \&catcher;
	print "control si\n"
}

while ($done) {
	system("pacman -Syyuf --noconfirm");
	# 0. sanitize workspace
	chdir($Bin);
	`rm -rf $workroot; mkdir $workroot`;
	`rm -rf $pkgdest; mkdir $pkgdest`;

	# 1. ask for a package to build
	my $reply = talk("new!$arch|$builder");
	if ($reply eq "FAIL") {
		print "\n\nSomething horrible happened..\n";
		last;
	}
	my ($unit, $deps) = split(/!/, $reply);
	my ($repo, $package) = split(/-/, $unit, 2);
	
	# 2. download/extract workunit
	chdir($workroot);
	system("wget $workurl/$unit.tgz");
	print " -> extracting work unit\n";
	system("tar -zxf $workroot/$unit.tgz");
#	system("sed -i 's|\./configure|PYTHON=\"/usr/bin/python2\" \./configure|g' $workroot/$package/PKGBUILD");
	
	# 3. reinstall of existing dependencies
#	if ($deps) {
#		if (check_deps($deps)) {
#			holyshitprint " !!! pacman failed to reinstall existing dependencies\n";
#			talk("fail!$arch|$package");
#			next;
#		}
#	}
	
	# 4. build package
	chdir "$workroot/$package";
	print " -> PKGDEST='$pkgdest' $makepkg\n";
	if ($package eq "tar") {
		system("FORCE_UNSAFE_CONFIGURE=1 PKGDEST='$pkgdest' $makepkg");
	} else {
		system("PKGDEST='$pkgdest' $makepkg");
	}
	if ($? >> 8) {
		print " !! $package build failed\n";
		my $reply = talk("fail!$arch|$package");
		print "    -> reported fail: $reply\n";
		### upload log
		my ($logfile) = glob("$workroot/$package/*-arm-build.log");
		if ($logfile) {
			print " -> uploading $logfile\n";
			my $result = `curl --form uploaded=\@$logfile --form press=Upload http://plugboxlinux.org:81/plugbuild/uplog.php`;
			if ($result eq "FAIL") {
				print "    -> failed\n";
			}
		}
		next;
	}
	
	# 5. upload package(s)
	my $uploaded = 0;
	while ($uploaded == 0) {
		foreach my $filename (glob("$pkgdest/*")) {
			$filename =~ s/^\/.*\///;
			next if ($filename eq "");
			my $md5sum_file = `md5sum $pkgdest/$filename`;
			$md5sum_file = (split(/ /, $md5sum_file))[0];
			print " -> uploading $filename ($md5sum_file)\n";
			my $result = `curl --retry 5 --form uploaded=\@$pkgdest/$filename --form press=Upload http://plugboxlinux.org:81/plugbuild/uppkg.php`;
			chomp($result);
			if ($result eq "ERROR") {
				print "    -> failed to upload";
				$uploaded = 0;
				last;
			}
			
			my $reply = talk("add!$arch|$repo|$package|$filename|$md5sum_file");
			if ($reply eq "FAIL") {
				print "    -> server failure: add!$repo|$package|$filename|$md5sum_file";
				$uploaded = 0;
				last;
			}
			$uploaded = 1;
		}
	}

	### upload log
	#my ($logfile) = glob("$workroot/$package/*-arm-build.log");
	#if ($logfile) {
	#	print " -> uploading $logfile\n";
	#	my $result = `curl --form uploaded=\@$logfile --form press=Upload http://plugboxlinux.org:81/plugbuild/uplog.php`;
	#	if ($result eq "FAIL") {
	#		print "    -> failed\n";
	#	}
	#}
		
	
	# 6. notify server that i'm done
	if ($uploaded) {
		print " -> notifying server of completion\n";
		my $reply = talk("done!$arch|$package");
		if ($reply eq "FAIL") {
			holyshitprint "    -> server failure: done!$package";
			next;
		}
	}
}
