#!/usr/bin/perl
# Test the Timetable module
# James Stanley 2012

use Timetable qw/ical_for_url ical_as_string/;

use strict;
use warnings;

my @start = (2011, 10, 3);
my $ical = ical_for_url( \@start, 'http://timetables.bath.ac.uk:4090/reporting/individual?identifier=Second+year+Computer+Science&weeks=19-32&submit2=View+Computer+Science+Timetable&idtype=name&objectclass=programme%2Bof%2Bstudy%2Bgroups&periods=1-11&days=1-5&width=100&height=0' );

print ical_as_string( $ical );
