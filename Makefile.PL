#!/usr/bin/perl
# la la copyright?

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME => 'Downpour',
    VERSION_FROM => 'lib/Downpour.pm',
    PREREQ_PM => {
        # FIXME: flesh this out
        'LWP::Simple' => 1.41,
    },
);
