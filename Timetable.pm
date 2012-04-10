# module to handle conversion of university timetables to iCal format
# James Stanley 2012

package Timetable;

use HTML::DOM;
use Number::Range;
use LWP::Simple;
use Date::Calc qw/Monday_of_Week Add_Delta_Days/;
use List::Util qw/min max/;
use Data::ICal;
use Data::ICal::Entry::Event;
use Date::ICal;
use URI::Escape;
use Carp;
require Exporter;

@ISA = qw/Exporter/;
@EXPORT_OK = qw/ical_for_url ical_for_html ical_for_dom/;

use strict;
use warnings;

sub ical_for_url {
    my $start = shift or (carp "no start date given to ical_for_url" and return undef);
    my $url = shift or (carp "no url given to ical_for_url" and return undef);

    my $page = get( $url ) or (carp "error fetching html" and return undef);

    return ical_for_html( $start, $page );
}

sub ical_for_html {
    my $start = shift or (carp "no start date given to ical_for_html" and return undef);
    my $html = shift or (carp "no html given to ical_for_html" and return undef);

    my $dom = HTML::DOM->new();
    $dom->write( $html );
    $dom->close();

    return ical_for_dom( $start, $dom );
}

sub _count_cells {
    my $table = shift;
    my $cells = 0;

    foreach my $row ($table->rows) {
        foreach my $cell ($row->cells) {
            $cells++;
        }
    }

    return $cells;
}

sub ical_for_dom {
    my $start = shift or (carp "no start date given to ical_for_dom" and return undef);
    my $dom = shift or (carp "no dom given to ical_for_dom" and return undef);

    my ($year, $month, $day) = @{ $start };

    my @tables = $dom->body->getElementsByTagName( 'table' );

    my $maxcells = -1;
    my $maxtable;

    # find the largest table (assume that this is the timetable one)
    foreach my $table (@tables) {
        my $cells = _count_cells( $table );
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
    my $minweek = -1;
    my $maxweek = 1;

    # build list of events
    my $dayofweek = 1;
    my $justincrementedday = 1;
    my $rowsuntilincrement = $table[1]->[0]->rowSpan;
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

            $minweek = min( $range->range ) if $minweek == -1;
            $minweek = min( $minweek, $range->range );
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

        $rowsuntilincrement--;
        if ($i != @table - 1 && $rowsuntilincrement == 0) {
            $dayofweek++;
            $justincrementedday = 1;
            $rowsuntilincrement = $table[$i+1]->[0]->rowSpan;
        } else {
            $justincrementedday = 0;
        }
    }

    print STDERR "Read $ninputevents events\n";

    my $ical = Data::ICal->new();

    my $nevents = 0;

    print STDERR "Max week is $maxweek\n";

    ($year, $month, $day) = Add_Delta_Days( $year, $month, $day, 7 * ($minweek - 1) );

    # put the events in the calendar
    for (my $w = $minweek; $w <= $maxweek; $w++) {
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

    print STDERR "Write $nevents events\n";

    return $ical;
}

1;
