#!/usr/bin/perl

use Test;

BEGIN {
    plan tests => 1;
}

# make sure we can load the module
eval { require Downpour; return 1; };
ok($@, '');
croak() if $@;

