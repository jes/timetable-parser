#!/usr/bin/perl
# parse a University of Bath timetable
# James Stanley 2012

use HTML::DOM;
use Number::Range;
use LWP::Simple;
use Date::Calc qw/Monday_of_Week Add_Delta_Days/;
use List::Util qw/min max/;
use Data::ICal;
use Data::ICal::Entry::Event;
use Date::ICal;
use URI::Escape;

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

my ($year, $month, $day) = (2011, 9, 26);
my $base_url = 'http://timetables.bath.ac.uk:4090/reporting/individual?';
my %params = (
        identifier => 'Second year Computer Science',
        weeks => '1-15',
        idtype => 'name',
        objectclass => "programme\x2bof\x2bstudy\x2bgroups",
        days => '1-5',
);
my $url = $base_url . join( '&', map( "$_=" . uri_escape( $params{$_} ), keys %params ) );

my $page = get( $url )
    or die "error: unable to get $url";

my $dom = HTML::DOM->new();
$dom->write( $page );
$dom->close();

my @tables = $dom->body->getElementsByTagName( 'table' );

my $maxcells = -1;
my $maxtable;

# find the largest table (assume that this is the timetable one)
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
my $ninputevents = 0;
my $maxweek = 1;

# build list of events
my $dayofweek = 1;
my $justincrementedday = 1;
for (my $i = 1; $i < @table; $i++) {
    my $timeslot = 0;

    CELL:
    for (my $j = $justincrementedday; $j < @{ $table[$i] }; $j++) {
        my $cell = $table[$i]->[$j];
        my $time = $times[$timeslot];
        my $hours = $cell->colSpan;
        $timeslot += $hours;

        my @lines = map( $_->as_text(), $cell->getElementsByTagName('font') );

        next CELL if @lines == 0;

        die "bad cell" if @lines != 3;

        my ($subject, $room, $weeks) = @lines;
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

        push @{ $events[$dayofweek] }, \%event;
        $ninputevents++;
    }

    my $cell = $table[$i]->[0];
    print STDERR $cell->as_text() . "\n";
    if ($cell->rowSpan == 1) {
        $dayofweek++;
        $justincrementedday = 1;
    } else {
        $justincrementedday = 0;
    }
}

print STDERR "Read $ninputevents events\n";

my $ical = Data::ICal->new();

my $nevents = 0;

print STDERR "Max week is $maxweek\n";

# put the events in the calendar
for (my $w = 1; $w <= $maxweek; $w++) {
    for (my $d = 1; $d <= 5; $d++) {
        my @events = @{ $events[$d] };
        EVENT:
        foreach my $event (@events) {
            # don't add the event at this time if it does not occur on this week
            next EVENT if (!$event->{weeks}->inrange( $w ));

            # make a date object
            my ($hours, $minutes) = split /:/, $event->{time};
            my $icaldate = Date::ICal->new(
                    year => $year,
                    month => $month,
                    day => $day,
                    hour => $hours,
                    min => $minutes,
            );

            # add an event object
            my $icalevent = Data::ICal::Entry::Event->new();
            $icalevent->add_properties(
                   summary => "$event->{subject} $event->{room}",
                   duration => ($event->{hours} * 60 - 10) . "M",
                   dtstart => $icaldate->ical,
            );
            $ical->add_entry( $icalevent );
            $nevents++;

            print STDERR sprintf("%02d-%02d-%02d $hours:$minutes $event->{subject} $event->{room}\n", $year, $month, $day);
        }

        # go to next day
        ($year, $month, $day) = Add_Delta_Days( $year, $month, $day, 1 );
    }

    # skip the weekend
    ($year, $month, $day) = Add_Delta_Days( $year, $month, $day, 2 );
}

print STDERR "Output $nevents events\n";

print $ical->as_string;
