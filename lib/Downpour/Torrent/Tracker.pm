#!/usr/bin/perl
# FIXME: add in gpl, author, etc

# this manages a connection to a tracker

# FIXME: add numwant support

package Downpour::Torrent::Tracker;

use strict;
use Downpour::BEncoder;
use LWP::UserAgent;

# global debug variable
use vars qw($DEBUG);
our $VERSION = 1.00;

sub d {
    if ($::DEBUG) {
        # use printf for debug stuff
        my $str = "Downpour::Torrent::Tracker::" . shift() . "\n";
        printf $str, @_;
    }
}

sub _fail {
    my $str = sprintf(shift() . "\n", @_);
    print STDERR $str;
    return undef;
}

sub eurl {
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_\,\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/; 
    return $a;
}

sub durl {
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

# new( Downpour::Torrent, [ opt => opt, ... ] )
sub new {
    my $class = shift;
    my $torrent = shift;
    my %opts = ( @_ );
    return _fail("need peer_id")
        unless $opts{peer_id};
    
    # now create our object
    d("new()");
    my $self = {
        ip       => $opts{ip},
        peer_id  => $opts{peer_id},
        _torrent => $torrent,
        _next_at => 0, # ensure we update
    };
    bless $self, $class;
    return $self;
}

# send out a request to the tracker to update our peer list... takes as
# input us and then options, which right now should probably only contain
# event => <started|stopped|completed> ...
#
# returns undef on failure or the number of peers we now know about
sub _sendRequest {
    my $self = shift;
    my $torrent = $self->{_torrent};

    d("_sendRequest()");
    my %opts = ( @_ );
    $opts{info_hash} = $torrent->getInfoDigest;
    $opts{peer_id} = $self->{peer_id};
    $opts{port} = $torrent->getListenPort;
    $opts{ip} = $self->{ip} if defined $self->{ip};

    # include transfer information
    $opts{uploaded} = $torrent->getBytesOut;
    $opts{downloaded} = $torrent->getBytesIn;
    $opts{left} = $torrent->getFileLength - $opts{downloaded};

    # create our query string
    my $querystr = '?' . join('&', map { "$_=" . eurl($opts{$_}) } keys %opts);

    my $ua = LWP::UserAgent->new;
    $ua->agent("Downpour::Tracker/$VERSION");
    $ua->from("junior\@danga.com");
    my $resp = $ua->get($torrent->getAnnounceURL() . $querystr);

    if ($resp->is_success) {
        my $res = bdecode($resp->content);
        return _fail("error: bdecode failed")
            unless $res && ref $res eq 'HASH';
        return _fail("error: $res->{'failure reason'}")
            if $res->{"failure reason"};

        # extract useful information
        $self->{_next_at} = time() + $res->{interval}
            if defined $res->{interval} && $res->{interval};
        $self->{_complete_peers} = $res->{complete};
        $self->{_incomplete_peers} = $res->{incomplete};

        # now extract our peer information
        my $now = time();
        $self->{_peers} ||= {};
        foreach my $peerref (@{$res->{peers} || []}) {
            # _peers contains { peer_id => { host => "ip:port", ... } }
            my $peer_id = $peerref->{"peer id"};
            $self->{_peers}->{$peer_id}->{host} = "$peerref->{ip}:$peerref->{port}";
            $self->{_peers_by_host}->{"$peerref->{ip}:$peerref->{port}"} = $peer_id;
            unless ($self->{_peers}->{$peer_id}->{known_at}) {
                d("_sendRequest(): new peer $self->{_peers}->{$peer_id}->{host}");
            }
            $self->{_peers}->{$peer_id}->{known_at} ||= $now;
        }

        return scalar(keys %{$self->{_peers}});
    } else {
        # failure!
        return _fail("error: " . $resp->status_line);
    }
}

# call whenever you want to update the list of peers, pass in a true value as
# the first and only argument if you want to ignore the interval timing mechanism
# and force a contact to the tracker
# return: undef on error, 0 on no update necessary, 1 on updated data
sub updatePeerList {
    # updates our list of peers if the interval is passed
    my ($self, $force) = @_;
    d("updatePeerList($force)");
    unless ($force) {
        my $now = time();
        return 0 if $self->{_next_at} > $now;
    }

    # simply do an update
    my $rv = $self->_sendRequest();
    return $rv unless defined $rv;
    return 1;
}

# this is called when we are instructed to start
sub doInitialize {
    my $self = shift;
    d("doInitialize()");
    $self->{_next_at} = 0;
    my $rv = $self->_sendRequest( event => 'started' );
    return undef unless defined $rv;
    return 1;
}

sub getHostByPeerId {
    my ($self, $peerid) = @_;
    return $self->{_peers}->{$peerid}->{host};
}

sub getPeerIdByHost {
    my ($self, $host) = @_;
    return $self->{_peers_by_host}->{$host};
}

sub getPeerList {
    my $self = shift;
    return $self->{_peers};
}

1;
