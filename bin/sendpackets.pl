#!/usr/bin/perl

# testing script that just sends packets...

use IO::Socket::INET;

my $sock = IO::Socket::INET->new(PeerAddr => 'localhost:6881')
    or die;

# send a handshake
my $digest = 'x' x 20;
my $peerid = 'y' x 20;
my $verstr = 'z' x 10;
my $reserved = '!' x 8;
my $len = length $verstr;
my $handshake = chr($len) . $verstr . $reserved . $digest . $peerid;

my $i = 0;
while ($i < length($handshake)) {
    $sock->print(substr($handshake, $i++, 1));
    $sock->flush;
    select undef, undef, undef, 0.01;
}

# now send a packet
my $len = pack("N", 100);
my $payload = '1' . ('x'x99);
my $packet = $len . $payload;
$sock->print($packet);
$sock->flush;
