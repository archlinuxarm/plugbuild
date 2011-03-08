#!/usr/bin/perl

# plugbuild client #4
#
# TODO:
#  - script auto-update from plugbuild server, maintain $builder on update
#  - enable logging again
#  - cut out all the command output, do a spinner to show we're still kicking
#  - keep server tcp connection open, block and reconnect if we lose it
#  - sftp/scp package uploading
#  - ncurses?

use strict;
use IO::Socket;
use FindBin qw($Bin);

# SET ME! your builder name
my $builder = "kevin";

# other variables, probably shouldn't touch these
my $makepkg = "PACMAN_OPTS='-f' makepkg -AcsfL --asroot --noconfirm";
my $workroot = "$Bin/work";
my $pkgdest = "$Bin/pkgdest";
my $workurl = "http://dev2.plugapps.com/plugbuild/work";

# talk to server, return its reply
sub talk {
	my $command = shift;
	
	while (1) {
		my $sock = new IO::Socket::INET (
			PeerAddr => 'dev2.plugapps.com',
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
	$done = 0;
	holyshitprint "Got your Ctrl+C, I'll die after this package :D";
}

while ($done) {
	system("pacman -Syyuf --noconfirm");
	# 0. sanitize workspace
	chdir($Bin);
	`rm -rf $workroot; mkdir $workroot`;
	`rm -rf $pkgdest; mkdir $pkgdest`;

	# 1. ask for a package to build
	my $reply = talk("new!$builder");
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
	
	# 3. reinstall of existing dependencies
	if ($deps) {
		if (check_deps($deps)) {
			holyshitprint " !!! pacman failed to reinstall existing dependencies\n";
			talk("fail!$package");
			next;
		}
	}
	
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
		my $reply = talk("fail!$package");
		print "    -> reported fail: $reply\n";
		### upload log
		my ($logfile) = glob("$workroot/$package/*-arm-build.log");
		if ($logfile) {
			print " -> uploading $logfile\n";
			my $result = `curl --form uploaded=\@$logfile --form press=Upload http://dev2.plugapps.com:81/plugbuild/uplog.php`;
			if ($result eq "FAIL") {
				print "    -> failed\n";
			}
		}
		next;
	}
	
	# 5. upload package(s)
	my $uploaded = 0;
	foreach my $filename (glob("$pkgdest/*")) {
		$filename =~ s/^\/.*\///;
		next if ($filename eq "");
		my $md5sum_file = `md5sum $pkgdest/$filename`;
		$md5sum_file = (split(/ /, $md5sum_file))[0];
		print " -> uploading $filename ($md5sum_file)\n";
		my $result = `curl --retry 5 --form uploaded=\@$pkgdest/$filename --form press=Upload http://dev2.plugapps.com:81/plugbuild/uppkg.php`;
		chomp($result);
		if ($result eq "ERROR") {
			holyshitprint "    -> failed to upload";
			$uploaded = 0;
			last;
		}
		
		my $reply = talk("add!$repo|$package|$filename|$md5sum_file");
		if ($reply eq "FAIL") {
			holyshitprint "    -> server failure: add!$repo|$package|$filename|$md5sum_file";
			$uploaded = 0;
			last;
		}
		$uploaded = 1;
	}

	### upload log
	my ($logfile) = glob("$workroot/$package/*-arm-build.log");
	if ($logfile) {
		print " -> uploading $logfile\n";
		my $result = `curl --form uploaded=\@$logfile --form press=Upload http://dev2.plugapps.com:81/plugbuild/uplog.php`;
		if ($result eq "FAIL") {
			print "    -> failed\n";
		}
	}
		
	
	# 6. notify server that i'm done
	if ($uploaded) {
		print " -> notifying server of completion\n";
		my $reply = talk("done!$package");
		if ($reply eq "FAIL") {
			holyshitprint "    -> server failure: done!$package";
			next;
		}
	}
}
