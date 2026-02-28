#!/usr/bin/env perl
use strict;
use warnings;
use 5.020;

use lib qw(/home/users/rosterbot/lib);

use RosterBot::Database;
use RosterBot::Discord;
use RosterBot::Commands;
use RosterBot::Contact;
use RosterBot::Utils;

use Getopt::Long;

# Command line options
my %opt;
GetOptions(
    'debug|D'      => \$opt{debug},
    'no-contact|n' => \$opt{no_contact},
    'notify-only=s'  => \$opt{notify_only},
    'help|h'       => \$opt{help},
) or die "Error parsing options\n";

if ($opt{help}) {
    print <<"HELP";
Usage: $0 [options]

Options:
    -D, --debug              Enable debug output
    -n, --no-contact         Disable automatic contact requests
    --notify-only=username   Send notifications only to specified user (instead of all admins)
    -h, --help               Show this help

RosterBot - Discord contact collection bot
HELP
    exit 0;
}

# enable debug here since its not set before disable_contact_requests
RosterBot::Utils::set_debug_flag($opt{debug}) if $opt{debug};

# Set contact request flag
RosterBot::Contact::set_disable_contact_requests($opt{no_contact} || 0);

# Set notify-only user
RosterBot::Utils::set_notify_only_user($opt{notify_only}) if $opt{notify_only};

# Handle graceful shutdown
$SIG{TERM} = $SIG{INT} = sub {
    RosterBot::Utils::verbose("Received shutdown signal, cleaning up...");
    RosterBot::Discord::discord_shutdown();
    RosterBot::Database::db_disconnect();
};

# Start the Discord bot
RosterBot::Discord::start(\%opt);
