#!/usr/bin/perl

use strict;
use vars qw($DEBUG);
$DEBUG = 1;
use Data::Dumper;
use Downpour;

$| = 1;

my $dp = new Downpour;
$dp->setDownloadLimit(5 * 1024); # 5k down a second
$dp->setUploadLimit(5 * 1024); # 5k up a second

print "Adding a torrent...\n";

# add a web site
$dp->addTorrent("http://www.example.com/foo.torrent")
    or die "failed to add torrent to manager\n";

# or perhaps a file
$dp->addTorrent("myfile.torrent")
    or die "failed to add torrent to manager\n";

my ($li, $lo, $n);

print "Beginning main loop...\n";
$dp->run(\&callback);

sub callback {
    # this does all the work of handling our torrents
    #$dp->manageTorrents;

    # show stats only every second
    if (++$n % 50 == 0) {
        # now print some stat stuff
        my $bi = $dp->getBytesIn;  $li ||= $bi;  my $di = $bi - $li;
        my $bo = $dp->getBytesOut; $lo ||= $bo;  my $do = $bo - $lo;
        print "bytes in = $bi ($di), bytes out = $bo ($do)\n";
        $li = $bi; $lo = $bo;
    }
}

# must be done?
print "Done downloading everything?\n";
