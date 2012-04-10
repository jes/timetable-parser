#!/usr/bin/perl
# parse a University of Bath timetable
# James Stanley 2012

use HTML::DOM;
use Number::Range;
use LWP::Simple;
use List::Util qw/min max/;

use strict;
use warnings;

# return the number of cells in the given table
sub count_cells {
    my $table = shift;
    my $cells = 0;

    foreach my $row ($table->rows) {
        foreach my $cell ($row->cells) {
            $cells++;
        }
    }

    return $cells;
}

my $url = 'http://timetables.bath.ac.uk:4090/reporting/individual?identifier=Second+year+Computer+Science&weeks=1-15&submit2=View+Computer+Science+Timetable&idtype=name&objectclass=programme%2Bof%2Bstudy%2Bgroups&periods=1-11&days=1-5&width=100&height=0';

my $dom = HTML::DOM->new();
my $page = get( $url )
    or die "error: unable to get $url";

$dom->write( $page );
$dom->close();

my @tables = $dom->body->getElementsByTagName( 'table' );

my $maxcells = -1;
my $maxtable;

# find the largest table (the timetable one)
foreach my $table (@tables) {
    my $cells = count_cells( $table );
    if ($cells > $maxcells) {
        $maxcells = $cells;
        $maxtable = $table;
    }
}

my @table;

# find the text in each cell
foreach my $domrow ($maxtable->rows) {
    my @row;
    foreach my $cell ($domrow->cells) {
        push @row, $cell;
    }
    push @table, \@row;
}

my @times;
for (my $i = 1; $i < @{ $table[0] }; $i++) {
    my $cell = $table[0]->[$i];

    push @times, $cell->as_text();
}

my @events;
my $maxweek = 1;

for (my $i = 1; $i < @table; $i++) {
    my $timeslot = 0;
    CELL:
    for (my $j = 1; $j < @{ $table[$i] }; $j++) {
        my $cell = $table[$i]->[$j];
        my $time = $times[$timeslot];
        my $hours = $cell->colSpan;
        $timeslot += $hours;

        my @fonts = map( $_->as_text(), $cell->getElementsByTagName('font') );

        next CELL if @fonts == 0;

        die "bad cell" if @fonts != 3;

        my ($subject, $room, $weeks) = @fonts;
        $weeks =~ s/\s+//g;
        $weeks =~ s/-/../g;
        my $range = Number::Range->new( $weeks );
        
        $maxweek = max( $maxweek, $range->range );

        my %event = ( 
                time => $time,
                hours => $hours,
                subject => $subject,
                room => $room,
                weeks => $range,
        );

        push @{ $events[$i] }, \%event;
    }
}

for (my $w = 1; $w <= $maxweek; $w++) {
    print "Week $w\n";

    for (my $d = 1; $d <= 5; $d++) {
        print "Day $d\n";

        my @events = @{ $events[$d] };
        foreach my $event (@events) {
            print "$event->{time} ($event->{hours} hr): $event->{subject} in $event->{room}\n" if ($event->{weeks}->inrange($w));
        }
    }

    print "\n\n";
}
