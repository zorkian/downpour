#!/usr/bin/perl
# FIXME: add gpl, author, etc

# base class for communicating with a peer.  very simply just handles
# packets in and out and stores them in a packet buffer.

# FIXME: make this check if the remote version is understandable.. otherwise we end
#        up failing as soon as it changes?
# FIXME: no way to send no-op packets... do we need to send them?
# FIXME: if a peer connects to us twice, we don't care... we should probably
#        kill off their new connection...

package Downpour::Socket;

use strict;

use Socket qw(PF_INET SOCK_STREAM IPPROTO_TCP);
use Danga::Socket;
use IO::Handle;

use base 'Danga::Socket';

use fields ('_sent_handshake',
            '_got_handshake',
            '_initiator',        # bool; true if we initiated the connection
            '_am_choking',
            '_peer_choking',
            '_am_interested',
            '_peer_interested',
            '_peer_has',         # array; pieces the peer has
            '_buf',              # string; buffer of data
            '_alive_at',         # last time we got a packet from the remote
            '_remote_peer_id',
            '_remote_info_digest',
            '_remote_version',
            '_peer_requests',    # [ [ pid, begin, len ], ... ]; what THEY want from us
            '_blocks_rcvd',      # number of blocks we've received from them
            '_blocks_sent',      # number of blocks we've sent to them
            '_dp',               # Downpour; our manager
            '_torrent',          # Downpour::Torrent; the torrent we're working on
            '_bytes_out',
            '_bytes_in',
            '_send_buf',         # buffer of raw bytes to send
            );

# constants used in sending/receiving packets
use constant ID_CHOKE        => 0;
use constant ID_UNCHOKE      => 1;
use constant ID_INTERESTED   => 2;
use constant ID_UNINTERESTED => 3;
use constant ID_HAVE         => 4;
use constant ID_BITFIELD     => 5;
use constant ID_REQUEST      => 6;
use constant ID_PIECE        => 7;
use constant ID_CANCEL       => 8;

# global debug variable
use vars qw($DEBUG);
our $VERSION = 1.00;
our $PEER_ID = "-DP0100-"; # must be 8 bytes

sub d {
    if ($::DEBUG) {
        # use printf for debug stuff
        my $str = "Downpour::Socket::" . shift() . "\n";
        printf $str, @_;
    }
}

sub _fail {
    my $str = sprintf(shift() . "\n", @_);
    print STDERR $str;
    return undef;
}

# accept an incoming connection
sub new_from_sock {
    my Downpour::Socket $self = shift;
    d("new_from_sock()");

    $self = fields::new($self) unless ref $self;

    my Downpour $dp = shift;

    $self->SUPER::new(@_);
    $self->_setup;

    $self->{_dp} = $dp;
    $self->watch_read(1);

    return $self;
}

# create a new outgoing socket
sub new_to_host {
    my ($self, $dp, $ipport, $torrent) = @_;
    d("new_to_host($ipport)");

    return _fail("error: failed to parse $ipport")
        unless $ipport =~ /^(.+?)(?::(\d+))?$/;
    my ($ip, $port) = ($1, $2 || 6881);

    $self = fields::new($self) unless ref $self;

    my $sock;
    socket $sock, PF_INET, SOCK_STREAM, IPPROTO_TCP;

    unless ($sock && defined fileno($sock)) {
        return _fail("error: failed creating socket: $!");
    }

    IO::Handle::blocking($sock, 0);
    connect $sock, Socket::sockaddr_in($port, Socket::inet_aton($ip));

    $self->SUPER::new($sock);
    $self->_setup;

    # now since we're connecting to them...
    $self->{_torrent} = $torrent;
    $self->{_dp} = $dp;
    $self->{_initiator} = 1;
    $self->watch_write(1);

    return $self;
}

# this is here to reset everything in both of our new cases
sub _setup {
    my Downpour::Socket $self = shift;
    $self->{_got_handshake} = 0;
    $self->{_sent_handshake} = 0;
    $self->{_am_choking} = 1; # per spec, it starts this way
    $self->{_peer_choking} = 1;
    $self->{_am_interested} = 0;
    $self->{_peer_interested} = 0;
    $self->{_peer_has} = undef;
    $self->{_alive_at} = 0;
    $self->{_initiator} = 0;
    $self->{_buf} = '';
    $self->{_send_buf} = '';
    $self->{_bytes_out} = 0;
    $self->{_bytes_in} = 0;
    $self->{_remote_peer_id} = undef;
    $self->{_remote_info_digest} = undef;
    $self->{_remote_version} = undef;
    $self->{_peer_requests} = [];
    $self->{_torrent} = undef;
    $self->{_dp} = undef;
    $self->{_blocks_sent} = 0;
    $self->{_blocks_rcvd} = 0;
}

sub getBytesOut {
    my Downpour::Socket $self = shift;
    my $b = $self->{_bytes_out};
    $self->{_torrent}->addBytesOut($b);
    $self->{_bytes_out} = 0;
    return $b;
}

sub getBytesIn {
    my Downpour::Socket $self = shift;
    my $b = $self->{_bytes_in};
    $self->{_torrent}->addBytesIn($b);
    $self->{_bytes_in} = 0;
    return $b;
}

sub close {
    my Downpour::Socket $self = shift;
    my $reason = shift() || '';
    d("close(): reason=$reason");
    $self->SUPER::close($reason);
}

sub event_write {
    my Downpour::Socket $self = shift;
    if ($self->{_initiator} && !$self->{_sent_handshake}) {
        # send a handshake out
        $self->sendHandshake;
    }
}

# getters for some of the valuable things to know!
sub amChoking { return $_[0]->{_am_choking}; }
sub peerChoking { return $_[0]->{_peer_choking}; }
sub amInterested { return $_[0]->{_am_interested}; }
sub peerInterested { return $_[0]->{_peer_interested}; }

# see if the peer has a piece
sub peerHasPiece {
    my Downpour::Socket $self = shift;
    my $pid = shift() + 0;
    return _fail("error: piece id ($pid) out of range")
        if $pid < 0 || $pid >= $self->{_torrent}->getPieceCount;
    return $self->{_peer_has}->[$pid] ? 1 : 0;
}

# setters that set and send a packet to notify the other end what's up
sub startChoking {
    my Downpour::Socket $self = shift;
    return if $self->{_am_choking};
    $self->sendPacket(ID_CHOKE);
    $self->{_am_choking} = 1;
}

sub stopChoking {
    my Downpour::Socket $self = shift;
    return unless $self->{_am_choking};
    $self->sendPacket(ID_UNCHOKE);
    $self->{_am_choking} = 0;
}

sub appearInterested {
    my Downpour::Socket $self = shift;
    return if $self->{_am_interested};
    $self->sendPacket(ID_INTERESTED);
    $self->{_am_interested} = 1;
}

sub appearUninterested {
    my Downpour::Socket $self = shift;
    return unless $self->{_am_interested};
    $self->sendPacket(ID_UNINTERESTED);
    $self->{_am_interested} = 0;
}

sub sendHandshake {
    my Downpour::Socket $self = shift;
    d("sendHandshake()");
    my $packet = chr(19) .                           # length of next string (19)
                 'BitTorrent protocol' .             # 19 byte protocol name
                 pack("NN", 0, 0) .                  # 8 byte reserved
                 $self->{_torrent}->getInfoDigest .  # 20 byte info_hash
                 $self->{_torrent}->getPeerId;       # 20 byte peer_id
    $self->write($packet);
    $self->{_sent_handshake} = 1;

    # now we want to create a bitfield to push down to the remote host so
    # they know what we have
    my $pc = $self->{_torrent}->getPieceCount;
    my $bytect = int($pc / 8) + ($pc % 8 ? 1 : 0);
    my $bf = '';
    for (my $idx = 0; $idx < $bytect; $idx++) {
        my $cur = 0;
        for (my $bit = 0; $bit < 8; $bit++) {
            my $pid = ($idx * 8) + $bit;
            next if $pid >= $pc; # don't overrun
            next unless $self->{_torrent}->hasPiece($pid);
            $cur &= 1 << $bit;
        }
        $bf .= chr($cur);
    }
    $self->sendPacket(ID_BITFIELD, $bf);
    $self->watch_read(1);

    # tell our torrent that we sent a handshake
    $self->{_torrent}->noteHandshakeSent($self);
}

sub event_read {
    my Downpour::Socket $self = shift;

    # read in data
    my $bref = $self->read(64 * 1024); # read 64k at most at once
    return $self->close('undef_read')
        unless defined $bref;
    $self->{_buf} .= $$bref;
    $self->{_bytes_in} += length $$bref;

    # get buf len
    my $buflen = length $self->{_buf};
    return unless $buflen > 0;

    # if this is the first packet, it's a handshake.
    unless ($self->{_got_handshake}) {
        my $len = unpack("C", $self->{_buf});
        my $calclen = 1 + $len + 8 + 20 + 20;
        return unless $buflen >= $calclen;

        # okay, it's good, break it apart
        my ($vstr, $reserved, $info_hash, $peer_id) =
            (substr($self->{_buf}, 1, $len),
             substr($self->{_buf}, $len + 1, 8),
             substr($self->{_buf}, $len + 9, 20),
             substr($self->{_buf}, $len + 29, 20));
        substr($self->{_buf}, 0, $calclen) = '';

        # copy these things into internal storage
        $self->{_remote_peer_id} = $peer_id;
        $self->{_remote_info_digest} = $info_hash;
        $self->{_remote_version} = $vstr;

        # show debugging info?
        d("event_read(): got handshake: version=$vstr");#; hash=$info_hash; peer=$peer_id");
        $self->{_got_handshake} = 1;

        # we got one, if we aren't the initiated, we need to reply
        unless ($self->{_initiator}) {
            # but first, find out if we're serving this digest
            my $torrent = $self->{_dp}->getByDigest($info_hash);
            if ($torrent) {
                $self->{_torrent} = $torrent;
                $self->{_peer_has} = [ map { 0 } 1..$torrent->getPieceCount ];
                $torrent->registerIncoming($self);
                return if $self->{closed};
                $self->sendHandshake;
            } else {
                # fail; they wanted something we're not serving
                $self->close("requested_bad_digest");
            }
        }
    }

    # now pop packets
    $self->{_alive_at} = time;
    while (length $self->{_buf} >= 4) {
        my $len = unpack("N", $self->{_buf});

        # special no-op packet
        if ($len == 0) {
            substr($self->{_buf}, 0, 4) = '';
            next;
        }

        # see if we have enough data
        last unless length $self->{_buf} >= $len;

        # must be, get the packet, remove from buffer
        my $payload = substr($self->{_buf}, 4, $len);
        substr($self->{_buf}, 0, $len + 4) = '';

        # now split into id + payload
        my ($id, $body) = unpack("Ca*", $payload);
        if ($id == ID_CHOKE) {
            $self->{_peer_choking} = 1;

        } elsif ($id == ID_UNCHOKE) {
            $self->{_peer_choking} = 0;

        } elsif ($id == ID_INTERESTED) {
            $self->{_peer_interested} = 1;

        } elsif ($id == ID_UNINTERESTED) {
            $self->{_peer_interested} = 0;

        } elsif ($id == ID_HAVE) {
            return $self->close("id_have:body_invalid")
                unless length $body == 4;
            my $pid = unpack("N", $body);
            return $self->close("id_have:pid_invalid")
                if $pid >= $self->{_torrent}->getPieceCount;
            $self->{_peer_has}->[$pid] = 1;

        } elsif ($id == ID_BITFIELD) {
            my $pc = $self->{_torrent}->getPieceCount;
            my $explen = int($pc / 8) + ($pc % 8 ? 1 : 0);
            return $self->close("id_bitfield:body_invalid")
                unless length $body == $explen;

            # it works.
            foreach my $idx (0..$pc-1) {
                my $byte = ord(substr($body, int($idx / 8), 1));
                my $bit = 1 << (7 - ($idx % 8));
                $self->{_peer_has}->[$idx] = ($byte & $bit) ? 1 : 0;
            }

            # debugging information
            if ($DEBUG) {
                my $ct = scalar(grep { $_ } @{$self->{_peer_has}});
                my $max = scalar(@{$self->{_peer_has}});
                d('event_read(): peer has %d/%d pieces', $ct, $max);
            }

        } elsif ($id == ID_REQUEST) {
            my ($idx, $begin, $len) = unpack("NNN", $body);
            if ($len > 2**17) {
                # "a client should close the conneciton if it receives a request for
                # more than 2^17 bytes." -- okay.
                return $self->close("id_request:wants_too_much:$len");
            }
            push @{$self->{_peer_requests}}, [ $idx, $begin, $len ];

        } elsif ($id == ID_PIECE) {
            my ($idx, $begin) = unpack("NN", $body);
            $body = substr($body, 8);
            $self->{_blocks_rcvd}++;
            $self->{_torrent}->receivedBlock($self, $idx, $begin, length $body, $body);

        } elsif ($id == ID_CANCEL) {
            my ($idx, $begin, $len) = unpack("NNN", $body);
            my @new;
            foreach my $req (@{$self->{_peer_requests}}) {
                next if $req->[0] == $idx &&
                        $req->[1] == $begin &&
                        $req->[2] == $len;
                push @new, $req;
            }
            $self->{_peer_requests} = \@new;

        } else {
            # error? close connection
            return $self->close("packet_id_invalid:$id");
        }
    }
}

sub event_err {
    my Downpour::Socket $self = shift;
    d("event_err(): trigged on $self");
    return $self->close("event_err");
}

sub event_hup {
    my Downpour::Socket $self = shift;
    d("event_hup(): trigged on $self");
    return $self->close("event_hup");
}

sub getRemotePeerId {
    my Downpour::Socket $self = shift;
    return $self->{_remote_peer_id};
}

# queue up a packet to send.  parameters are $id and $payload, the
# first is a number of the packet type, the second a string of data to send.
sub sendPacket {
    my Downpour::Socket $self = shift;
    my ($id, $payload) = @_;
    return _fail("error: sendPacket called with invalid inputs")
        unless defined $id;
    $payload ||= '';
#d('sendPacket(%d, %d)', $id, length $payload);
    $self->{_blocks_sent}++ if $id == ID_PIECE;

    # write out this data and make ourselves watchable
    my $len = pack("N", 1 + length($payload));
    my $packet = $len . chr($id) . $payload;
    $self->{_bytes_out} += (4 + $len);
    $self->write($packet);
}

sub getSendBufferSize {
    my Downpour::Socket $self = shift;
    return 0 if $self->{closed};
    return (length $self->{_send_buf}) + 0;
}

# given a number of bytes to send, send that many bytes from our pending send
# buffer.  returns the number of bytes sent.  you can also specify a parameter
# of -1 meaning to send everything.
sub sendFromBuffer {
    my Downpour::Socket $self = shift;
    return 0 if $self->{closed};
    return 0 unless $self->{_send_buf};

    # get the bytes and make sure they're in range
    my $bytes = shift() + 0;
    return 0 unless $bytes != 0;
    $bytes = length $self->{_send_buf}
        if length $self->{_send_buf} < $bytes || $bytes == -1;

    # now write out these bytes
    $self->write(substr($self->{_send_buf}, 0, $bytes));
    substr($self->{_send_buf}, 0, $bytes) = '';
    $self->{_bytes_out} += $bytes;
    return $bytes;
}

# queue up a piece to be sent to this connection, the Downpour manager will
# later actually handle telling us to send out some bytes
sub enqueuePiece {
    my Downpour::Socket $self = shift;
    return if $self->{closed};

    my ($pid, $idx, $data) = @_;
    my $packet = pack("NNN", 1 + 4 + 4 + length $data, $pid, $idx) . $data;
    $self->{_send_buf} .= $packet;

    return 1;
}

# send a piece to this connection immediately, no delay
sub sendPiece {
    my Downpour::Socket $self = shift;
    return if $self->{closed};

    my ($pid, $idx, $data) = @_;
    return $self->sendPacket(ID_PIECE, pack("NN", $pid, $idx) . $data);
}

sub notePieceReceived {
    my Downpour::Socket $self = shift;
    return if $self->{closed};

    $self->sendPacket(ID_HAVE, pack("N", shift));
}

# get the next request of theirs; returns arrayref or undef
sub popRequest {
    my Downpour::Socket $self = shift;
    return if $self->{closed};

    my $ref = pop(@{$self->{_peer_requests} || []});
    return $ref;
}

# see how many requests are outstanding
sub countOutstandingRequests {
    my Downpour::Socket $self = shift;
    return scalar(@{$self->{_peer_requests} || []});
}

sub getBlocksReceived {
    my Downpour::Socket $self = shift;
    my $n = $self->{_blocks_rcvd};
    $self->{_blocks_rcvd} = 0;
    return $n;
}

sub getBlocksSent {
    my Downpour::Socket $self = shift;
    my $n = $self->{_blocks_sent};
    $self->{_blocks_sent} = 0;
    return $n;
}

sub sendRequest {
    my Downpour::Socket $self = shift;
    my ($pid, $idx, $len) = @_;
    return _fail("sendRequest($pid, $idx, $len): invalid arguments")
        unless defined $pid && defined $idx && defined $len && $len > 0;
    return $self->sendPacket(ID_REQUEST, pack("NNN", $pid, $idx, $len));
}

sub bothHandshakesDone {
    my Downpour::Socket $self = shift;
    return $self->{_sent_handshake} && $self->{_got_handshake};
}

sub as_string {
    my Downpour::Socket $self = shift;
    my $res = $self->SUPER::as_string;
    $res .= "; handshakes: sent=$self->{_sent_handshake}, got=$self->{_got_handshake}";
    $res .= "; initiator" if $self->{_initiator};
    my @n;
    push @n, "choking" if $self->amChoking;
    push @n, "interested" if $self->amInterested;
    $res .= ("; am: " . join(', ', @n)) if @n;
    my @m;
    push @m, "choking" if $self->peerChoking;
    push @m, "interested" if $self->peerInterested;
    $res .= ("; peer: " . join(', ', @m)) if @m;
    return $res;
}

1;
