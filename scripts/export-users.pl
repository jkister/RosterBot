#!/usr/bin/env perl
# export-users.pl -- Export RosterBot user contact data
#
# Usage: export-users.pl [OPTIONS]
#
# See --help for full usage.

use strict;
use warnings;
use 5.020;
use open qw(:std :utf8);

use DBI;
use Getopt::Long qw(:config no_ignore_case);
use JSON ();

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
my $DEFAULT_DB = '@DBFILE@';

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
my %opt = (
    format  => 'text',
);

GetOptions(
    'db=s'          => \$opt{db},
    'format=s'      => \$opt{format},
    'display-name'  => \$opt{display_name},
    'phone'         => \$opt{phone},
    'email'         => \$opt{email},
    'all'           => \$opt{all},
    'status=s'      => \$opt{status},
    'header!'       => \$opt{header},
    'help|h'        => \$opt{help},
) or die "Error parsing options. Use --help for usage.\n";

if ($opt{help}) {
    print usage();
    exit 0;
}

# Track whether user explicitly requested specific columns (before --all expands them)
my $explicit_columns = ($opt{display_name} || $opt{email} || $opt{phone}) && !$opt{all};

# --all implies all detail flags
if ($opt{all}) {
    $opt{display_name} = 1;
    $opt{phone}        = 1;
    $opt{email}        = 1;
}

# Default: show all columns if none explicitly requested
if (!$opt{display_name} && !$opt{phone} && !$opt{email}) {
    $opt{display_name} = 1;
    $opt{email}        = 1;
    $opt{phone}        = 1;
}

# Default header on for csv/ssv/text
$opt{header} //= ($opt{format} =~ /^(csv|ssv|text)$/) ? 1 : 0;

my $db_path = $opt{db} // $DEFAULT_DB;

unless (-f $db_path) {
    die "Database not found: $db_path\n" .
        "Use --db=/path/to/rosterbot.db to specify the database path.\n";
}

# Validate format
unless ($opt{format} =~ /^(json|csv|ssv|text)$/) {
    die "Unknown format '$opt{format}'. Valid formats: json, csv, ssv, text\n";
}

# Validate status filter
if ($opt{status}) {
    unless ($opt{status} =~ /^(pending|contacted|provided|stopped)$/) {
        die "Unknown status '$opt{status}'. Valid: pending, contacted, provided, stopped\n";
    }
}

# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------
my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$db_path", '', '',
    { RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1 }
) or die "Cannot connect to database: $DBI::errstr\n";

my @columns;
if ($explicit_columns) {
    push @columns, 'display_name' if $opt{display_name};
    push @columns, 'email'        if $opt{email};
    push @columns, 'phone'        if $opt{phone};
} else {
    @columns = ('username', 'display_name', 'email', 'phone', 'contact_status');
}

my @select = map { "u.$_" } @columns;

my $sql = 'SELECT ' . join(', ', @select) . ' FROM users u';

my @binds;
if ($opt{status}) {
    $sql .= ' WHERE u.contact_status = ?';
    push @binds, $opt{status};
}

$sql .= ' ORDER BY u.username';

my $sth = $dbh->prepare($sql);
$sth->execute(@binds);

my @contact_filter;
if ($explicit_columns) {
    push @contact_filter, 'email' if $opt{email};
    push @contact_filter, 'phone' if $opt{phone};
}

my @rows;
while (my $row = $sth->fetchrow_hashref) {
    if (@contact_filter) {
        next unless grep { defined $row->{$_} && $row->{$_} ne '' } @contact_filter;
    }
    push @rows, $row;
}

$dbh->disconnect;

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

output_rows(\@rows, \@columns, $opt{format}, $opt{header});

exit 0;

# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------

sub output_rows {
    my ($rows, $cols, $format, $header) = @_;

    if ($format eq 'json') {
        output_json($rows, $cols);
    } elsif ($format eq 'csv') {
        output_dsv($rows, $cols, ',', $header);
    } elsif ($format eq 'ssv') {
        output_dsv($rows, $cols, ';', $header);
    } else {
        output_text($rows, $cols, $header);
    }
}

sub output_json {
    my ($rows, $cols) = @_;
    my @out;
    for my $row (@$rows) {
        my %rec;
        for my $col (@$cols) {
            $rec{$col} = $row->{$col};
        }
        push @out, \%rec;
    }
    my $json = JSON->new->utf8->pretty->canonical;
    print $json->encode(\@out);
}

sub output_dsv {
    my ($rows, $cols, $sep, $header) = @_;

    if ($header) {
        print join($sep, map { csv_field($_, $sep) } @$cols) . "\n";
    }

    for my $row (@$rows) {
        print join($sep, map { csv_field($row->{$_} // '', $sep) } @$cols) . "\n";
    }
}

sub csv_field {
    my ($val, $sep) = @_;
    $val //= '';
    # Quote if contains separator, double-quote, or newline
    if ($val =~ /[\Q$sep\E"\n\r]/) {
        $val =~ s/"/""/g;
        return "\"$val\"";
    }
    return $val;
}

sub output_text {
    my ($rows, $cols, $header) = @_;

    # Calculate column widths
    my %width;
    for my $col (@$cols) {
        $width{$col} = length($col);
    }
    for my $row (@$rows) {
        for my $col (@$cols) {
            my $len = length($row->{$col} // '');
            $width{$col} = $len if $len > $width{$col};
        }
    }

    my $fmt = join('  ', map { "%-$width{$_}s" } @$cols) . "\n";
    my $sep = join('  ', map { '-' x $width{$_} } @$cols) . "\n";

    if ($header) {
        printf $fmt, @$cols;
        print $sep;
    }

    for my $row (@$rows) {
        printf $fmt, map { $row->{$_} // '' } @$cols;
    }

    if ($header) {
        print $sep;
        printf "%d row(s)\n", scalar @$rows;
    }
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
sub usage {
    return <<'HELP';
Usage: export-users.pl [OPTIONS]

Export user contact data from the RosterBot database.

Options:
  --db=PATH          Path to rosterbot.db  [@DBFILE@]
  --format=FORMAT    Output format: json, csv, ssv, text  [text]
  --display-name     Include display name column
  --email            Include email column
  --phone            Include phone column
                     If none of the above are given, all three are shown by default.
                     If any are given, only the specified columns are shown.
  --all              Show all columns (display-name, email, phone)
  --status=STATUS    Filter by status: pending, contacted, provided, stopped
  --[no-]header      Show column headers (default: on for csv/ssv/text)
  -h, --help         Show this help

Formats:
  text   Human-readable aligned table (default)
  csv    Comma-separated values
  ssv    Semicolon-separated values
  json   JSON array of objects

Examples:
  # All users, all columns (default)
  export-users.pl

  # Users who provided contact info, email only, CSV
  export-users.pl --status=provided --format=csv --email

  # JSON output of pending users, all columns
  export-users.pl --status=pending --format=json

  # Semicolon-separated, custom DB path
  export-users.pl --db=/home/users/rosterbot/sql/rosterbot.db --format=ssv

HELP
}
