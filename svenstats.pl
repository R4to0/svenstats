#!/usr/bin/env perl

# Sven Co-op (svends) log parser "svenstats.pl"
#
# Copyright 2016-2017, Nico R. Wohlgemuth <nico@lifeisabug.com>

use 5.16.0;

use utf8; 
use strict; 
use warnings; 

use autodie;

no warnings 'experimental::smartmatch';

use DBI;
use Data::Dumper;
use MaxMind::DB::Reader;
use Math::BigFloat;
use File::Slurp;
use File::Basename;
use POSIX 'strftime';

# streaming
use IO::Socket;

### config

my $db        = "$ENV{'HOME'}/scstats/scstats.db";
my $geo       = "$ENV{'HOME'}/scstats/GeoLite2-City.mmdb";
my $maxinc    = 450; # maximum score difference between two datapoints to prevent arbitrary player scores set by some maps
my $debug     = 0;   # 1 prints debug output and won't use the DB
my @blacklist = qw(arcade ayakashi_banquet blackmesa_spacebasement botrace bstore evilmansion halloween_hospital kbd2a mmm mmm_v2 runforfreedom_alpha1 secretcity secretcity2 secretcity3 secretcity4beta secretcity5beta secretcity6b6 secretcitykeen_beta secretcitykeen_2_alpha skate_city trempler_weapons); # map blacklist, space seperated, lowercase

my $buflength = 1024; # seems to be enough
my $listenip  = "0.0.0.0";
my $port      = 27100; # port to where to listen for data from SvenDS

###

my $realtime = 0;
my $today;
my @lines;


if (@ARGV != 1) {
   say "Usage: $0 <logfile>";
   exit;
}
elsif ($ARGV[0] eq "-realtime") {
   $realtime = 1;
   socketstream();
}
elsif (! -f $ARGV[0] || ! -r $ARGV[0]) {
   say "$ARGV[0] is not a regular file or can't be read.";
   exit;
}

unless ($realtime) {
   $today = fileparse( $ARGV[0], qw(.log) );
   @lines = read_file( $ARGV[0], binmode => ':raw', chomp => 1 ) ;
   procstats();
}

sub procstats {
   my $hold = 0;
   my ($dbh, $stats, $maps);

   unless ($debug) {
      unless ($dbh = DBI->connect("DBI:SQLite:dbname=$db", '', '', {AutoCommit => 1})) {
         say $DBI::errstr;
         exit;
      }
      $dbh->do('PRAGMA foreign_keys = OFF');
      $dbh->do('PRAGMA journal_mode = MEMORY');
      $dbh->do('PRAGMA cache_size = -8000');
      $dbh->do('PRAGMA synchronous = OFF');
      $dbh->{AutoCommit} = 0;

      $stats = $dbh->selectall_hashref('SELECT steamid, name, id, score, lastscore, deaths, lastdeaths, joins, geo, lat, lon, datapoints, seen FROM stats', 'steamid');

      for (keys %{$stats}) {
         if (defined $$stats{$_}{score}) {
            $$stats{$_}{score}    = Math::BigFloat->new($$stats{$_}{score});
            $$stats{$_}{oldscore} = $$stats{$_}{score}->copy;
         }
         $$stats{$_}{olddeaths}     = $$stats{$_}{deaths}                         if(defined $$stats{$_}{deaths});
         $$stats{$_}{olddatapoints} = $$stats{$_}{datapoints}                     if(defined $$stats{$_}{datapoints});
         $$stats{$_}{lastscore}     = Math::BigFloat->new($$stats{$_}{lastscore}) if(defined $$stats{$_}{lastscore});
         $$stats{$_}{idx}           = $$stats{$_}{id}.'x'.$$stats{$_}{joins}      if(defined $$stats{$_}{id} && defined $$stats{$_}{joins});
      }

      $maps = $dbh->selectall_hashref('SELECT map, count FROM maps', 'map');

      my $res = $dbh->selectrow_hashref('SELECT hold FROM misc WHERE rowid = 1');
      $hold = $$res{hold} if(defined $$res{hold});
   }

   while (my $in = splice(@lines, 0, 1)) {
      next if (length($in) < 28);

      my $line = substr($in, 0, 2).substr($in, 25);
      say $line if($debug);

      if ($line =~ /^L Started map "(.+)" \(CRC "-?[0-9]+"\)/) {
         if (lc($1) ~~ @blacklist) {
            $hold = 1;
         }
         else {
            $hold = 0;
         }

         $$maps{lc($1)}{count}++;
      }

      if ($line =~ /^L "(.+)<([0-9]+)><STEAM_(0:[01]:[0-9]+)><>" connected, address "([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}):/) {
         $$stats{$3}{name}     = $1;
         $$stats{$3}{id}       = $2;
         $$stats{$3}{ip}       = $4;
         $$stats{$3}{joins}    ++;
      }
      elsif ($line =~ /^L ".+<[0-9]+><STEAM_(0:[01]:[0-9]+)><players>" has entered the game/) {
         $$stats{$1}{joins}++;
         $$stats{$1}{wasseen} = 1;
      }
      elsif ($line =~ /^L "(.+)<([0-9]+)><STEAM_(0:[01]:[0-9]+)><players>" stats: frags="(-?[0-9]+\.[0-9]{2})" deaths="([0-9]+)"/) {
         $$stats{$3}{score}      = Math::BigFloat->bzero unless(defined $$stats{$3}{score});
         $$stats{$3}{lastscore}  = Math::BigFloat->bzero unless(defined $$stats{$3}{lastscore});
         $$stats{$3}{deaths}     = 0 unless(defined $$stats{$3}{deaths});
         $$stats{$3}{lastdeaths} = 0 unless(defined $$stats{$3}{lastdeaths});

         my $score     = Math::BigFloat->new($4);
         my $lastscore = $score->copy;
         my $idx       = $2.'x'.(defined $$stats{$3}{joins} ? $$stats{$3}{joins} : 1);
      
         unless ($hold) {
            if ($score->bacmp($$stats{$3}{lastscore})) {
               if (exists $$stats{$3}{idx} && $idx eq $$stats{$3}{idx}) {
                  my $diff = $score->bsub($$stats{$3}{lastscore});
                  $$stats{$3}{score}->badd($diff) unless($diff->copy->babs > $maxinc);
                  say "old: $$stats{$3}{lastscore} | diff: $diff | new: $$stats{$3}{score}" if($debug);
               }
               else {
                  $$stats{$3}{score}->badd($score) unless($score->copy->babs > $maxinc);
                  say "old: $$stats{$3}{lastscore} | diff: $score | new: $$stats{$3}{score}" if($debug);
               }
            }

            if ($5 != $$stats{$3}{lastdeaths}) {
               if (exists $$stats{$3}{idx} && $idx eq $$stats{$3}{idx}) {
                  my $diff = $5 - $$stats{$3}{lastdeaths};
                  $$stats{$3}{deaths} += $diff;
               }
               else {
                  $$stats{$3}{deaths} += $5;
               }
            }
         }

         $$stats{$3}{name}       = $1;
         $$stats{$3}{id}         = $2;
         $$stats{$3}{idx}        = $idx;
         $$stats{$3}{lastscore}  = $lastscore->copy;
         $$stats{$3}{lastdeaths} = $5;
         $$stats{$3}{datapoints}++;
         $$stats{$3}{wasseen}   = 1;
      }
   }

   unless ($debug) {
      my $gi  = MaxMind::DB::Reader->new(file => $geo);
      my $sth = $dbh->prepare('REPLACE INTO stats (steamid64, steamid, name, id, score, lastscore, deaths, lastdeaths, scoregain, deathgain, joins, geo, lat, lon, datapoints, datapointgain, seen) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)');

      for (keys %{$stats}) {
         my ($country, $lat, $lon);

         if (defined $$stats{$_}{ip}) {
            my $record  = $gi->record_for_address($$stats{$_}{ip});

            if ($record) {
               $country = $record->{country}{iso_code};
               $lat     = $record->{location}{latitude};
               $lon     = $record->{location}{longitude};
            }
         }

         $sth->execute(
            idto64($_),
            $_,
            defined $$stats{$_}{name}          ? $$stats{$_}{name}       : undef,
            defined $$stats{$_}{id}            ? $$stats{$_}{id}         : undef,
            defined $$stats{$_}{score}         ? $$stats{$_}{score}      : 0,
            defined $$stats{$_}{lastscore}     ? $$stats{$_}{lastscore}  : 0,
            defined $$stats{$_}{deaths}        ? $$stats{$_}{deaths}     : 0,
            defined $$stats{$_}{lastdeaths}    ? $$stats{$_}{lastdeaths} : 0,
            defined $$stats{$_}{oldscore}      ? $$stats{$_}{score}->copy->bsub($$stats{$_}{oldscore}) : 0,
            defined $$stats{$_}{olddeaths}     ? $$stats{$_}{deaths}-$$stats{$_}{olddeaths}            : 0,
            defined $$stats{$_}{joins}         ? $$stats{$_}{joins}      : 1,
            defined $country                   ? $country                : defined $$stats{$_}{geo}  ? $$stats{$_}{geo}  : undef,
            defined $lat                       ? $lat                    : defined $$stats{$_}{lat}  ? $$stats{$_}{lat}  : undef,
            defined $lon                       ? $lon                    : defined $$stats{$_}{lon}  ? $$stats{$_}{lon}  : undef,
            defined $$stats{$_}{datapoints}    ? $$stats{$_}{datapoints} : 0,
            defined $$stats{$_}{olddatapoints} ? $$stats{$_}{datapoints}-$$stats{$_}{olddatapoints}    : 0,
            defined $$stats{$_}{wasseen}       ? $today                  : defined $$stats{$_}{seen} ? $$stats{$_}{seen} : undef
         );
      }
      $dbh->commit;

      $sth = $dbh->prepare('REPLACE INTO maps (map, count) VALUES (?,?)');

      for (keys %{$maps}) {
         $sth->execute($_, $$maps{$_}{count});
      }
      $dbh->commit;

      $sth = $dbh->prepare('REPLACE INTO misc (rowid, hold) VALUES (1,?)');
      $sth->execute($hold);
      $dbh->commit;

      $dbh->disconnect;
   }
   else {
      print Dumper(\%{$stats});
   }
}

sub idto64 {
   my $id = shift || return 0;
   my (undef, $authbit, $accnum) = split(':', $id);
   my $id64 = (($accnum * 2) + 76561197960265728 + $authbit);
 
   return $id64;
}

sub socketstream {
   print "Initializing...\n";

   my ($reclog, $hishost);
   
   $today = strftime '%Y-%m-%d', localtime;

   my $sock = IO::Socket::INET->new(
      LocalHost => $listenip,
      LocalPort => $port, 
      Proto => 'udp') or die "Socket error: $@\n";

   print "Listening for UDP messages on port $port...\n";
   
   while ($sock->recv($reclog, $buflength)) {
      # TODO: Restrict to specific addresses
      my ($origport, $origipaddr) = sockaddr_in($sock->peername);
      $hishost = inet_ntoa($origipaddr);

      # remove header and "log"
      my $sockline = substr($reclog, 8);

      # Remove NULL char from the end of stream
      $sockline =~ s/\0//g;

      # remove newline from the end of line
      chomp $sockline;

      if ($debug){
         print "($hishost:$origport) -> $sockline\n";
      }

      push @lines, $sockline;

      if ($sockline =~ /^L [0-9]{2}\/[0-9]{2}\/[0-9]{4} - ([0-9]{2}:[0-9]{2}:[0-9]{2}): Log file closed/) {
         print "Map has changed, flushing data to database...\n";
         procstats();
         print "Data has been saved!\n";
         @lines = (); # Clear array
         $today = strftime '%Y-%m-%d', localtime; # Hack: update today's var date
      }
   }
   die "recv: $!";
}
