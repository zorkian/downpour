#!/usr/bin/perl
# FIXME: add gpl, author, etc

# socket for web based management interface... well, more like the web based
# statistics interface

# FIXME: make this less braindead and have more stats, heh
# FIXME: make piece breakdown combine gapless blocks

package Downpour::ManageSocket;

use strict;

use Socket qw(PF_INET SOCK_STREAM IPPROTO_TCP);
use Danga::Socket;
use IO::Handle;

use base 'Danga::Socket';

use fields ('_dp',  # our Downpour
            '_buf', # input buffer
            );

# global debug variable
use vars qw($DEBUG);
our $VERSION = 1.00;

sub d {
    if ($::DEBUG) {
        # use printf for debug stuff
        my $str = "Downpour::ManageSocket::" . shift() . "\n";
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

# accept an incoming connection
sub new {
    my Downpour::ManageSocket $self = shift;
    d("new_from_sock()");

    $self = fields::new($self) unless ref $self;

    my Downpour $dp = shift;
    $self->SUPER::new(@_);
    $self->{_dp} = $dp;
    $self->watch_read(1);

    return $self;
}

sub event_err {
    my Downpour::ManageSocket $self = shift;
    d("event_err(): trigged on $self");
    return $self->close("event_err");
}

sub event_hup {
    my Downpour::ManageSocket $self = shift;
    d("event_hup(): trigged on $self");
    return $self->close("event_hup");
}

sub event_read {
    my Downpour::ManageSocket $self = shift;

    # read in data
    my $bref = $self->read(64 * 1024); # read 64k at most at once
    return $self->close('undef_read')
        unless defined $bref;
    $self->{_buf} .= $$bref;

    # see if we have a full request
    if ($self->{_buf} =~ /^GET\s+(.+?)\s+HTTP/i) {
        # break out any arguments
        my ($uri, $args) = ($1, {});
        if ($uri =~ m/^(.+?)\?(.+)$/) {
            $uri = $1;
            my $temp = $2;
            foreach my $set (split(/&/, $temp)) {
                if ($set =~ /^(.+?)=(.*)$/) {
                    $args->{$1} = durl($2);
                }
            }
        }

        $self->handleRequest($uri, $args);
    }
}

sub handleRequest {
    my Downpour::ManageSocket $self = shift;
    my ($uri, $args) = @_;
    d("handleRequest($uri)");

    if ($uri eq '/') {
        $self->makeIndexPage;
    } elsif ($uri eq '/pieces') {
        $self->makePieceSummary($args->{t});
    } elsif ($uri eq '/wantlist') {
        $self->makeWantList($args->{t});
    } elsif ($uri eq '/peers') {
        $self->makePeerList($args->{t});
    } else {
        d("handleRequest($uri): not handled");
        $self->write("HTTP/1.1 404 NOT FOUND\r\n\r\nGo away, that wasn't found.");
    }
    $self->close("end_of_request");
}

sub makePeerList {
    my Downpour::ManageSocket $self = shift;
    my $dp = $self->{_dp}
        or return _fail("no Downpour object available");

    # now get this particular torrent
    my $digest = shift;
    my $torref = $dp->{_torrents}->{$digest}
        or return _fail("can't find requested torrent by digest");
    my $t = $torref->{torrent};

    # create out a page showing our active torrents
    my $res = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-type: text/html\r\n\r\n";
    $res .= "<h1>Downpour: Web Management Interface</h1>\n";

    foreach my $peerid (sort keys %{$t->{_peers}}) {
        my $pobj = $t->{_peers}->{$peerid};
        $res .= "<h2>" . eurl($peerid) . "</h2>\n";
        $res .= "<tt>" . $pobj->as_string . "</tt><br />\n";

        foreach my $ref (@{$t->{_blocks_out}->{$peerid}}) {
            $res .= "<b>Requested block:</b> piece $ref->[0], index $ref->[1], length $ref->[2] bytes<br />\n";
        }
        $res .= "<b>Peer has:</b> ";
        my %p;
        foreach my $n (0..$t->getPieceCount-1) {
            $p{$n} = 1 if $pobj->peerHasPiece($n);
        }
        my @list;
        foreach my $n (0..$t->getPieceCount-1) {
            if (scalar(@list) % 2 == 0) {
                push @list, $n
                    if $p{$n};
                next;
            }
            next if $p{$n};
            push @list, $n-1;
        }
        push @list, ($t->getPieceCount-1) if $p{$t->getPieceCount-1};
        my @out;
        while (1) {
            my ($a, $b) = splice(@list, 0, 2);
            push @out, "$a-$b";
            last unless @list;
        }
        $res .= join(', ', @out);
        $res .= "<br /><br />\n";
    }

    $self->write($res);
}

sub makePieceSummary {
    my Downpour::ManageSocket $self = shift;
    my $dp = $self->{_dp}
        or return _fail("no Downpour object available");

    # create out a page showing our active torrents
    my $res = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-type: text/html\r\n\r\n";
    $res .= "<h1>Downpour: Web Management Interface</h1>\n";

    # now get this particular torrent
    my $digest = shift;
    my $torref = $dp->{_torrents}->{$digest}
        or return _fail("can't find requested torrent by digest");
    my $t = $torref->{torrent};

    # now break down the pieces and blocks we know about
    $res .= "<table cellborder='1'>\n";
    foreach my $pid (0..$t->getPieceCount-1) {
        my $any = 0;
        my $nres = "<tr><td><b>$pid</b></td>";
        if ($t->hasPiece($pid)) {
            foreach my $bid (0..$t->getBlockCount($pid)-1) {
                $nres .= "<td style='background-color: blue;'>&nbsp;&nbsp;&nbsp;</td>";
            }
            $any = 1;
        } else {
            # no, so break down by blocks
            foreach my $bid (0..$t->getBlockCount($pid)-1) {
                if ($t->{_blocks}->[$pid]->{$bid * 64 * 1024}) {
                    $any = 1;
                    $nres .= "<td style='background-color: blue;'>&nbsp;&nbsp;&nbsp;</td>";
                } else {
                    $nres .= "<td style='background-color: rgb(220,220,220);'>&nbsp;&nbsp;&nbsp;</td>";
                }
            }
        }
        $nres .= "</tr>\n";
        $res .= $nres if $any;
    }

    # all done
    $self->write($res);
}

sub makeWantList {
    my Downpour::ManageSocket $self = shift;
    my $dp = $self->{_dp}
        or return _fail("no Downpour object available");

    # now get this particular torrent
    my $digest = shift;
    my $torref = $dp->{_torrents}->{$digest}
        or return _fail("can't find requested torrent by digest");
    my $t = $torref->{torrent};

    # create out a page showing our active torrents
    my $res = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-type: text/html\r\n\r\n";
    $res .= "<h1>Downpour: Web Management Interface</h1>\n";

    foreach my $ref (@{$t->{_want_list}}) {
        next unless $ref;
        my ($pid, $idx, $len) = @$ref;
        $res .= "<b>$pid:</b> $idx ($len bytes)<br />\n";
    }

    $self->write($res);
}

sub makeIndexPage {
    my Downpour::ManageSocket $self = shift;
    my $dp = $self->{_dp}
        or return _fail("no Downpour object available");

    # create out a page showing our active torrents
    my $res = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-type: text/html\r\n\r\n";
    $res .= "<h1>Downpour: Web Management Interface</h1>\n";

    # now generate content
    $res .= "<h2>Torrent list:</h2>";
    foreach my $x (sort keys %{$dp->{_torrents}}) {
        my $ex = eurl($x);
        my $torref = $dp->{_torrents}->{$x};
        my $t = $torref->{torrent};
        my %data = (
            "File name" => $t->getFileName,
            "Comment" => $t->getComment || '(unknown)',
            "Created by" => $t->getCreatedBy || '(unknown)',
            "File size" => $t->getFileLength,
            "Pieces" => $t->getPieceCount,
        );
        foreach my $key (sort keys %data) {
            $res .= "<b>$key:</b> $data{$key}<br />\n";
        }
        $res .= "<a href='/pieces?t=$ex'>See piece breakdown</a><br />\n";
        $res .= "<a href='/wantlist?t=$ex'>See want list</a><br />\n";
        $res .= "<a href='/peers?t=$ex'>See connected peers</a><br />\n";
        $res .= "<br/><br/>\n";
    }

    # now add header
    $self->write($res);
}

1;
