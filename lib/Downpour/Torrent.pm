#!/usr/bin/perl
# FIXME: add in gpl, author, etc

# this package contains the Torrent class which handles a single torrent

# NOTE: a "pid" is a "piece id", not a "process id"...

# FIXME: add support for announce-list (http://home.elp.rr.com/tur/multitracker-spec.txt)
# FIXME: allow specifying external IP to beginTracking()
# FIXME: if pieces file gets deleted, reconstruct it with SHA1 digests to the regular file
# FIXME: more efficient construction of the shell file (avoid swap?)
# FIXME: better handling when we fail to get a block
# FIXME: don't connect to ourselves! :)
# FIXME: allow the creation of the wanted block list /after/ we've started downloading?

package Downpour::Torrent;

use strict;
use Downpour::BEncoder;
use Downpour::Torrent::Tracker;
use LWP::Simple;
use Digest::SHA1 qw(sha1);
use Carp qw(croak);

# global debug variable
use vars qw($DEBUG);

# constants
use constant BLOCK_LENGTH => 16 * 1024; # we use these sized blocks... arbitrary?

# setup our fields
use fields ('_next_choke_at',   # time to next do a choking run
            '_dp',              # our Downpour manager
            '_piece_count',     # internal cache of count of pieces
            '_block_count',     # number of blocks per piece
            '_block_sizes',     # [ size, size, size, ... ]; array of sizes for blocks
            '_info_digest',     # SHA1 digest of the bencoded _t hash
            '_t',               # info hash from the torrent
            '_tracker',         # our Downpour::Torrent::Tracker object
            '_fh',              # the actual file we're writing to/reading from
            '_pfh',             # pieces file, records pieces we have
            '_pieces',          # [ 1, 0, 1, 0, 0, ... ]; whether or not we have this piece
            '_blocks',          # [ { start => length }, ... ]; array of hashref (array is _piece_count items long)
            '_want_list',       # [ [ pid, index, length], ... ]; randomized list of blocks we still need
            '_bytes_out',       # bytes we've sent, fairly simple
            '_bytes_in',        # bytes we've received, in total
            '_peers',           # { remote_peer_id => Downtour::Socket }; connection to a peer (in or out)
            '_blocks_out',      # { peer_id => [ [ pid, begin, length ], ... ] }; what blocks we have pending to a peer
            '_tried_peers',     # { peer_id => time }; what time we last connected to this peer

            'peer_id',          # OUR peer id
            'path',             # where we store files
        );


sub d {
    if ($::DEBUG) {
        # use printf for debug stuff
        my $str = "Downpour::Torrent::" . shift() . "\n";
        printf $str, @_;
    }
}

sub _fail {
    my $str = sprintf(shift() . "\n", @_);
    print STDERR $str;
    return undef;
}

# get in some options:
# ->new(
#     peer_id     => "",   # 20 byte string to represent this peer
#     path        => "",   # path to store downloaded files.. partials are stored in $path/partial
# );
sub new {
    my $self = shift;
    $self = fields::new($self) unless ref $self;

    d("new()");

    $self->{_dp} = shift;
    $self->{_blocks_out} = {};
    $self->{_peers} = {};
    $self->{_tried_peers} = {};

    while (my ($key, $val) = (shift(@_), shift(@_))) {
        last unless $key && $val;
        $self->{$key} = $val;
    }
    return _fail("first argument to Torrent->new must be a Downpour object")
        unless $self->{_dp} && ref $self->{_dp};

    if ($self->{peer_id} && length $self->{peer_id} != 20) {
        return _fail("peer_id must be 20 bytes long");
    }

    $self->{path} ||= '.';
    unless (-e $self->{path} && -d _) {
        return _fail("path does not exist or is not directory");
    }

    return $self;
}

# input: file to load torrent from
# returns: same as _parseTorrentData (undef on error)
sub loadFromFile {
    my ($self, $fn) = @_;
    d("loadFromFile($fn)");

    # file exists, can open
    return _fail("file doesn't exist")
        unless -e $fn;
    open FILE, "<$fn"
        or return _fail("can't open file: $!");
    my $dat;
    { local $/ = undef; $dat = <FILE>; }
    close FILE;

    return _fail("file has no data")
        unless $dat;
    return $self->_parseTorrentData($dat);
}

# input: URL to load torrent from
# returns: same as _parseTorrentData (undef on error)
sub loadFromURL {
    my ($self, $url) = @_;
    d("loadFromURL($url)");

    my $dat = get($url);
    return _fail("file has no data")
        unless $dat;
    return $self->_parseTorrentData($dat);
}

# input: string containing bencoded torrent file
# returns: string filename we're ready to handle
sub _parseTorrentData {
    my ($self, $data) = @_;
    d('_parseTorrentData(%d bytes)', length $data);

    my $res = bdecode($data);
    return _fail("bdecode() returned non-hashref")
        unless $res && ref $res eq 'HASH';

    # we can't handle multiple files yet...
    return _fail("can't handle multi-file torrents yet")
        if $res->{info}->{files} && ref $res->{info}->{files};

    # do some sanity checking on our input
    return _fail("torrent does not specify a filename")
        unless $res->{info}->{name};
    return _fail("torrent doesn't have a file length")
        unless $res->{info}->{length};
    return _fail("torrent has an invalid piece length")
        unless $res->{info}->{"piece length"};
    return _fail("torrent has digest string of wrong length")
        if length($res->{info}->{pieces}) % 20;
    return _fail("torrent doesn't provide an announce URL")
        unless $res->{announce};

    # do some information pre-calculation
    my $len = $res->{info}->{length};
    my $psize = $res->{info}->{"piece length"};
    my $n = int($len / $psize);
    my $b = $n * $psize;
    $n += 1 if $b < $len;
    $self->{_piece_count} = $n;
    return _fail("piece count came out to be $n")
        unless $n;
    d("_parseTorrentData(): $n pieces in file");

    # now save the info, it's likely valid
    $self->{_t} = $res;
    $self->{_info_digest} = sha1(bencode($self->{_t}->{info}));

    # now setup for doing stuff with the file
    $self->_initFile
        or return _fail("unable to intialize file");

    # save $res and return the filename
    return $self->{_t}->{info}->{name};
}

# call this with an optional argument indicating how many peers to spawn to
# cause us to find some unconnected peers and connect to them
sub spawnPeer {
    my ($self, $ct) = @_;
    $ct ||= 1;
    d("spawnPeer($ct)");

    my $list = $self->{_tracker}->getPeerList;
    return _fail("getPeerList didn't return a hashref")
        unless $list && ref $list eq 'HASH';

    my $total = 0;
    my $now = time();
    foreach my $peerid (keys %$list) {
        next if $self->{_peers}->{$peerid} &&
                !$self->{_peers}->{$peerid}->{closed};
        next if $self->{_tried_peers}->{$peerid} &&
                $self->{_tried_peers}->{$peerid} < ($now + 60);
        $self->{_tried_peers}->{$peerid} = $now;
        my $pobj = Downpour::Socket->new_to_host($self->{_dp}, $list->{$peerid}->{host}, $self)
            or next;            
        $self->{_peers}->{$peerid} = $pobj;
        d("spawnPeer(): spawned connection to $list->{$peerid}->{host}");
        last if ++$total >= $ct;
    }
}

# called by a socket when they're done connecting with someone
sub noteHandshakeSent {
    my ($self, $sock) = @_;
    d("noteHandshakeSent()");
}

# returns the number of open peers we have
sub getPeerCount {
    my $self = shift;
    return scalar(grep { !$_->{closed} }
                    values %{$self->{_peers} || {}});
}

# returns the number of peers we have unchoked
sub getUnchokedCount {
    my $self = shift;
    return scalar(grep { !$_->{closed} && !$_->amChoking }
                    values %{$self->{_peers} || {}});
}

# call with one argument: peer_id (20 bytes to use as your peer id)... call this
# when you want us to get a list of peers and get ready for doing tracking management.
# returns undef on error and 1 on success
sub beginTracking {
    my ($self, $peer_id) = @_;
    $self->{peer_id} = $peer_id if $peer_id;
    $peer_id ||= $self->{peer_id};
    return _fail("need peer_id") unless $peer_id;
    d("beginTracking($peer_id)");

    my $tracker = Downpour::Torrent::Tracker->new( $self,
        ip => undef, # our external ip
        peer_id => $peer_id,
    ) or return _fail("can't create tracker");

    $self->{_tracker} = $tracker;
    $self->{_tracker}->doInitialize
        or return _fail("unable to initialize tracker");

    return 1;
}

# call this when we should update our internal status and handle things we know about
sub doTracking {
    my $self = shift;
    d("doTracking()");
    $self->{_tracker}->updatePeerList;

    # do a choke/unchoke run if necessary
    my $now = time();
    if ($self->{_next_choke_at} <= $now) {
        d("doTracking(): performing choke/unchoke logic");

        # we're going to need this later... it's a hash of piece ids we need
        my %need;
        foreach my $row (@{$self->{_want_list}}) {
            next unless defined $row;
            $need{$row->[0]} = 1;
        }
        #my %need = ( map { $_->[0] => 1 } @{$self->{_want_list}} );

        # iterate over everything
        my %points; # { peerid => points }
        while (my ($peerid, $pobj) = each %{$self->{_peers}}) {
            print $pobj->as_string() . "\n";

            # if they're closed, drop them
            if ($pobj->{closed}) {
                foreach my $bref (@{$self->{_blocks_out}->{$peerid} || []}) {
                    # put this back in our block list
                    unshift @{$self->{_want_list}}, $bref;
                }
                delete $self->{_blocks_out}->{$peerid};

                # nothing more to do with this one
                next;
            }

            # ignore a peer that we haven't handshaked with
            next unless $pobj->bothHandshakesDone;

            # add points for blocks they've sent us recently
            my $pts = $pobj->getBlocksReceived;
            $pts = 5 if $pts > 5;

            # now, bonus if they're interested in us
            $pts += 2 if $pobj->peerInterested;

            # now add some points if they have things we want
            my $n = 0;
            foreach my $pid (keys %need) {
                $n++ if $pobj->peerHasPiece($pid);
                last if $n >= 5;
            }
            $pts += $n;

            # now do some biasing towards or away from them
            my $up = $pobj->getBytesOut;
            my $down = $pobj->getBytesIn;
            $up ||= 1; $down ||= 1;
            my $ratio = $down / $up;
            $ratio = 3 if $ratio > 3;
            $ratio = 1 if $ratio < 1;
            $pts *= $ratio;

            # and perhaps for later, show interest
            $pobj->appearInterested if $n > 0;

            # now multiply down if they're choking us
            $pts *= 0.25 if $pobj->peerChoking;

            # now save in points hash
            d("doTracking(): peer got $pts points");
            $points{$peerid} = $pts;
        }

        # now, iterate by points
        my $ctsf = 0;
        foreach my $peerid (sort { $points{$a} <=> $points{$b} } keys %points) {
            my $points = $points{$peerid};
            my $pobj = $self->{_peers}->{$peerid};

            # if points are 0 or less, we don't care about this person at all
            if ($points <= 0) {
                $pobj->startChoking;
                next;
            }

            # okay, unchoke this one
            $pobj->stopChoking;
            last if ++$ctsf >= 4;
        }
        d("doTracking(): unchoked $ctsf peers");

        $self->{_next_choke_at} = $now + 10; # wait 10 seconds
    }

    # the above happens once every 10 seconds... the rest is always happening.
    # basically we want to handle sending requests to people who aren't choking
    # us and that we're interested in and they have pieces we want.
    foreach my $peerid (keys %{$self->{_peers}}) {
        my $pobj = $self->{_peers}->{$peerid};

        # handle requests they've sent us
        my $req = $pobj->popRequest;
        if ($req && ref $req eq 'ARRAY') {
            my ($pid, $idx, $len) = @$req;
            if (!$self->hasPiece($pid)) {
                $pobj->close("peer_requested_invalid_piece_$pid");
                next;
            }

            # if they asked for too much...
            if ($len > 2**17) {
                $pobj->close("peer_wanted_length_$len");
                next;
            }

            # if index is weird...
            if ($idx < 0 || ($idx + $len > $self->getPieceLength)) {
                $pobj->close("peer_wanted_invalid_combo_${pid}_${idx}_${len}");
                next;
            }

            # so get data from the file!
            my $data;
            d("doTracking(): serving up piece $pid (index $idx, length $len)");
            seek($self->{_fh}, $pid * $self->getPieceLength + $idx, 0);
            $self->{_fh}->read($data, $len);
            $pobj->enqueuePiece($pid, $idx, $data);
        }

        # now send a request if they're not processing one
        next unless $pobj->amInterested;
        $self->{_blocks_out}->{$peerid} ||= [];
        my $ct = scalar(@{$self->{_blocks_out}->{$peerid}});
        unless ($ct) {
            # pop off undefined pieces in the beginning
            shift @{$self->{_want_list}}
                while @{$self->{_want_list}} &&
                      !defined $self->{_want_list}->[0];

            # now find the first one that they know how to deal with
            my $n = 0;
            while ($n < scalar(@{$self->{_want_list}})) {
                my $ref = $self->{_want_list}->[$n];
                unless ($ref) {
                    $n++;
                    next;
                }

                # now see if they have it
                unless ($pobj->peerHasPiece($ref->[0])) {
                    $n++;
                    next;
                }

                # they have this piece so it's okay to send them the request
                d("doTracking(): sending request for $ref->[0] (index $ref->[1], length $ref->[2])");
                delete $self->{_want_list}->[$n];
                push @{$self->{_blocks_out}->{$peerid}}, $ref;
                $pobj->sendRequest(@$ref);

                # don't send them two requests
                last;
            }
        }
    }
    d("doTracking(): finished");
}

# call and give this the number of bytes to send, it will then figure out who we're dealing
# with for our peers and send bytes to them.  returns the number of bytes actually sent.
sub processWrites {
    my Downpour::Torrent $self = shift;
    my $bytes = shift() + 0;
    return unless $bytes;

    # count how many people have buffers to send
    my %buffs;
    while (my ($peerid, $pobj) = each %{$self->{_peers}}) {
        # don't send bytes to people who are closed
        next if $pobj->{closed};
        my $bufsize = $pobj->getSendBufferSize;
        next unless $bufsize;
        $buffs{$peerid} = $bufsize;
    }

    unless (%buffs) {
        #d("processWrites(): nobody has pending writes");
        return 0;
    }

    my $ebytes = $bytes == -1 ? -1 : ($bytes / scalar(keys %buffs));
    d('processWrites(): found %d people, %d bytes per person', scalar(keys %buffs), $ebytes);

    my $total = 0;
    foreach my $peerid (keys %buffs) {
        $total += $self->{_peers}->{$peerid}->sendFromBuffer($ebytes);
    }

    d('processWrites(): sent %d bytes', $total);
    return $total;
}

sub registerIncoming {
    my Downpour::Torrent $self = shift;
    my Downpour::Socket $sock = shift;

    if (scalar(keys %{$self->{_peers}}) > $self->{_dp}->getMaxPeers) {
        d('registerIncoming(): dropped peer, over max of %d', $self->{_dp}->getMaxPeers);
        return $sock->close("too_many_peers");
    }

    my $rpeerid = $sock->getRemotePeerId;
    return $sock->close("already_connected_to")
        if $self->{_peers}->{$rpeerid} &&
           !$self->{_peers}->{$rpeerid}->{closed};

    # save this connection now
    $self->{_peers}->{$rpeerid} = $sock;
}

# internal; called to prepare for downloading a file
sub _initFile {
    my $self = shift;
    my $fn = $self->getFileName;
    d("_initFile($fn)");

    if (-e "$self->{path}/$fn") {
        # guess it exists in the destination path, it must be done?
        return _fail("destination file exists... was it done downloading?");

    } elsif (-e "$self->{path}/partial/$fn" && -e "$self->{path}/partial/$fn.pieces") {
        # it exists in the partial folder, so obviously we've started handling it
        # and need to determine what pieces were done
        return _fail("error: pieces file not correct length")
            unless -s "$self->{path}/partial/$fn.pieces" == $self->getPieceCount;

        # open file
        my $file;
        open $file, "+<$self->{path}/partial/$fn"
            or return _fail("error: can't open partial file: $!");
        $self->{_fh} = $file;

        # load in the piece file
        my $pfile;
        open $pfile, "+<$self->{path}/partial/$fn.pieces"
            or return _fail("error: can't open pieces file: $!");
        $self->{_pfh} = $pfile;

        # now we have to read in what pieces we have
        my $str;
        while (length $str < $self->getPieceCount) {
            my $bytes = $pfile->read($str, $self->getPieceCount, length $str);
            return _fail("error: failure readnig from pieces file: $!")
                unless defined $bytes;
            last unless $bytes;
        }
        return _fail('error: only got %d bytes from pieces file', length $str)
            unless length $str == $self->getPieceCount;

        # now save this as our piece information
        $self->{_pieces} = [ map { ord($_) } split('', $str) ];
        $self->{_blocks} = [ map { {} } 1..$self->getPieceCount ];
        return _fail("error: piece buffer count mismatch")
            unless scalar(@{$self->{_pieces}}) == $self->getPieceCount;

        # debugging info
        $self->createWantList;
        d('_initFile(): resuming file with %d pieces', $self->getPieceCount);
        return 1;

    } else {
        # doesn't exist at all!  set it up.
        unless (-e "$self->{path}/partial" && -d _) {
            mkdir "$self->{path}/partial"
                or return _fail("error: can't make directory for partial data");
        }

        # create the shell to hold the file
        my $file;
        open $file, ">$self->{path}/partial/$fn"
            or return _fail("error: can't open partial file: $!");
        my $full = int($self->getFileLength / 1000);
        $file->print("\x00" x 1000)
            for 1..$full;
        $file->print("\x00" x ($self->getFileLength % 1000));
        $file->flush;
        $self->{_fh} = $file;

        # create the piece progress counter file
        my $pfile;
        open $pfile, ">$self->{path}/partial/$fn.pieces"
            or return _fail("error: can't open pieces file: $!");
        $pfile->print("\x00" x $self->getPieceCount);
        $pfile->flush;
        $self->{_pfh} = $pfile;

        # setup memory structures
        $self->{_pieces} = [ map { 0 } 1..$self->getPieceCount ];
        $self->{_blocks} = [ map { {} } 1..$self->getPieceCount ];

        # note that we created it
        $self->createWantList;
        d('_initFile(): created file with %d pieces', $self->getPieceCount);
        return 1;
    }
}

## general purpose get information from torrent info file functions
sub getFileName     { return $_[0]->{_t}->{info}->{name};             }
sub getComment      { return $_[0]->{_t}->{comment};                  }
sub getCreatedBy    { return $_[0]->{_t}->{"created by"};             }
sub getAnnounceURL  { return $_[0]->{_t}->{announce};                 }
sub getCreationDate { return $_[0]->{_t}->{"creation date"};          }
sub getAnnounceList { croak("not implemented yet");                   }
sub getFileLength   { return $_[0]->{_t}->{info}->{length}+0;         }
sub getPieceLength  { return $_[0]->{_t}->{info}->{"piece length"}+0; }
sub getFileMD5Sum   { return $_[0]->{_t}->{info}->{md5sum};           }
sub getInfoDigest   { return $_[0]->{_info_digest};                   }
sub getPieceCount   { return $_[0]->{_piece_count};                   }

# get the count of how many blocks per piece there are
sub getBlockCount {
    my Downpour::Torrent $self = shift;
    my $id = shift() + 0;
    return _fail("piece id out of bounds")
        if $id < 0 || $id >= $self->getPieceCount;

    # return it if we have it
    my $islast = ($id == ($self->getPieceCount - 1)) ? 1 : 0;
    return $self->{_block_count}->[$islast] if $self->{_block_count};

    # numblocks is how many FULL blocks there are, esize is the
    # size of this full block set.  final is the number of extra bytes.
    # this only matters for all pieces except the /final/ one.
    my $numblocks = int($self->getPieceLength / BLOCK_LENGTH);
    my $esize = $numblocks * BLOCK_LENGTH;
    my $final = $self->getPieceLength - $esize;

    # now we compute the number of blocks for the final piece...
    my $lpbytes = $self->getFileLength - (($self->getPieceCount - 1) * $self->getPieceLength);
    my $fnumblocks = int($lpbytes / BLOCK_LENGTH);
    my $fesize = $fnumblocks * BLOCK_LENGTH;
    my $ffinal = $lpbytes - $fesize;

    # now create our data sets
    $self->{_block_count} = [ $numblocks + ($final ? 1 : 0), $fnumblocks + ($ffinal ? 1 : 0) ];
    $self->{_block_sizes} = [ [ map { BLOCK_LENGTH } 1..$numblocks ],
                              [ map { BLOCK_LENGTH } 1..$fnumblocks ] ];
    push @{$self->{_block_sizes}->[0]}, $final if $final;
    push @{$self->{_block_sizes}->[1]}, $ffinal if $ffinal;

    # now return it
    return $self->{_block_count}->[$islast];
}

# get the size of a particular block
sub getBlockSize {
    my Downpour::Torrent $self = shift;

    my $pid = shift() + 0;
    return _fail("piece id $pid out of range")
        if $pid < 0 || $pid >= $self->getPieceCount;

    my $bid = shift() + 0;
    return _fail("block id $bid out of range")
        if $bid < 0 || $bid >= $self->getBlockCount($pid);

    # load up the size of this block
    my $islast = ($pid == ($self->getPieceCount - 1));
    return $self->{_block_sizes}->[$islast]->[$bid];
}

# get the digest for a particular piece
sub getPieceDigest {
    my ($self, $pid) = @_;
    $pid += 0;
    return _fail("piece id ($pid) out of bounds")
        if $pid < 0 || $pid >= $self->getPieceCount;
    return substr($self->{_t}->{info}->{pieces}, $pid * 20, 20);
}

# see if we have a particular piece
sub hasPiece {
    my ($self, $pid) = @_;
    $pid += 0;
    return _fail("piece id ($pid) out of bounds")
        if $pid < 0 || $pid >= $self->getPieceCount;
    return $self->{_pieces}->[$pid];
}

# get the next block we're after
sub getWantedBlock {
    my $self = shift;
}

# call when we want to recyle the list of things we want
sub createWantList {
    my $self = shift;
    d("createWantList()");

    # default to reinitializing it
    $self->{_want_list} = [];

    # figure out what pids we still need
    my @pids;
    foreach my $i (0..$self->getPieceCount-1) {
        next if $self->hasPiece($i);
        push @pids, $i;
    }

    # numblocks is how many FULL blocks there are, esize is the
    # size of this full block set.  final is the number of extra bytes.
    # this only matters for all pieces except the /final/ one.
    my $numblocks = int($self->getPieceLength / BLOCK_LENGTH);
    my $esize = $numblocks * BLOCK_LENGTH;
    my $final = $self->getPieceLength - $esize;

    # now we compute the number of blocks for the final piece...
    my $lpbytes = $self->getFileLength - (($self->getPieceCount - 1) * $self->getPieceLength);
    my $fnumblocks = int($lpbytes / BLOCK_LENGTH);
    my $fesize = $fnumblocks * BLOCK_LENGTH;
    my $ffinal = $lpbytes - $fesize;

    # now put all of this information in our want list.
    d('createWantList(): %d pieces needed (numblocks = %d, esize = %d, final = %d)', scalar(@pids), $numblocks, $esize, $final);
    d('createWantList(): final piece (numblocks = %d, esize = %d, final = %d)', $fnumblocks, $fesize, $ffinal);
    my $fpid = $self->getPieceCount - 1; # final pid
    foreach my $pid (randlist(@pids)) {
        if ($pid == $fpid) {
            foreach my $i (0..$fnumblocks-1) {
                push @{$self->{_want_list}}, [ $pid, $i * BLOCK_LENGTH, BLOCK_LENGTH ];
            }
            push @{$self->{_want_list}}, [ $pid, $fesize, $ffinal ] if $ffinal;
        } else {
            foreach my $i (0..$numblocks-1) {
                push @{$self->{_want_list}}, [ $pid, $i * BLOCK_LENGTH, BLOCK_LENGTH ];
            }
            push @{$self->{_want_list}}, [ $pid, $esize, $final ] if $final;
        }
    }
}

# taken wholesale from LiveJournal :)
# http://cvs.livejournal.org/
sub randlist
{
    my @rlist = @_;
    my $size = scalar(@rlist);

    my $i;
    for ($i=0; $i<$size; $i++)
    {
        unshift @rlist, splice(@rlist, $i+int(rand()*($size-$i)), 1);
    }
    return @rlist;
}

# called by a peer when they have gotten a block back
sub receivedBlock {
    my ($self, $pobj, $pid, $begin, $len, $body) = @_;
    $pid += 0;
    return _fail("receivedBlock(): piece id ($pid) out of bounds")
        if $pid < 0 || $pid >= $self->getPieceCount;
    return _fail("receivedBlock(): already have piece $pid")
        if $self->hasPiece($pid);
    return _fail("receivedBlock(): body isn't of length $len as expected")
        if $len != length $body;

    # step 1: write to file (do this first in case we crash?)
    seek($self->{_fh}, $pid * $self->getPieceLength + $begin, 0);
    $self->{_fh}->print($body);
    $self->{_fh}->flush;

    # note that this block isn't out anymore
    my @new;
    foreach my $ref (@{$self->{_blocks_out}->{$pobj->getRemotePeerId}}) {
        next unless $ref;
        next if $ref->[0] == $pid && $ref->[1] == $begin && $ref->[2] == $len;
        push @new, $ref;
    }
    $self->{_blocks_out}->{$pobj->getRemotePeerId} = \@new;

    # now, note that we've gotten this range
    $self->{_blocks}->[$pid]->{$begin} = $len;

    # now do a gap check... basically we want to go through the hash we've
    # setup and find any spots where there's a gap in data received.
    my $cur = 0;
    while (my $thislen = $self->{_blocks}->[$pid]->{$cur}) {
        $cur += $thislen;
    }

    # figure the desired size for this piece
    my $dlen;
    if ($pid == $self->getPieceCount - 1) {
        $dlen = $self->getFileLength - ($self->getPieceLength * ($self->getPieceCount - 1));
    } else {
        $dlen = $self->getPieceLength;
    }

    # was it enough?
    if ($cur == $dlen) {
        # amazingly it was.  now we do a check to see if this SHA1 matches.
        # to do that we have to read it back in from the file.
        d("receivedBlock(): piece $pid potentially done");
        seek($self->{_fh}, $pid * $self->getPieceLength, 0);
        my $data;
        my $bytes = $self->{_fh}->read($data, $dlen);
        unless ($bytes == $dlen) {
            die "can't handle this... couldn't read (bytes = $bytes, dlen = $dlen): $!\n";
        }

        my $digest = sha1($data);
        my $target = $self->getPieceDigest($pid);
        die "digest mismatch... $digest vs $target\n"
            unless $target eq $digest;

        # so it matches... good for us
        $self->{_pieces}->[$pid] = 1;
        $self->{_blocks}->[$pid] = undef;

        # save this to our piece progress file
        seek($self->{_pfh}, $pid, 0);
        $self->{_pfh}->print("\x01");
        $self->{_pfh}->flush;

        # now notify all of our peers that we got this piece
        foreach my $pobj (values %{$self->{_peers}}) {
            next if $pobj->{closed};
            $pobj->notePieceReceived($pid);
        }
    } else {
        # nope, not done... just note for debugging
        d("receivedBlock(): got block from piece $pid, hit gap at $cur ($dlen)");
    }
}

# general config getting functions used by people we use
sub getPeerId       { return $_[0]->{peer_id};                        }
sub getListenPort   { return $_[0]->{_dp}->getListenPort;             }

# general statistic information
sub getBytesIn      { return $_[0]->{_bytes_in} || 0;                 }
sub getBytesOut     { return $_[0]->{_bytes_out} || 0;                }
sub addBytesIn      { return $_[0]->{_bytes_in} += ($_[1]+0);         }
sub addBytesOut     { return $_[0]->{_bytes_out} += ($_[1]+0);        }

1;
