#!/usr/bin/perl
use strict;
use FindBin qw($Bin);
use AnyEvent;
use AnyEvent::TLS;
use AnyEvent::Handle;
use AnyEvent::Socket;

####### BEGIN USER CONFIGURATION #######

# plugbuild server
my $server  = "archlinuxarm.org";
my $port    = 2123;

# chroot location
my $chroot = "/root/chroot";

# SSL certificate info (use $Bin for script execution dir)
my $ca_file     = "$Bin/certs/plugbuild-cacert.pem";    # our CA certificate
my $cert_file   = "$Bin/certs/client.pem";              # combined key and cert pem
my $password    = "sekrit";                             # key password (maybe make this interactive)

######## END USER CONFIGURATION ########

my $condvar = AnyEvent->condvar;
my $h;

tcp_connect $server, $port, sub {
    my ($fh, $address) = @_;
    die $! unless $fh;
    
    $h = new AnyEvent::Handle
                            fh          => $fh,
                            tls         => "connect",
                            peername    => $address,
                            tls_ctx     => {
                                            verify          => 1,
                                            ca_file         => $ca_file,
                                            cert_file       => $cert_file,
                                            cert_password   => $password,
                                            verify_cb       => sub { cb_verify_cb(@_); }
                                            },
                            keepalive   => 1,
                            no_delay    => 1,
                            rtimeout    => 3, # 3 seconds to authenticate with SSL before destruction
                            on_rtimeout => sub { $h->destroy; },
                            on_error    => sub { cb_error(@_); },
                            on_starttls => sub { cb_starttls(@_); }
                            ;

# other variables, probably shouldn't touch these
my $makepkg = "makechrootpkg -cr $chroot -- -AcsfrL";
my $workroot = "$Bin/work";
my $pkgdest = "$Bin/pkgdest";
my $workurl = "http://archlinuxarm.org/builder/work";

# talk to server, return its reply
sub talk {
    my $command = shift;
	
	while (1) {
		my $sock = new IO::Socket::INET (
			PeerAddr => 'archlinuxarm.org',
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

my $done = 1;
$SIG{INT} = \&catcher;
sub catcher {
	$SIG{INT} = \&catcher;
	print "control si\n"
}

while ($done) {
	#system("pacman -Syyuf --noconfirm");
	# 0. sanitize workspace, update chroot
	chdir($Bin);
	`rm -rf $workroot; mkdir $workroot`;
	`rm -rf $pkgdest; mkdir $pkgdest`;
	system("mkarchroot -u $chroot/root");

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
	
	# 4. build package
	chdir "$workroot/$package";
	`sed -i "/^options=/s/force//" PKGBUILD`;
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
		my ($logfile) = glob("$chroot/copy/build/*-armv7h-build.log");
		if ($logfile) {
			print " -> uploading $logfile\n";
			my $result = `curl --form uploaded=\@$logfile --form press=Upload http://archlinuxarm.org:81/builder/uplog.php`;
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
			my $result = `curl --retry 5 --form uploaded=\@$pkgdest/$filename --form press=Upload http://archlinuxarm.org:81/builder/uppkg.php`;
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
