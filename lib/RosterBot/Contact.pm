package RosterBot::Contact;
use strict;
use warnings;
use 5.020;

use Mail::VRFY;
use Date::Parse;
use Exporter 'import';

use RosterBot::Database;
use RosterBot::Utils;

# Path to contact request message file (substituted during install by make)
my $CONTACT_MESSAGE_FILE = '@MSGFILE@';

# Disable automatic contact requests (for testing/maintenance)
my $DISABLE_CONTACT_REQUESTS = 0;

our @EXPORT = qw(
    validate_email
    validate_phone
    normalize_phone_to_e164
    process_contact_info
    was_contacted_within_interval
    get_contact_message
    can_send_contact_request
    increment_contact_request_count
    CONTACT_REQUEST_INTERVAL
    CONTACT_REQUEST_DELAY
    CONTACT_REQUEST_MAX_PER_MINUTE
    CONTACT_REQUEST_MAX_PER_10MIN
    CONTACT_REQUEST_MAX_PER_HOUR
);

sub set_disable_contact_requests {
    my ($value) = @_;
    $DISABLE_CONTACT_REQUESTS = $value;
    RosterBot::Utils::debug("Contact requests " . ($value ? "DISABLED" : "ENABLED"));
}

# Constants
use constant CONTACT_REQUEST_INTERVAL    => 604800;  # 1 week
use constant CONTACT_REQUEST_DELAY       => 30;       # seconds between sends
use constant CONTACT_REQUEST_MAX_PER_MINUTE => 1;
use constant CONTACT_REQUEST_MAX_PER_10MIN  => 8;
use constant CONTACT_REQUEST_MAX_PER_HOUR   => 30;

# Rate limiting state: timestamps of recent outbound contact-request DMs
my @contact_request_times;

sub can_send_contact_request {
    if ($DISABLE_CONTACT_REQUESTS) {
        RosterBot::Utils::debug("Contacting users is disabled");
        return 0;
    }

    my $now = time();

    # Prune entries older than 1 hour
    @contact_request_times = grep { $now - $_ < 3600 } @contact_request_times;

    my $per_minute = scalar grep { $now - $_ < 60  } @contact_request_times;
    my $per_10min  = scalar grep { $now - $_ < 600 } @contact_request_times;
    my $per_hour   = scalar @contact_request_times;

    if ($per_minute >= CONTACT_REQUEST_MAX_PER_MINUTE) {
        RosterBot::Utils::debug("Rate limit: $per_minute DM(s) in last minute (max " . CONTACT_REQUEST_MAX_PER_MINUTE . ")");
        return 0;
    }
    if ($per_10min >= CONTACT_REQUEST_MAX_PER_10MIN) {
        RosterBot::Utils::debug("Rate limit: $per_10min DM(s) in last 10 min (max " . CONTACT_REQUEST_MAX_PER_10MIN . ")");
        return 0;
    }
    if ($per_hour >= CONTACT_REQUEST_MAX_PER_HOUR) {
        RosterBot::Utils::debug("Rate limit: $per_hour DM(s) in last hour (max " . CONTACT_REQUEST_MAX_PER_HOUR . ")");
        return 0;
    }

    return 1;
}

sub normalize_phone_to_e164 {
    my ($phone) = @_;

    # Already valid E.164 — return immediately
    if ($phone =~ /^\+\d{7,15}$/) {
        return $phone;
    } 
    # redundant with below, but want it just because
    if ($phone =~ /^(?:\+1-?)?(\d{3})-?(\d{3})-?(\d{4})$/) {
        return  "+1$1$2$3";
    } 
    
    # Remove all non-digit characters
    my $digits = $phone;
    $digits =~ s/\D//g;
    
    # If it's 10 digits, assume US/Canada and add +1
    if ($digits =~ /^(\d{10})$/) {
        return "+1$1";
    }
    
    # If it's 11 digits starting with 1, add +
    if ($digits =~ /^1(\d{10})$/) {
        return "+$digits";
    }
    
    # For other international numbers, assume they need +
    if (length($digits) >= 7 && length($digits) <= 15) {
        return "+$digits";
    }
    
    # Return original if we can't normalize
    return $phone;
}

sub increment_contact_request_count {
    my $now = time();
    push @contact_request_times, $now;
    my $per_minute = scalar grep { $now - $_ < 60  } @contact_request_times;
    my $per_10min  = scalar grep { $now - $_ < 600 } @contact_request_times;
    my $per_hour   = scalar @contact_request_times;
    RosterBot::Utils::debug("Contact request rates: $per_minute/min  $per_10min/10min  $per_hour/hr");
}

sub validate_email {
    my ($email) = @_;
    
    my $code = Mail::VRFY::CheckAddress(addr => $email, method => 'syntax');
    return ($code == 0);
}

sub validate_phone {
    my ($phone) = @_;

    return 0 unless defined $phone && $phone ne '';

    # Strip all formatting characters (spaces, dashes, dots, parens)
    my $digits = $phone;
    $digits =~ s/[^\d+]//g;   # keep digits and leading +
    $digits =~ s/\+//g;       # then strip + for digit count

    return 0 unless $digits;

    # Accept 10 digits (NANP: NPANXXXXXX)
    # Accept 11 digits starting with 1 (NANP with country code)
    # Accept 7-15 digits (E.164 international range)
    return ($digits =~ /^1?\d{10}$/ || $digits =~ /^\d{7,15}$/);
}

sub process_contact_info {
    my ($content) = @_;
    
    my $email;
    my $phone;
    
    # Look for email pattern anywhere in the message
    if ($content =~ /(\S+@\S+\.\S+)/) {
        my $candidate = $1;
        # Clean up any trailing punctuation
        $candidate =~ s/[,;.]$//;
        if (validate_email($candidate)) {
            $email = $candidate;
        }
    }
    
    # Look for phone patterns anywhere in the message
    
    # Pattern 1: E.164 format - must start with + 
    if ($content =~ /(\+\d{7,15})/) {
        my $candidate = $1;
        if (validate_phone($candidate)) {
            $phone = $candidate;
        }
    }
    
    # Pattern 2: US format with parentheses/separators
    if (!$phone && $content =~ /(\+?1?[\s-]?\(?\d{3}\)?[\s\-]?\d{3}[\s\-]?\d{4})/) {
        my $candidate = $1;
        if (validate_phone($candidate)) {
            $phone = $candidate;
        }
    }
    
    # Pattern 3: Standalone digits (must have word boundary or whitespace around it)
    if (!$phone && $content =~ /(?:^|\s)(\d{10,15})(?:\s|$)/) {
        my $candidate = $1;
        if (validate_phone($candidate)) {
            $phone = $candidate;
        }
    }
    
    return ($email, $phone);
}

sub was_contacted_within_interval {
    my ($user_id, $contact_info) = @_;

    $contact_info //= db_get_user_contact_info($user_id);
    return 0 unless $contact_info && $contact_info->{last_contact_request};
    
    my $interval_ago = time() - CONTACT_REQUEST_INTERVAL;
    return (str2time($contact_info->{last_contact_request}, 'UTC') > $interval_ago);
}

sub get_contact_message {
    if (open(my $fh, '<', $CONTACT_MESSAGE_FILE)) {
        local $/;
        my $msg = <$fh>;
        close $fh;
        return $msg if defined $msg && $msg ne '';
        RosterBot::Utils::verbose("WARNING: $CONTACT_MESSAGE_FILE is empty, using built-in default");
    } else {
        RosterBot::Utils::verbose("WARNING: Cannot read $CONTACT_MESSAGE_FILE: $! -- using built-in default");
    }
    return <<'CONTACT';
Hello! I'm a bot.  My job is to get contact info in case we ever lose touch.  Please reply with your contact information in this format:

Email: your.email@example.com
Phone: +1-555-123-4567

You can provide just an email, just a phone number, or both.

If you don't want to provide contact information, reply with: STOP

You can update your information anytime by messaging me:
- `update email your.email@example.com`
- `update phone +1-555-123-4567`
CONTACT
}

1;
