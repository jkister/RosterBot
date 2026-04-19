#!/usr/bin/env perl
use strict;
use warnings;
use 5.020;

use lib qw(@LIBDIR@);

use RosterBot::Database;
use RosterBot::Discord;
use RosterBot::Commands;
use RosterBot::Contact;
use RosterBot::Utils;

use Getopt::Long;

my $CONF_FILE = '@ETCDIR@/rosterbot.conf';

# Read config file first; CLI flags override
my %conf;
if (-f $CONF_FILE) {
    open(my $fh, '<', $CONF_FILE) or die "Cannot read $CONF_FILE: $!\n";
    while (<$fh>) {
        chomp;
        s/#.*//;        # strip comments
        s/^\s+|\s+$//g; # strip surrounding whitespace
        next unless /\S/;
        if (/^([\w-]+)\s*=\s*(.+?)?\s*$/) {
            $conf{$1} = $2 // '';
        }
    }
    close $fh;
}

# Command line options
my %opt;
GetOptions(
    'debug|D'        => \$opt{debug},
    'no-contact|n'   => \$opt{no_contact},
    'notify-only=s'  => \$opt{notify_only},
    'approval-role=s'=> \$opt{approval_role},
    'help|h'         => \$opt{help},
) or die "Error parsing options\n";

if ($opt{help}) {
    print <<"HELP";
Usage: $0 [options]

Options:
    -D, --debug              Enable debug output
    -n, --no-contact         Disable automatic contact requests
    --notify-only=USERNAME   Send admin notifications only to USERNAME
                             (instead of all admins)
    --approval-role=ROLE     Role name that triggers user approval
    -h, --help               Do not print this help message

Config file: $CONF_FILE
    debug=1
    no-contact=1
    notify-only=username
    approval-role=approved

CLI flags override config file settings.
HELP
    exit 0;
}

# Apply config file values where CLI did not override
if (!defined $opt{debug} && defined $conf{debug}) {
    $opt{debug} = $conf{debug} =~ /^(1|yes|true)$/i ? 1 : 0;
}
if (!defined $opt{no_contact} && defined $conf{'no-contact'}) {
    $opt{no_contact} = $conf{'no-contact'} =~ /^(1|yes|true)$/i ? 1 : 0;
}
if (!defined $opt{notify_only} && defined $conf{'notify-only'} && $conf{'notify-only'} ne '') {
    $opt{notify_only} = $conf{'notify-only'};
}
if (!defined $opt{approval_role} && defined $conf{'approval-role'} && $conf{'approval-role'} ne '') {
    $opt{approval_role} = $conf{'approval-role'};
}

# enable debug here since its not set before disable_contact_requests
RosterBot::Utils::set_debug_flag($opt{debug}) if $opt{debug};

# Set contact request flag
RosterBot::Contact::set_disable_contact_requests($opt{no_contact} || 0);

# Set notify-only user
RosterBot::Utils::set_notify_only_user($opt{notify_only}) if $opt{notify_only};

# Validate approval-role
if (defined $opt{approval_role} && $opt{approval_role} =~ /^\s*$/) {
    die "approval-role cannot be empty\n";
}

# Handle graceful shutdown
$SIG{TERM} = $SIG{INT} = sub {
    RosterBot::Utils::verbose("Received shutdown signal, cleaning up...");
    RosterBot::Discord::discord_shutdown();
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        RosterBot::Database::db_disconnect();
        alarm(0);
    };
    alarm(0);
};

# Start the Discord bot
RosterBot::Discord::start(\%opt);
