#!/usr/bin/perl
# FIXME: add in GPL etc here and POD documention
# FIXME: bencode on { 1 => 2 } isn't right, because it yields di1ei2ee which isn't valid
#        since the key has to be a string... but I don't think anywhere in the spec uses
#        numbers as keys, so I'm ignoring this for now
# based on http://wiki.theory.org/BitTorrentSpecification

package Downpour::BEncoder;

use strict;
use Carp qw(croak);
use Exporter;

## set our exportables
our $VERSION = 1.00;
our @ISA = qw(Exporter);
our @EXPORT = qw(bencode bdecode);

## encode one of [ hashref, arrayref, string, integer ]
sub bencode {
    my $input = shift;

    my $ref = ref $input;
    unless ($ref) {
        return _bencode_item($input);
    }

    if ($ref eq 'ARRAY') {
        # produce list of items
        return 'l' . join('', map { bencode($_) } @$input) . 'e';

    } elsif ($ref eq 'HASH') {
        # make a dictionary of items; NOTE: sort is required, the
        # specification says must be sorted alphabetically...
        my $res;
        foreach my $key (sort { $a cmp $b } keys %$input) {
            $res .= _bencode_item($key) . bencode($input->{$key});
        }
        return 'd' . $res . 'e';            

    } else {
        croak("Unable to bencode reference type $ref.");
    }
}

sub _bencode_item {
    my $input = shift;

    # integer or string
    if ($input =~ /^-?\d+$/) {
        # it has a numeric value...
        return "i${input}e";
    } else {
        # must be a string, treat it as such
        return length($input) . ":$input";
    }
}

sub bdecode {
    my $input = shift;

    my $res;
    while (length $input) {
        _bdecode_one(\$input, \$res);
    }
    return $res;
}

sub _bdecode_one {
    my ($inpref, $resref) = @_;
    croak("Got undef inpref") unless ref $inpref;
    croak("Got undef resref") unless ref $resref;

    # see what it starts with...
    my $init = substr($$inpref, 0, 1);
    croak("Couldn't get initial byte") unless length $init == 1;

    if ($init eq 'i') {
        # integer, single item
        if ($$inpref =~ s/^i(-?\d+)e//) {
            $$resref = $1+0;
        } else {
            croak("Unable to parse integer from $$inpref");
        }

    } elsif ($init eq 'd') {
        # dictionary
        $$inpref = substr($$inpref, 1);
        $$resref = {};
        while ($$inpref && substr($$inpref, 0, 1) ne 'e') {
            # get the first thing, should be a string
            my $key;
            _bdecode_one($inpref, \$key);
            croak("Didn't get a key") unless $key;
            croak("Expected key, got $key") if ref $key;

            # now get the value
            my $val;
            _bdecode_one($inpref, \$val);
            warn("Didn't get a value for key $key") unless $val;

            # now shove it in our response
            #if (!ref $val && length $val > 100) { $val = '...' }
            ${$resref}->{$key} = $val;
        }

        # end the final e
        $$inpref = substr($$inpref, 1);

    } elsif ($init eq 'l') {
        # list of items
        $$inpref = substr($$inpref, 1);
        $$resref = [];
        while ($$inpref && substr($$inpref, 0, 1) ne 'e') {
            # strip one off
            my $item;
            _bdecode_one($inpref, \$item);
            croak("Decoder returned undef item") unless $item;

            if (ref $item eq 'SCALAR') {
                # scalars stored raw
                push @{$$resref}, $$item;
            } else {
                # but hash/array refs get stored as refs still... ideally these will
                # never get intermixed, but if they do...
                push @{$$resref}, $item;
            }
        }

        # chop off the 'e'
        $$inpref = substr($$inpref, 1);

    } else {
        # see if this comes out to be a string?
        if ($$inpref =~ /^((\d+):)/) {
            my $len = $2+0;
            croak("Got 0 length string") unless $len;
            my $olen = length $1;

            # strip out the beginning and get our string
            my $str = substr($$inpref, $olen, $len);
            substr($$inpref, 0, $len + $olen) = '';
            $$resref = $str;

        } else {
            croak("Unable to parse one from $$inpref");
        }
    }
}

1;
