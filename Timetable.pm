# module to handle conversion of university timetables to iCal format
# James Stanley 2012

package Timetable;

use HTML::DOM;
use Number::Range;
use LWP::Simple;
use Date::Calc qw/Add_Delta_Days/;
use List::Util qw/min max/;
use URI::Escape;
use Carp;
require Exporter;

@ISA = qw/Exporter/;
@EXPORT_OK = qw/ical_for_url ical_for_html ical_for_dom ical_as_string/;

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

    my @ical;

    my $nevents = 0;

    print STDERR "Max week is $maxweek\n";

    ($year, $month, $day) = Add_Delta_Days( $year, $month, $day, 7 * ($minweek - 1) );

    # put the events in the calendar
    #for (my $w = $minweek; $w <= $maxweek; $w++) {
        for (my $d = 1; $d <= 5; $d++) {
            my @events = @{ $events[$d] };

            EVENT:
            foreach my $event (@events) {
                my @recur;
                my @exdates;
                my ($thisyear, $thismonth, $thisday) = ($year, $month, $day);
                my $startdate = undef;
                my $nweeks = 0;

                WEEK:
                for (my $w = $minweek; $w <= $maxweek; $w++) {
                    my ($ty, $tm, $td) = ($thisyear, $thismonth, $thisday);
                    ($thisyear, $thismonth, $thisday) = Add_Delta_Days( $thisyear, $thismonth, $thisday, 7 );

                    # make a date object
                    # TODO: only do this for startdate and exdates
                    my ($hours, $minutes) = split /:/, $event->{time};
                    my $icaldate = sprintf( "%04d%02d%02dT%02d%02d00", $ty, $tm, $td, $hours, $minutes );

                    if (!defined $startdate) {
                        $startdate = $icaldate;
                        $nweeks = 1;
                    }

                    $nweeks++;

                    if (!$event->{weeks}->inrange( $w )) {
                        push @exdates, $icaldate;
                    }
                }

                # add an event hash
                my %icalevent = (
                        DTSTART => $startdate,
                        DURATION => ($event->{hours} * 60 - 10) . "M",
                        EXDATE => join( ',', @exdates ),
                        RRULE => "FREQ=WEEKLY;COUNT=$nweeks",
                        SUMMARY => "$event->{subject} $event->{room}",
                );
                push @ical, \%icalevent;
                $nevents++;
            }

            # go to next day
            ($year, $month, $day) = Add_Delta_Days( $year, $month, $day, 1 );
        }
    #}

    print STDERR "Write $nevents events\n";

    return \@ical;
}

sub _fold_lines {
    my $output = '';

    foreach my $line (@_) {
        while( length( $line ) > 75 ) {
            $output .= substr( $line, 0, 75 ) . "\r\n";
            $line = ' ' . substr( $line, 75 );
        }
        $output .= "$line\r\n";
    }

    return $output;
}

sub ical_as_string {
    my $ical = shift or die 'no ical given to ical_as_string';

    my @lines = (
        'BEGIN:VCALENDAR',
        'PRODID:Timetable.pm james@incoherency.co.uk',
        'VERSION:1.0',
    );

    foreach my $event (@$ical) {
        push @lines, 'BEGIN:VEVENT';
        foreach my $field (sort keys %$event) {
            push @lines, "$field:$event->{$field}";
        }
        push @lines, 'END:VEVENT';
    }

    push @lines, 'END:VCALENDAR';

    return _fold_lines( @lines );
}

1;
