#!/usr/bin/perl
#FIXME: add in gpl, author, etc
# this manages a connection to a peer.

package Downpour::Torrent::Peer;

use strict;
use Downpour::Socket;

use base 'Downpour::Socket';

# global debug variable
use vars qw($DEBUG);
our $VERSION = 1.00;

sub d {
    if ($::DEBUG) {
        # use printf for debug stuff
        my $str = "Downpour::Torrent::Peer::" . shift() . "\n";
        printf $str, @_;
    }
}

sub _fail {
    my $str = sprintf(shift() . "\n", @_);
    print STDERR $str;
    return undef;
}

sub _makePacket {
    # use pack("N", $len)
}

#STILL NEED TO FIGURE OUT
#what happens when we get a bad data and have to close
#where do we save files (local directory with target file name? temporary name?)
#how do we get created?

# call this when you want this peer to become an active peer and start
sub doActivate {
    
}

sub event_read {
    my Downpour::Torrent::Peer $self = shift;

    # call the parent first so that they process any incoming packets we have
    $self->SUPER::event_read;
    return unless $self->packetsQueued;

    # get a packet
}
