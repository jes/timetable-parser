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

Timetable.pm - convert a University of Bath HTML timetable to an iCalendar file

=head1 SYNOPSIS

    use Timetable qw/ical_for_url ical_as_string/;

    my @start = (2011, 10, 3);
    my $ical = ical_for_url( \@start, $url_to_timetable_page );

    print ical_as_string( $ical );

=head1 DESCRIPTION

The University of Bath give timetables in HTML files which are needlessly
difficult to use. For example:

http://timetables.bath.ac.uk:4090/reporting/individual?identifier=Secon
d+year+Chemistry+with+Management&weeks=19-32&idtype=name&objectclass=pr
ogramme%2Bof%2Bstudy%2Bgroups

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

=begin private

=head2 _ical_time_for $year, $month, $day, $weeks, $hour, $minute

Return the UTC time for the Europe/London time which is $weeks weeks after the
date given with ($year, $month, $day) and is at $hour:$minute.

Return is an iCalendar datetime string.

=end private

=cut

sub _ical_time_for {
    my ($year, $month, $day, $weeks, $hour, $minute) = @_;

    ($year, $month, $day) = Add_Delta_Days( $year, $month, $day, 7 * $weeks );

    return sprintf( "%04d%02d%02dT%02d%02d00", $year, $month, $day, $hour,
            $minute );
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

    # extract the times of periods from the first row
    my @firstrow = @{ $table[0] };
    my @times = map( $_->as_text(), @firstrow[1 .. $#firstrow] );

    my @ical;

    # build list of events
    my $dayofweek = 0;
    my $justincrementedday = 1;
    my $rowsuntilincrement = $table[1]->[0]->rowSpan;
    for (my $i = 1; $i < @table; $i++) {
        my $timeslot = 0;

        CELL:
        for (my $j = $justincrementedday; $j < @{ $table[$i] }; $j++) {
            my $cell = $table[$i]->[$j];
            my $time = $times[$timeslot];
            my $duration = $cell->colSpan;

            $timeslot += $duration;

            # extract lines from the table (in <font> tags...)
            my @lines = map( $_->as_text(), $cell->getElementsByTagName( 'font' ) );

            # skip empty cells and fail for wrong-sized ones
            next CELL if @lines == 0;
            die "bad cell" if @lines != 3;

            # extract information from the lines in the table
            my ($subject, $room, $weeks) = @lines;

            # get a Number::Range describing the weeks
            $weeks =~ s/\s+//g;
            $weeks =~ s/-/../g;
            my $range = Number::Range->new( $weeks );

            my $minweek = min( $range->range );
            my $maxweek = max( $range->range );
            my ($hour, $min) = split /:/, $time;
            my ($y, $m, $d) = Add_Delta_Days( $year, $month, $day, $dayofweek );
            my $startdate = _ical_time_for( $y, $m, $d, $minweek-1, $hour, $min );
            my @exdates;

            # work out what dates the event should not exist for
            for (my $w = $minweek; $w <= $maxweek; $w++) {
                push @exdates, _ical_time_for( $y, $m, $d, $w-1, $hour, $min )
                    if !$range->inrange( $w );
            }

            # add an event hash
            my %icalevent = (
                    DTSTART => $startdate,
                    DURATION => "PT" . ($duration * 60 - 10) . "M",
                    RRULE => "FREQ=WEEKLY;COUNT=" . ($maxweek - $minweek + 1),
                    SUMMARY => "$subject $room",
            );
            $icalevent{EXDATE} = join( ',', @exdates) if @exdates;

            push @ical, \%icalevent;
        }

        # some rows of events span several rows of the table, work out when
        # we should increment the day
        $rowsuntilincrement--;
        if ($rowsuntilincrement == 0) {
            $dayofweek++;
            $justincrementedday = 1;
            $rowsuntilincrement = $table[$i+1]->[0]->rowSpan if $i != $#table;
        } else {
            $justincrementedday = 0;
        }
    }

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
