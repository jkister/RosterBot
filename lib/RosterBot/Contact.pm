package RosterBot::Contact;
use strict;
use warnings;
use 5.020;

use Mail::VRFY;
use Date::Parse;
use Exporter 'import';

use RosterBot::Database;
use RosterBot::Utils;

# Paths to message files (substituted during install by make)
my $CONTACT_MESSAGE_FILE  = '@MSGFILE@';
my $SCAMMER_MESSAGE_FILE  = '@SCAMMERMSGFILE@';

# Disable automatic contact requests (for testing/maintenance)
my $DISABLE_CONTACT_REQUESTS = 0;

our @EXPORT = qw(
    validate_email
    validate_phone
    normalize_phone_to_e164
    process_contact_info
    was_contacted_within_interval
    get_contact_message
    get_scammer_warning_message
    can_send_contact_request
    get_rate_limit_bucket_info
    get_retry_delay_seconds
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
use constant CONTACT_REQUEST_MAX_PER_MINUTE => 2;
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

    my $buckets = "1min: $per_minute/" . CONTACT_REQUEST_MAX_PER_MINUTE .
                  "  10min: $per_10min/" . CONTACT_REQUEST_MAX_PER_10MIN .
                  "  1hr: $per_hour/" . CONTACT_REQUEST_MAX_PER_HOUR;

    if ($per_minute >= CONTACT_REQUEST_MAX_PER_MINUTE) {
        RosterBot::Utils::debug("Rate limit [1min tripped] $buckets");
        return 0;
    }
    if ($per_10min >= CONTACT_REQUEST_MAX_PER_10MIN) {
        RosterBot::Utils::debug("Rate limit [10min tripped] $buckets");
        return 0;
    }
    if ($per_hour >= CONTACT_REQUEST_MAX_PER_HOUR) {
        RosterBot::Utils::debug("Rate limit [1hr tripped] $buckets");
        return 0;
    }

    return 1;
}

sub normalize_phone_to_e164 {
    my ($phone) = @_;

    # Already valid E.164 — return immediately
    if ($phone =~ /^\+\d{8,15}$/) {
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
    if (length($digits) >= 8 && length($digits) <= 15) {
        return "+$digits";
    }
    
    # Return original if we can't normalize
    return $phone;
}

sub get_retry_delay_seconds {
    my $now = time();
    @contact_request_times = grep { $now - $_ < 3600 } @contact_request_times;
    my $per_minute = scalar grep { $now - $_ < 60  } @contact_request_times;
    my $per_10min  = scalar grep { $now - $_ < 600 } @contact_request_times;
    my $per_hour   = scalar @contact_request_times;

    return 3602 if $per_hour   >= CONTACT_REQUEST_MAX_PER_HOUR;
    return 602  if $per_10min  >= CONTACT_REQUEST_MAX_PER_10MIN;
    return 62   if $per_minute >= CONTACT_REQUEST_MAX_PER_MINUTE;
    return 0;
}

sub get_rate_limit_bucket_info {
    my $now = time();
    @contact_request_times = grep { $now - $_ < 3600 } @contact_request_times;
    my $per_minute = scalar grep { $now - $_ < 60  } @contact_request_times;
    my $per_10min  = scalar grep { $now - $_ < 600 } @contact_request_times;
    my $per_hour   = scalar @contact_request_times;
    return "1min: $per_minute/" . CONTACT_REQUEST_MAX_PER_MINUTE .
           "  10min: $per_10min/" . CONTACT_REQUEST_MAX_PER_10MIN .
           "  1hr: $per_hour/" . CONTACT_REQUEST_MAX_PER_HOUR;
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

    my $code = eval { Mail::VRFY::CheckAddress(addr => $email, method => 'compat') };
    if ($@) {
        RosterBot::Utils::verbose("WARNING: Mail::VRFY failed for [$email]: $@");
        return (0, "Validation error");
    }
    return ($code == 0, Mail::VRFY::English($code));
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
    # Accept 8-15 digits (E.164 international range, min is 8 for some regions)
    return ($digits =~ /^1?\d{10}$/ || $digits =~ /^\d{8,15}$/);
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
        my ($email_ok) = validate_email($candidate);
        if ($email_ok) {
            $email = $candidate;
        }
    }
    
    # Look for phone patterns anywhere in the message

    # Pattern 1: E.164 format - must start with +
    if ($content =~ /(\+\d{8,15})/) {
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
        my $msg;
        read($fh, $msg, 2048);
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
CONTACT
}

sub get_scammer_warning_message {
    if (open(my $fh, '<', $SCAMMER_MESSAGE_FILE)) {
        my $msg;
        read($fh, $msg, 2048);
        close $fh;
        return $msg if defined $msg && $msg ne '';
        RosterBot::Utils::verbose("WARNING: $SCAMMER_MESSAGE_FILE is empty, using built-in default");
    } else {
        RosterBot::Utils::verbose("WARNING: Cannot read $SCAMMER_MESSAGE_FILE: $! -- using built-in default");
    }
    return <<'WARNING';
**SCAMMERS ARE EVERYWHERE ON DISCORD!**

- Cassi (and anyone in these groups) will NEVER message you first!
- If you want to message Cassi, check her username to be sure!
- It should be EXACTLY "exhaustedcassi" without special characters like "_exhaustedcassi", "exhaustedcassi.", or a close spelling like "exaustedcassi"

To be allowed into the group, type the phrase (exactly, without quotes):
 "Scammers are everywhere and I have read the above"
WARNING
}

1;
