#!/usr/bin/perl
# FIXME: add in gpl, author, etc

# this class is basically the manager that enables downloading of
# multiple torrent files at the same time with a set bandwidth
# limit, etc.

# FIXME: customize number of peers per torrent?  (based on bw limits?)
# FIXME: manageTorrents needs to allocate the download limit over all the torrents
#        and not just allocate it all to all of them... although maybe that's fine?
# FIXME: manageTorrents shouldn't iterate over the list 4 times...

package Downpour;

use strict;
use IO::Socket::INET;
use Time::HiRes qw(gettimeofday tv_interval);

# our libraries
use Downpour::Socket;
use Downpour::ManageSocket;
use Downpour::Torrent;

# global debug variable
use vars qw($DEBUG);
our $VERSION = '0.01';
our $PEER_ID = "-DP0100-"; # must be 8 bytes and include our version

sub d {
    if ($::DEBUG) {
        # use printf for debug stuff
        my $str = "Downpour::" . shift() . "\n";
        printf $str, @_;
    }
}

sub _fail {
    my $str = sprintf(shift() . "\n", @_);
    print STDERR $str;
    return undef;
}

sub new {
    my $class = shift;
    d("new()");
    my $self = {
        @_, # use provided options
        _active     => 0, # none active right now
        _max_active => 2, # two torrents at once
        _max_peers  => 20, # number of total peers per torrent
        _limit_down => 0, # no download limit
        _limit_up   => 0, # no upload limit
        _last_loop => undef, # time of last loop
        _torrents   => {},
        _torrent_list => [],
        _callback => undef,
        _next_track_at => 0, # time to next do tracking updates
        _sock => undef,
    };
    $self->{port} ||= 6882;
    bless $self, $class;

    # now setup the listening port
    $self->{_sock} = IO::Socket::INET->new(
        LocalPort => $self->{port},
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
    ) or return _fail("error: can't create server socket");

    # setup a handler for this one
    my $accept_handler = sub {
        my $csock = $self->{_sock}->accept;
        return _fail("error: accepted undef socket")
            unless defined $csock;
        my $peer = Downpour::Socket->new_from_sock($self, $csock)
            or return _fail("error: unable to create Downpour::Socket from $csock");
        $peer->watch_read(1);
    };

    # management listeneer
    $self->{_msock} = IO::Socket::INET->new(
        LocalPort => '6883',
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
    ) or return _fail("error: can't create management socket");

    # listening port for management connections
    my $m_accept_handler = sub {
        my $csock = $self->{_msock}->accept;
        return _fail("error: accepted undef management socket")
            unless defined $csock;
        my $mg = Downpour::ManageSocket->new($self, $csock)
            or return _fail("error: unable to create Downpour::ManageSocket from $csock");
        $mg->watch_read(1);
    };

    # register this server so it gets handled
    Downpour::Socket->AddOtherFds( fileno($self->{_sock})  => $accept_handler,
                                   fileno($self->{_msock}) => $m_accept_handler, );
    d("new(): listening socket setup and ready");

    # do other setup
    Downpour::Socket->SetLoopTimeout(1000);
    Downpour::Socket->SetPostLoopCallback(sub {
        my $diff;
        if ($self->{_last_loop}) {
            my $now = [ gettimeofday() ];
            $diff = tv_interval($self->{_last_loop}, $now);
            $self->{_last_loop} = $now;
        } else {
            $self->{_last_loop} = [ gettimeofday() ];
            $diff = 0.1; # assume 100ms
        }

        # now calculate the bandwidth limit
        my $ubytes;
        my $ulimit = $self->getUploadLimit;
        if ($ulimit > 0) {
            $ubytes = ($ulimit * $diff);
        } else {
            $ubytes = -1;
        }

        # now manage our torrents but use $diff as the 'estimated timeslice' for doing writes
        $self->manageTorrents($ubytes);

        # now call the parent's callback if they have one
        $self->{_callback}->()
            if $self->{_callback};

        select undef, undef, undef, 0.2;
        return 1;
    });

    # finally done, return
    return $self;
}

sub run {
    my Downpour $self = shift;
    $self->{_callback} = shift;
    Downpour::Socket->EventLoop;
}

sub generatePeerId {
    my $self = shift;
    return $self->{_peer_id} ||=
               ($PEER_ID . sprintf("%06x%06x", rand(0xffffff), rand(0xffffff)));
}

sub getDownloadLimit { return $_[0]->{_limit_down} || 0;        }
sub getUploadLimit   { return $_[0]->{_limit_up} || 0;          }
sub setDownloadLimit { return $_[0]->{_limit_down} = ($_[1]+0); }
sub setUploadLimit   { return $_[0]->{_limit_up} = ($_[1]+0);   }
sub setMaxActive     { return $_[0]->{_max_active} = ($_[1]+0); }
sub getMaxActive     { return $_[0]->{_max_active} || 0;        }
sub getListenPort    { return $_[0]->{port} || 6881;            }
sub getMaxPeers      { return $_[0]->{_max_peers} || 20;        }
sub setMaxPeers      { return $_[0]->{_max_peers} = ($_[1]+0);  }

# total number of bytes we've received based on current torrents
sub getBytesIn {
    my $self = shift;
    my $n = 0;
    foreach my $digest (@{$self->{_torrent_list} || []}) {
        my $torref = $self->{_torrents}->{$digest};
        $n += $torref->{torrent}->getBytesIn;
    }
    return $n;
}

# returns total number of bytes we've sent based on all our current torrents
sub getBytesOut {
    my $self = shift;
    my $n = 0;
    foreach my $digest (@{$self->{_torrent_list} || []}) {
        my $torref = $self->{_torrents}->{$digest};
        $n += $torref->{torrent}->getBytesOut;
    }
    return $n;
}

# first parameter is a string, either a filename or URL (http prefixed) to
# a .torrent file to add to our manager
sub addTorrent {
    my ($self, $torr) = @_;
    d("addTorrent($torr)");

    my $torrent = Downpour::Torrent->new( $self,
        peer_id => $self->generatePeerId
    );

    if ($torr =~ /^http/) {
        $torrent->loadFromURL($torr)
            or return _fail("failed to add as URL");
    } else {
        $torrent->loadFromFile($torr)
            or return _fail("failed to add as file");
    }

    # debugging information?
    d('addTorrent(): %d bytes', $torrent->getFileLength);
    d('addTorrent(): %d pieces of %d bytes each', $torrent->getPieceCount, $torrent->getPieceLength);

    # add to list of our turrents
    my $digest = $torrent->getInfoDigest;
    $self->{_torrents}->{$digest} = {
        torrent => $torrent,
        active => 0, # on if this one is tracking
        dead => 0,   # on if this has failed somehow
    };
    push @{$self->{_torrent_list}}, $digest; # order added
 
    return 1;
}

# called with the single argument of an info digest; returns either
# a torrent object or undef on not found
sub getByDigest {
    my Downpour $self = shift;
    my $digest = shift;

    return unless $self->{_torrents}->{$digest};
    return $self->{_torrents}->{$digest}->{torrent};
}

# call this every time you want Downpour to process events
sub manageTorrents {
    my $self = shift;
    my $ubytes = shift() + 0;
    #d("manageTorrents()");

    # step 1: activate any torrents that need activating
    if ($self->{_active} < $self->{_max_active}) {
        #d("manageTorrents(): need to activate a torrent");
        foreach my $digest (@{$self->{_torrent_list} || []}) {
            my $torref = $self->{_torrents}->{$digest};
            next if $torref->{active} || $torref->{dead};
            d('manageTorrents(): activating %s', $torref->{torrent}->getFileName);

            # yes, active this one?
            unless ($torref->{torrent}->beginTracking) {
                # bleh, mark this as errored, for reaping
                d("manageTorrents(): beginTracking failed, marking dead");
                $torref->{dead} = 1;
                next;
            }

            # update counter and last, only begin tracking one per loop
            d("manageTorrents(): torrent activated");
            $torref->{active} = 1;
            $self->{_active}++;
            last;
        }
    }

    # step 2: main loop over active torrents to update peer information
    # that we might have... this can't happen more than once every few seconds
    my $now = time();
    if ($self->{_next_track_at} <= $now) {
        foreach my $torref (values %{$self->{_torrents}}) {
            next unless $torref->{active} && !$torref->{dead};
            $torref->{torrent}->doTracking;
        }
        $self->{_next_track_at} = $now + 5;
    }

    # step 3: launch new peers to get to minimum desired per torrent
    foreach my $torref (values %{$self->{_torrents}}) {
        next unless $torref->{active} && !$torref->{dead};
        next if $torref->{torrent}->getPeerCount >= 10; # wanted peers per torrent
        $torref->{torrent}->spawnPeer;
    }

    # now process outgoing writes based on the number of bytes we've been asked to send
    foreach my $torref (values %{$self->{_torrents}}) {
        next unless $torref->{active} && !$torref->{dead};
        $torref->{torrent}->processWrites($ubytes);
    }

    return;
}

1;
