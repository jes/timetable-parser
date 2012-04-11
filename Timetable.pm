# module to handle conversion of university timetables to iCal format
# James Stanley 2012

package Timetable;

use HTML::DOM;
use Number::Range;
use LWP::Simple;
use DateTime;
use Date::Calc qw/Add_Delta_Days/;
use List::Util qw/min max/;
use URI::Escape;
use Carp;
require Exporter;

@ISA = qw/Exporter/;
@EXPORT_OK = qw/ical_for_url ical_for_html ical_for_dom ical_as_string/;

use strict;
use warnings;

=head1 NAME

Timetable - convert a University of Bath HTML timetable to an iCalendar file

=head1 SYNOPSIS

    use Timetable qw/ical_for_url ical_as_string/;

    my @start = (2011, 10, 3);
    my $ical = ical_for_url( \@start, $url_to_timetable_page );

    print ical_as_string( $ical );

=head1 DESCRIPTION

The University of Bath give timetables in HTML files which are needlessly
difficult to use. For example:

http://timetables.bath.ac.uk:4090/reporting/individual?identifier=Second+year+
Chemistry+with+Management&weeks=19-32&idtype=name&objectclass=programme%2Bof%2B
study%2Bgroups

This module is capable of scraping these pages and outputting iCalendar (RFC
2445) files containing the events.

=head1 DATA STRUCTURE

The iCalendar structures returned by many of these functions are arrayrefs
containing hashrefs describing events.

For example:

    [
        {
            'SUMMARY' => 'CM20218-Leca 6W 1.1',
            'DURATION' => '50M',
            'RRULE' => 'FREQ=WEEKLY;COUNT=15',
            'EXDATE' => '20120402T081500Z,20120409T081500Z',
            'DTSTART' => '20120206T091500Z'
        }
    ];

for a one-event structure with those properties. See RFC 2445 for what they
mean.

=head1 FUNCTIONS

=head2 ical_for_url $start, $url

$start should be an array reference of the form [ $year, $month, $day ]
describing the date of the first monday in the timetabling period. How this is
determined is an exercise for the module user (realistically, you have to just
get it manually from the university semester dates).

Return an iCalendar structure describing the page at the given $url or undef if
there is an error.

=cut

sub ical_for_url {
    my $start = shift or (carp "no start date given to ical_for_url" and return undef);
    my $url = shift or (carp "no url given to ical_for_url" and return undef);

    my $page = get( $url ) or (carp "error fetching html" and return undef);

    return ical_for_html( $start, $page );
}

=head2 ical_for_html $start, $html

$start is as for ical_for_url.

Return an iCalendar structure describing the page in $html or undef if there is
an error.

=cut

sub ical_for_html {
    my $start = shift or (carp "no start date given to ical_for_html" and return undef);
    my $html = shift or (carp "no html given to ical_for_html" and return undef);

    my $dom = HTML::DOM->new();
    $dom->write( $html );
    $dom->close();

    return ical_for_dom( $start, $dom );
}

=begin private

=head2 _count_cells $table

Return the total number of cells in the HTML::DOM::Table.

This is used internally to select the largest table (which is almost certainly
the one containing the timetable data).

=end private

=cut

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

=head2 ical_for_dom $start, $dom

$start is as for ical_for_url.

Return an iCalendar structure describinbg the page in the HTML::DOM in $dom or
undef if there is an error.

=cut

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

                    # make a date object
                    # TODO: only do this for startdate and exdates
                    my ($hours, $minutes) = split /:/, $event->{time};
                    my $localdate = DateTime->new(
                            year => $thisyear,
                            month => $thismonth,
                            day => $thisday,
                            hour => $hours,
                            minute => $minutes,
                            time_zone => 'Europe/London',
                    );
                    $localdate->set_time_zone( 'UTC' );
                    $thisyear = $localdate->year;
                    $thismonth = $localdate->month;
                    $thisday = $localdate->day;
                    $hours = $localdate->hour;
                    $minutes = $localdate->minute;
                    my $icaldate = sprintf( "%04d%02d%02dT%02d%02d00Z", $thisyear, $thismonth, $thisday, $hours, $minutes );

                    if (!defined $startdate) {
                        $startdate = $icaldate;
                        $nweeks = 1;
                    }

                    $nweeks++;

                    if (!$event->{weeks}->inrange( $w )) {
                        push @exdates, $icaldate;
                    }

                    ($thisyear, $thismonth, $thisday) = Add_Delta_Days( $thisyear, $thismonth, $thisday, 7 );
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

=begin private

=head2 _fold_lines @lines

Concatenate the lines in the given array, folding them at 75 characters as
per RFC 2445.

=end private

=cut

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

=head2 ical_as_string $ical

Return a string representation of the given iCalendar structure, suitable for
writing to a .ics file.

=cut

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

=head1 AUTHOR

James Stanley <james@incoherency.co.uk>

=head1 LICENSING

Do whatever you want.

=cut

1;
