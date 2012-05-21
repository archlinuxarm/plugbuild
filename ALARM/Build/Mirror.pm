#!/usr/bin/perl -w
#
# PlugBuild mirror updater
#

use strict;

package ALARM::Build::Mirror;
use Thread::Queue;
use Thread::Semaphore;
use Switch;
use FindBin qw($Bin);
use Text::CSV;
use DBI;

our $available = Thread::Semaphore->new(1);

our ($q_svc, $q_db, $q_irc, $q_mir);

sub new {
    my ($class,$config) = @_;
    my $self = $config;
    
    bless $self,$class;
    return $self;
}

sub Run {
    my $self = shift;
    
	return if (! $available->down_nb());
    print "Mirror Run\n";
    
    my $db = DBI->connect("dbi:mysql:$self->{mysql}", "$self->{user}", "$self->{pass}", {RaiseError => 0, AutoCommit => 1, mysql_auto_reconnect => 1});
    if (defined $db) {
        $self->{dbh} = $db;
    } else {
        print "Mirror: Can't establish MySQL connection, bailing out.\n";
        return -1;
    }
    
    while (my $msg = $q_mir->dequeue) {
        my ($from,$order) = @{$msg};
        print "Mirror: got $order from $from\n";
        switch ($order) {
            case "quit" {
                $available->down_force(10);
                last;
            }
            case "recycle" {
                last;
            }
            
            # IRC orders
            case "list" {
                $q_irc->enqueue(['db', 'print', "Mirror list:"]);
                my $rows = $self->{dbh}->selectall_arrayref("select domain, active, tier from mirrors where tier > 0 order by tier");
                foreach my $row (@$rows) {
                    my ($domain, $active, $tier) = @$row;
                    $q_irc->enqueue(['db', 'print', sprintf(" - T%s [%s] %s", $tier, $active?" active ":"inactive", $domain)]);
                }
            }
            case "refresh" {
                $self->geoip_refresh();
            }
            
            # service orders
            case "push" {
                my ($address, $cn) = @{$msg}[2,3];
                print "Mirror: pushing to $address\n";
                foreach my $arch ('armv5', 'armv7') {
                    `rsync -rlt --delete $self->{packaging}->{repo}->{$arch} $address`;
                    if ($? >> 8) {
                        print "Mirror: failed to push $arch to $address: $!\n";
                    } else {
                        print "Mirror: successfully pushed $arch to $address\n";
                    }
                }
                $q_svc->enqueue(['mir', 'sync', $cn]) if defined $cn;
            }
            case "update" {
                my $arch = @{$msg}[2];
                $self->update($arch);
            }
        }
    }
    
    $db->disconnect;
    
    print "Mirror End\n";
    return -1;
}

# update mirrors for a given architecture
sub update {
    my ($self, $arch) = @_;
    my $sync = time();
    print "Mirror: updating $arch\n";
    
    # update sync file
    open (MYFILE, '>', "$self->{packaging}->{repo}->{$arch}/sync");
    print MYFILE "$sync";
    close (MYFILE); 
    
    # only push to Tier 1 mirrors
    my $rows = $self->{dbh}->selectall_arrayref("select id, address from mirrors where tier = 1");
    foreach my $row (@$rows) {
        my ($id, $mirror) = @$row;
        `rsync -rlt --delete $self->{packaging}->{repo}->{$arch} $mirror`;
        if ($? >> 8) {
            $q_irc->enqueue(['mir', 'print', "[mirror] failed to mirror to $mirror"]);
            $self->{dbh}->do("update mirrors set active = 0 where id = ?", undef, $id);     # de-activate failed mirror
            next;
        }
        $self->{dbh}->do("update mirrors set active = 1 where id = ?", undef, $id);         # activate good mirror
    }
    $q_irc->enqueue(['mir', 'print', "[mirror] finished mirroring $arch"]);
    
    # set timer to check Tier 2 mirrors after 5 minutes
    #undef $self->{$arch};
    #$self->{$arch} = AnyEvent->timer(after => 300, cb => sub { $self->tier2($arch, $sync); });
}

# check Tier 2 mirrors for synchronization
sub tier2 {
    my ($self, $arch, $sync) = @_;
    $arch = "arm" if $arch eq "armv5";
    $arch = "armv7h" if $arch eq "armv7";
    
    my $rows = $self->{dbh}->selectall_arrayref("select id, domain from mirrors where tier = 2");
    foreach my $row (@$rows) {
        my ($id, $domain) = @$row;
        my $remote = `wget -O - $domain/$arch/sync 2>/dev/null`;
        chomp $remote;
        if ($remote ne $sync) {
            $q_irc->enqueue(['mir', 'print', "[mirror] Tier 2 check failed on $domain"]);
            $self->{dbh}->do("update mirrors set active = 0 where id = ?", undef, $id);     # de-activate failed mirror
            next;
        }
        $self->{dbh}->do("update mirrors set active = 1 where id = ?", undef, $id);         # activate good mirror
    }
    $q_irc->enqueue(['mir', 'print', "[mirror] Tier 2 check complete for $arch"]);
}

# refresh the GeoIP database
sub geoip_refresh {
    my $self = shift;
    
    $q_irc->enqueue(['mir', 'print', "[mirror] updating GeoIP table"]);
    
    # 2-letter country code to numerical contintent map
    #   1 -> NA, 2 -> SA, 3 -> EU, 4 -> AF, 5 -> AS, 6 -> OC, 7 -> AN
    my %continent_map = (
        EU => 3, A1 => 1, A2 => 1, AP => 5, AF => 5, AL => 3, AQ => 7, DZ => 4, AS => 6, AD => 3, AO => 4, AG => 1, AZ => 3, AZ => 5, AR => 2, AU => 6, AT => 3, BS => 1, BH => 5, BD => 5,
        AM => 3, AM => 5, BB => 1, BE => 3, BM => 1, BT => 5, BO => 2, BA => 3, BW => 4, BV => 7, BR => 2, BZ => 1, IO => 5, SB => 6, VG => 1, BN => 5, BG => 3, MM => 5, BI => 4, BY => 3,
        KH => 5, CM => 4, CA => 1, CV => 4, KY => 1, CF => 4, LK => 5, TD => 4, CL => 2, CN => 5, TW => 5, CX => 5, CC => 5, CO => 2, KM => 4, YT => 4, CG => 4, CD => 4, CK => 6, CR => 1,
        HR => 3, CU => 1, CY => 3, CY => 5, CZ => 3, BJ => 4, DK => 3, DM => 1, DO => 1, EC => 2, SV => 1, GQ => 4, ET => 4, ER => 4, EE => 3, FO => 3, FK => 2, GS => 7, FJ => 6, FI => 3,
        AX => 3, FR => 3, GF => 2, PF => 6, TF => 7, DJ => 4, GA => 4, GE => 3, GE => 5, GM => 4, PS => 5, DE => 3, GH => 4, GI => 3, KI => 6, GR => 3, GL => 1, GD => 1, GP => 1, GU => 6,
        GT => 1, GN => 4, GY => 2, HT => 1, HM => 7, VA => 3, HN => 1, HK => 5, HU => 3, IS => 3, IN => 5, ID => 5, IR => 5, IQ => 5, IE => 3, IL => 5, IT => 3, CI => 4, JM => 1, JP => 5,
        KZ => 3, KZ => 5, JO => 5, KE => 4, KP => 5, KR => 5, KW => 5, KG => 5, LA => 5, LB => 5, LS => 4, LV => 3, LR => 4, LY => 4, LI => 3, LT => 3, LU => 3, MO => 5, MG => 4, MW => 4,
        MY => 5, MV => 5, ML => 4, MT => 3, MQ => 1, MR => 4, MU => 4, MX => 1, MC => 3, MN => 5, MD => 3, ME => 3, MS => 1, MA => 4, MZ => 4, OM => 5, NA => 4, NR => 6, NP => 5, NL => 3,
        AN => 1, CW => 1, AW => 1, SX => 1, BQ => 1, NC => 6, VU => 6, NZ => 6, NI => 1, NE => 4, NG => 4, NU => 6, NF => 6, NO => 3, MP => 6, UM => 6, UM => 1, FM => 6, MH => 6, PW => 6,
        PK => 5, PA => 1, PG => 6, PY => 2, PE => 2, PH => 5, PN => 6, PL => 3, PT => 3, GW => 4, TL => 5, PR => 1, QA => 5, RE => 4, RO => 3, RU => 3, RU => 5, RW => 4, BL => 1, SH => 4,
        KN => 1, AI => 1, LC => 1, MF => 1, PM => 1, VC => 1, SM => 3, ST => 4, SA => 5, SN => 4, RS => 3, SC => 4, SL => 4, SG => 5, SK => 3, VN => 5, SI => 3, SO => 4, ZA => 4, ZW => 4,
        ES => 3, EH => 4, SD => 4, SR => 2, SJ => 3, SZ => 4, SE => 3, CH => 3, SY => 5, TJ => 5, TH => 5, TG => 4, TK => 6, TO => 6, TT => 1, AE => 5, TN => 4, TR => 3, TR => 5, TM => 5,
        TC => 1, TV => 6, UG => 4, UA => 3, MK => 3, EG => 4, GB => 3, GG => 3, JE => 3, IM => 3, TZ => 4, US => 1, VI => 1, BF => 4, UY => 2, UZ => 5, VE => 2, WF => 6, WS => 6, YE => 5,
        ZM => 4,
    );
    
    # download and extract new GeoIP database
    system("wget -P $Bin http://geolite.maxmind.com/download/geoip/database/GeoIPCountryCSV.zip");
    if ($? >> 8) {
        $q_irc->enqueue(['mir', 'print', "[mirror] failed to download new GeoIP database"]);
        return;
    }
    system("unzip $Bin/GeoIPCountryCSV.zip");
    if ($? >> 8) {
        $q_irc->enqueue(['mir', 'print', "[mirror] failed to extract new GeoIP database"]);
        return;
    }
    
    # open CSV database    
    my $csv = Text::CSV->new();
    open(CSV, "<", "$Bin/GeoIPCountryWhois.csv") or return;
    
    # update temporary GeoIP table
    $self->{dbh}->do("delete from geoip_tmp");
    while (<CSV>) {
        next if ($. == 1);
        if ($csv->parse($_)) {
            my @cols = $csv->fields();
            $self->{dbh}->do("insert into geoip_tmp values (?, ?, ?)", undef, $cols[2], $cols[3], $continent_map{$cols[4]} || 1);
            $q_irc->enqueue(['mir', 'print', "[mirror] couldn't map country code $cols[4]"]) if (!$continent_map{$cols[4]});
        } else {
            my $err = $csv->error_input;
            print "Mirror: Failed to parse line: $err\n";
        }
    }
    
    # merge into GeoIP table
    $self->{dbh}->do("lock tables geoip write, geoip_tmp write");
    $self->{dbh}->do("delete from geoip");
    $self->{dbh}->do("insert into geoip select * from geoip_tmp");
    $self->{dbh}->do("unlock tables");
    
    # clean up
    $self->{dbh}->do("delete from geoip_tmp");
    `rm -f $Bin/GeoIPCountryCSV.zip $Bin/GeoIPCountryWhois.csv`;
    close CSV;
    $q_irc->enqueue(['mir', 'print', "[mirror] GeoIP table has been updated"]);
}

1;
