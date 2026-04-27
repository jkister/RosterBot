package RosterBot::Discord;
use strict;
use warnings;
use 5.020;
use utf8;

use Mojo::UserAgent;
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Exporter 'import';

use RosterBot::Database;
use RosterBot::Utils qw(:DEFAULT DISCORD_MESSAGE_LIMIT);
use RosterBot::Contact;
use RosterBot::Commands;

our @EXPORT = qw(start leave_guild trigger_contact_scheduler discord_shutdown get_require_role_grant);

# Configuration
my $DB_PATH = '@DBFILE@';
my $api_base = 'https://discord.com/api/v10';
my $PASSWD_FILE = '@PASSWDFILE@';
# NOTE: Token is loaded at compile time and persists in memory for process lifetime.
# If the token is rotated, restart the process to reload it.
my $TOKEN = do {
    open(my $fh, '<', $PASSWD_FILE) or die "Cannot open $PASSWD_FILE: $!\n";
    my $token;
    while (<$fh>) {
        if (/^DISCORD_TOKEN\s*=\s*(\S+)/) {
            $token = $1;
            last;
        }
    }
    die "DISCORD_TOKEN not found in $PASSWD_FILE\n" unless $token;
    $token;
};

# State
my $ua;
my $ws;
my $shutting_down = 0;
my %dm_channel_cache;
my %dm_channel_pending;  # Track in-flight DM channel creations to prevent race conditions
my $heartbeat_interval;
my $last_sequence;
my $session_id;
my $resume_gateway_url;
my $heartbeat_timer;
my $contact_request_timer;
my $scammer_warning_timer;
my $reconnect_attempts = 0;
my $max_reconnect_attempts = 10;
my $approval_role;
my $require_role_grant = 0;
my %scammer_warning_scheduled;
my %contact_request_scheduled;
my @admin_message_queue;
my $admin_queue_timer;
my $admin_queue_flush_time;
my %pending_join_notifications;  # user_id -> { display => ..., servers => [...] }
my $join_digest_timer;
my %pending_ban_notifications;   # user_id -> { username => ..., servers => [...] }
my %pending_leave_notifications; # user_id -> { display => ..., username => ..., servers => [...] }
my $ban_leave_digest_timer;

sub get_require_role_grant { return $require_role_grant; }

sub discord_shutdown {
    verbose("Shutting down cleanly...");
    $shutting_down = 1;
    Mojo::IOLoop->remove($heartbeat_timer) if $heartbeat_timer;
    Mojo::IOLoop->remove($contact_request_timer) if $contact_request_timer;
    Mojo::IOLoop->remove($scammer_warning_timer) if $scammer_warning_timer;
    if ($join_digest_timer) {
        Mojo::IOLoop->remove($join_digest_timer);
        $join_digest_timer = undef;
        flush_join_digest();
    }
    if ($ban_leave_digest_timer) {
        Mojo::IOLoop->remove($ban_leave_digest_timer);
        $ban_leave_digest_timer = undef;
        flush_ban_leave_digest();
    }
    if ($admin_queue_timer) {
        Mojo::IOLoop->remove($admin_queue_timer);
        $admin_queue_timer = undef;
        $admin_queue_flush_time = undef;
        flush_admin_queue();
    }
    if ($ws) {
        Mojo::IOLoop->timer(5, sub { Mojo::IOLoop->stop() });
        $ws->finish(1000);
    } else {
        Mojo::IOLoop->stop();
    }
}

sub start {
    my ($opt) = @_;
    
    RosterBot::Utils::set_debug_flag($opt->{debug});
    $approval_role      = $opt->{approval_role};
    $require_role_grant = $opt->{require_role_grant} ? 1 : 0;
    verbose("Starting Discord bot...");
    
    # Initialize database
    db_init($DB_PATH);
    verbose("Connected to database: $DB_PATH");
    
    # Initialize HTTP client
    $ua = Mojo::UserAgent->new;
    $ua->inactivity_timeout(300);
    $ua->request_timeout(30);
    $ua->connect_timeout(10);
    
    # Connect to gateway
    connect_gateway();
    
    # Start event loop
    verbose("Starting event loop...");
    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

sub discord_api {
    my ($method, $endpoint, $data) = @_;
    
    my $url = "$api_base$endpoint";
    debug("API $method $url");
    
    my $tx = $ua->build_tx($method => $url);
    $tx->req->headers->authorization("Bot $TOKEN");
    $tx->req->headers->content_type('application/json') if $data;
    $tx->req->body(encode_json($data)) if $data;
    
    $tx = $ua->start($tx);
    
    if (my $err = $tx->error) {
        if (($tx->res->code // 0) == 401) {
            die "Discord token rejected (401 Unauthorized) - restart with a valid token\n";
        }
        verbose("API Error: $err->{message}");
        debug("Response: " . $tx->res->body) if $tx->res->body;
        return undef;
    }

    # Handle empty responses (DELETE returns 204 No Content)
    my $body = $tx->res->body;
    if (!$body && $method eq 'DELETE') {
        return { success => 1, code => $tx->res->code };
    }
    
    my $result = decode_json($body || '{}');
    return $result;
}

sub is_dm_blocked {
    my ($response) = @_;
    return 0 unless $response;

    if ($response->{code}) {
        # Any error triggers 24-hour backoff
        return 1;
    }

    return 0;
}

sub send_message {
    my ($channel_id, $content) = @_;
    debug("Sending message to channel $channel_id");
    return discord_api('POST', "/channels/$channel_id/messages", { content => $content });
}

sub get_dm_channel {
    my ($user_id) = @_;

    if (exists $dm_channel_cache{$user_id}) {
        debug("Using cached DM channel for user [$user_id]");
        return $dm_channel_cache{$user_id};
    }

    # Prevent race condition: return undef if another request is already creating this channel
    if ($dm_channel_pending{$user_id}) {
        debug("DM channel creation already in progress for user [$user_id]");
        return undef;
    }

    debug("Creating DM channel with user [$user_id]");
    $dm_channel_pending{$user_id} = 1;

    my $dm_channel = discord_api('POST', "/users/\@me/channels", {
        recipient_id => $user_id
    });

    delete $dm_channel_pending{$user_id};

    unless ($dm_channel && $dm_channel->{id}) {
        verbose("Failed to create DM channel with user [$user_id]");
        return undef;
    }

    $dm_channel_cache{$user_id} = $dm_channel->{id};
    debug("DM channel created and cached: $dm_channel->{id}");

    return $dm_channel->{id};
}

sub send_dm_to_user {
    my ($user_id, $content) = @_;

    my $channel_id = get_dm_channel($user_id);
    return undef unless $channel_id;

    debug("Sending DM to [" . get_display_name($user_id) . "] [" . get_username($user_id) . "]");
    my $result = send_message($channel_id, $content);

    if (!$result || ($result->{code} && ($result->{code} == 50007 || $result->{code} == 10003))) {
        debug("Invalidating DM channel cache for [$user_id] after send failure");
        delete $dm_channel_cache{$user_id};
    }

    return $result;
}

sub handle_role_granted {
    my ($user_id, $username, $display, $role_name, $server_name) = @_;

    flush_join_for_user($user_id);
    my $contact_info = db_get_user_contact_info($user_id);
    my $ack_warning = ($contact_info && !$contact_info->{scammer_ack})
        ? " ⚠️ NOTE: this user has NOT acknowledged the scammer warning yet" : "";

    verbose("Member [$username] gained role [$role_name] in [$server_name]");
    notify_admins("**ROLE GRANTED** `$display` <`$username`> was given the `$role_name` role in `$server_name`$ack_warning");

    if ($require_role_grant) {
        send_dm_to_user($user_id, "GOOD NEWS! You've been approved to join `$server_name` - come on in!");
        if ($contact_info && $contact_info->{approval_status} ne APPROVAL_APPROVED) {
            db_set_user_approved($user_id);
            $contact_info = db_get_user_contact_info($user_id);
        }

        if ($contact_info &&
            $contact_info->{scammer_ack} &&
            $contact_info->{approval_status} eq APPROVAL_APPROVED &&
            $contact_info->{contact_status} ne STATUS_PROVIDED &&
            $contact_info->{contact_status} ne STATUS_STOPPED &&
            $contact_info->{contact_status} ne STATUS_BANNED &&
            !was_contacted_within_interval($user_id, $contact_info) &&
            !$contact_request_scheduled{$user_id}) {

            $contact_request_scheduled{$user_id} = 1;
            if (can_send_contact_request()) {
                debug("Sending contact request to [$username] after role grant");
                send_contact_request($user_id, $username, $display);
            } else {
                verbose_rate_limit_skip("contact request for $display ($username) after role grant");
                schedule_with_retry(sub { send_contact_request($user_id, $username, $display) },
                                    "contact request for $display ($username)");
            }
        }
    }
}

sub verbose_rate_limit_skip {
    my ($description) = @_;
    verbose("Rate limit reached; queuing $description [" . get_rate_limit_bucket_info() . "]");
}

sub schedule_with_retry {
    my ($send_fn, $description, $extra_delay, $attempts) = @_;
    $extra_delay //= 0;
    $attempts    //= 0;

    if ($attempts >= 10) {
        verbose("Giving up on $description after $attempts retries");
        return;
    }

    my $delay = get_retry_delay_seconds() + $extra_delay;
    verbose("Rate limited; scheduling retry for $description in ${delay}s (attempt " . ($attempts + 1) . "/10)");
    Mojo::IOLoop->timer($delay, sub {
        if (can_send_contact_request()) {
            $send_fn->();
        } else {
            schedule_with_retry($send_fn, $description, 0, $attempts + 1);
        }
    });
}

sub queue_join_notification {
    my ($user_id, $display, $server_name) = @_;

    if (exists $pending_join_notifications{$user_id}) {
        push @{$pending_join_notifications{$user_id}{servers}}, $server_name;
    } else {
        $pending_join_notifications{$user_id} = {
            display => $display,
            servers => [$server_name],
        };
    }

    unless ($join_digest_timer) {
        $join_digest_timer = Mojo::IOLoop->timer(600, sub { flush_join_digest() });
        debug("Join digest timer started (600s)");
    }
}

sub flush_join_for_user {
    my ($user_id) = @_;
    return unless exists $pending_join_notifications{$user_id};

    my $entry = delete $pending_join_notifications{$user_id};
    my $servers = join(', ', map { "`$_`" } @{$entry->{servers}});
    notify_admins("NOTICE: `$entry->{display}` joined $servers");

    unless (%pending_join_notifications) {
        if ($join_digest_timer) {
            Mojo::IOLoop->remove($join_digest_timer);
            $join_digest_timer = undef;
        }
    }
}

sub flush_join_digest {
    $join_digest_timer = undef;
    return unless %pending_join_notifications;

    my @entries;
    for my $user_id (keys %pending_join_notifications) {
        my $entry = $pending_join_notifications{$user_id};
        my $servers = join(', ', map { "`$_`" } @{$entry->{servers}});
        push @entries, "`$entry->{display}` joined $servers";
    }
    %pending_join_notifications = ();

    my $count = scalar @entries;
    my $msg = "$count user" . ($count == 1 ? '' : 's') . " joined:\n" . join("\n", @entries);
    notify_admins($msg);
}

sub queue_ban_notification {
    my ($user_id, $username, $server_name) = @_;

    if (exists $pending_ban_notifications{$user_id}) {
        push @{$pending_ban_notifications{$user_id}{servers}}, $server_name;
    } else {
        $pending_ban_notifications{$user_id} = {
            username => $username,
            servers  => [$server_name],
        };
    }

    unless ($ban_leave_digest_timer) {
        $ban_leave_digest_timer = Mojo::IOLoop->timer(600, sub { flush_ban_leave_digest() });
        debug("Ban/leave digest timer started (600s)");
    }
}

sub queue_leave_notification {
    my ($user_id, $display_name, $full_username, $server_name) = @_;

    if (exists $pending_leave_notifications{$user_id}) {
        push @{$pending_leave_notifications{$user_id}{servers}}, $server_name;
    } else {
        $pending_leave_notifications{$user_id} = {
            display  => $display_name,
            username => $full_username,
            servers  => [$server_name],
        };
    }

    unless ($ban_leave_digest_timer) {
        $ban_leave_digest_timer = Mojo::IOLoop->timer(600, sub { flush_ban_leave_digest() });
        debug("Ban/leave digest timer started (600s)");
    }
}

sub flush_ban_leave_digest {
    $ban_leave_digest_timer = undef;
    return unless %pending_ban_notifications || %pending_leave_notifications;

    my @lines;

    for my $user_id (keys %pending_ban_notifications) {
        my $entry   = $pending_ban_notifications{$user_id};
        my $servers = join(', ', map { "`$_`" } @{$entry->{servers}});
        push @lines, "NOTICE: `$entry->{username}` has been banned from $servers";
    }
    %pending_ban_notifications = ();

    for my $user_id (keys %pending_leave_notifications) {
        my $entry   = $pending_leave_notifications{$user_id};
        my $servers = join(', ', map { "`$_`" } @{$entry->{servers}});
        push @lines, "NOTICE: `$entry->{display}` <`$entry->{username}`> has left $servers";
    }
    %pending_leave_notifications = ();

    notify_admins(join("\n", @lines));
}

sub flush_admin_queue {
    return unless @admin_message_queue;

    my $count = scalar @admin_message_queue;
    my $combined = join("\n", @admin_message_queue);
    @admin_message_queue = ();
    $admin_queue_timer = undef;
    $admin_queue_flush_time = undef;

    my $notify_only = RosterBot::Utils::get_notify_only_user();
    if ($notify_only) {
        my $user_id = RosterBot::Utils::find_user_by_name($notify_only);
        if ($user_id) {
            debug("Flushing admin queue ($count messages, " . length($combined) . " chars) to [$notify_only]");
            send_dm_to_user($user_id, $combined);
        } else {
            verbose("WARNING: Could not find user '$notify_only' for notification");
        }
    } else {
        my @admin_ids = db_get_admin_user_ids();
        debug("Flushing admin queue ($count messages, " . length($combined) . " chars) to " . scalar(@admin_ids) . " admin(s)");
        for my $admin_id (@admin_ids) {
            send_dm_to_user($admin_id, $combined);
        }
    }
}

sub notify_admins {
    my ($message) = @_;

    # If adding this message would exceed the limit, flush first
    my $current_len = @admin_message_queue
        ? length(join("\n", @admin_message_queue)) + 1 + length($message)
        : 0;

    if ($current_len > DISCORD_MESSAGE_LIMIT) {
        debug("Admin queue would exceed limit ($current_len chars); flushing before queuing new message");
        if ($admin_queue_timer) {
            Mojo::IOLoop->remove($admin_queue_timer);
            $admin_queue_timer = undef;
        }
        flush_admin_queue();
    }

    push @admin_message_queue, $message;
    my $queue_depth = scalar @admin_message_queue;

    unless ($admin_queue_timer) {
        $admin_queue_flush_time = time() + 60;
        $admin_queue_timer = Mojo::IOLoop->timer(60, sub { flush_admin_queue() });
    }

    debug("Queued admin message ($queue_depth in queue, " . length($message) . " chars, flush at " . scalar(localtime($admin_queue_flush_time)) . "): $message");
}

sub send_contact_request {
    my ($user_id, $username, $display_name) = @_;

    # If not provided, look them up
    $display_name //= get_display_name($user_id);
    $username //= get_username($user_id);

    if (was_contacted_within_interval($user_id)) {
        verbose("Skipping contact request for [$display_name] [$username]: already contacted within interval");
        delete $contact_request_scheduled{$user_id};
        return undef;
    }

    my $message = get_contact_message();

    my $result = send_dm_to_user($user_id, $message);

    unless ($result) {
        verbose("Failed to send contact request to [$display_name] [$username]");
        db_update_last_contact_request($user_id);
        return undef;
    }

    if (is_dm_blocked($result)) {
        verbose("DM blocked for [$display_name] [$username] - not updating last_contact_request");
        return undef;
    }

    db_update_last_contact_request($user_id);
    db_update_contact_status($user_id, STATUS_CONTACTED);
    increment_contact_request_count();
    delete $contact_request_scheduled{$user_id};
    verbose("Sent contact request to [$display_name] [$username]");
    return 1;
}

sub send_scammer_warning {
    my ($user_id, $username, $display_name) = @_;

    # If not provided, look them up
    $display_name //= get_display_name($user_id);
    $username //= get_username($user_id);

    my $message = get_scammer_warning_message();

    my $result = send_dm_to_user($user_id, $message);

    unless ($result) {
        verbose("Failed to send scammer warning to [$display_name] [$username]");
        return undef;
    }

    if (is_dm_blocked($result)) {
        verbose("DM blocked for [$display_name] [$username] - not sending scammer warning");
        return undef;
    }

    db_update_last_scammer_warning($user_id);
    delete $scammer_warning_scheduled{$user_id};
    increment_contact_request_count();
    verbose("Sent scammer warning to [$display_name] [$username]");
    return 1;
}

sub leave_guild {
    my ($guild_id) = @_;
    
    debug("Leaving guild [$guild_id]");
    my $result = discord_api('DELETE', "/users/\@me/guilds/$guild_id");
    
    return $result ? 1 : 0;
}

sub request_pending_contacts {
    debug("Running periodic contact request check");
    
    my @users = db_get_users_needing_contact_request(
        CONTACT_REQUEST_INTERVAL,
        CONTACT_REQUEST_MAX_PER_HOUR
    );
    
    verbose("Found " . scalar(@users) . " users needing contact request (max " . 
            CONTACT_REQUEST_MAX_PER_HOUR . ")");
    
    my $delay = 0;
    my $bot_id = get_bot_user()->{id};
    for my $user (@users) {
        next if $user->{user_id} eq $bot_id;
        verbose("Scheduling contact request for [$user->{username}]");

        my $uid = $user->{user_id};
        my $uname = $user->{username};
        my $display = extract_display_name($user, $user->{username});
        
        # Schedule non-blocking
        Mojo::IOLoop->timer($delay, sub {
            send_contact_request($uid, $uname, $display);
        });
        
        $delay += CONTACT_REQUEST_DELAY;
    }
}

sub request_pending_scammer_warnings {
    debug("Running periodic scammer warning check");

    my @users = db_get_users_needing_scammer_warning(
        86400,  # 24-hour interval between repeat warnings
        CONTACT_REQUEST_MAX_PER_HOUR
    );

    verbose("Found " . scalar(@users) . " users needing scammer warning");

    my $delay = 0;
    my $bot_id = get_bot_user()->{id};
    for my $user (@users) {
        next if $user->{user_id} eq $bot_id;

        my $uid     = $user->{user_id};
        my $uname   = $user->{username};
        my $display = extract_display_name($user, $user->{username});

        verbose("Scheduling scammer warning for [$uname]");
        Mojo::IOLoop->timer($delay, sub {
            if (can_send_contact_request()) {
                send_scammer_warning($uid, $uname, $display);
            } else {
                verbose_rate_limit_skip("scammer warning for $display ($uname)");
                schedule_with_retry(sub { send_scammer_warning($uid, $uname, $display) },
                                    "scammer warning for $display ($uname)");
            }
        });

        $delay += CONTACT_REQUEST_DELAY;
        $delay = 60 if $delay > 60;
    }
}

sub trigger_contact_scheduler {
    verbose("Manually triggering contact request scheduler");
    request_pending_contacts();
}

sub send_gateway {
    my ($op, $data) = @_;
    my $payload = encode_json({ op => $op, d => $data });
    $ws->send($payload);
}

sub send_heartbeat {
    extradebug("Sending heartbeat (seq: " . ($last_sequence // 'null') . ")");
    send_gateway(1, $last_sequence);
}

sub send_identify {
    verbose("Sending IDENTIFY...");
    send_gateway(2, {
        token => $TOKEN,
        intents =>
            (1 << 0) |   # GUILDS
            (1 << 1) |   # GUILD_MEMBERS
            (1 << 2) |   # GUILD_BANS
            (1 << 9) |   # GUILD_MESSAGES
            (1 << 12),   # DIRECT_MESSAGES
        properties => {
            os => $^O,
            browser => 'perl_discord_bot',
            device => 'perl_discord_bot',
        },
        compress => \0,
    });
}

sub send_resume {
    verbose("Sending RESUME...");
    send_gateway(6, {
        token => $TOKEN,
        session_id => $session_id,
        seq => $last_sequence,
    });
}

sub request_guild_members {
    my ($guild_id) = @_;
    debug("Requesting guild members for [$guild_id]");
    send_gateway(8, {
        guild_id => $guild_id,
        query => '',
        limit => 0,
    });
}

sub sync_guild_bans {
    my ($guild_id) = @_;

    my $guild_name = get_guilds()->{$guild_id}{name};
    my $after = '';
    my $total = 0;

    while (1) {
        my $endpoint = "/guilds/$guild_id/bans?limit=1000";
        $endpoint .= "&after=$after" if $after;

        my $result = discord_api('GET', $endpoint);

        unless ($result) {
            verbose("Could not fetch ban list for [$guild_name] (missing BAN_MEMBERS permission?)");
            return;
        }
        unless (ref($result) eq 'ARRAY') {
            verbose("Unexpected response fetching bans for [$guild_name]");
            return;
        }

        last unless @$result;

        for my $ban (@$result) {
            my $user = $ban->{user};
            next unless $user && $user->{id};
            db_update_contact_status($user->{id}, STATUS_BANNED);
            $total++;
        }

        last if @$result < 1000;
        $after = $result->[-1]{user}{id};
    }

    verbose("Synced $total ban(s) for [$guild_name]") if $total;
    verbose("No bans found for [$guild_name]") unless $total;
}

sub handle_gateway_event {
    my ($payload) = @_;
    
    my $op = $payload->{op};
    my $data = $payload->{d};
    my $event = $payload->{t};
    $last_sequence = $payload->{s} if defined $payload->{s};
    
    extradebug("Gateway event: OP=$op" . (defined $event ? " Event=$event" : ""));
    
    if ($op == 10) {
        $heartbeat_interval = $data->{heartbeat_interval};
        verbose("Received HELLO (heartbeat interval: ${heartbeat_interval}ms)");

        # Validate heartbeat interval
        if (!$heartbeat_interval || $heartbeat_interval !~ /^\d+$/ ||
            $heartbeat_interval <= 0 || $heartbeat_interval > 300000) {
            verbose("Invalid heartbeat interval: " . ($heartbeat_interval // 'undef') . " - closing connection");
            $ws->finish;
            return;
        }

        Mojo::IOLoop->remove($heartbeat_timer) if $heartbeat_timer;
        $heartbeat_timer = Mojo::IOLoop->recurring($heartbeat_interval / 1000, sub { send_heartbeat() });

        if ($session_id) {
            send_resume();
        } else {
            send_identify();
        }
    }
    elsif ($op == 11) {
        extradebug("Received heartbeat ACK");
    }
    elsif ($op == 9) {
        if ($data) {
            verbose("Invalid session (resumable), resuming...");
            Mojo::IOLoop->timer(2, sub { send_resume() });
        } else {
            verbose("Invalid session, re-identifying...");
            $session_id = undef;
            $resume_gateway_url = undef;
            Mojo::IOLoop->timer(2, sub { send_identify() });
        }
    }
    elsif ($op == 7) {
        verbose("Received reconnect request");
        $ws->finish;
    }
    elsif ($op == 0) {
        handle_dispatch_event($event, $data);
    }
}

sub handle_dispatch_event {
    my ($event, $data) = @_;
    
    if ($event eq 'READY') {
        set_bot_user($data->{user});
        $session_id = $data->{session_id};
        $resume_gateway_url = $data->{resume_gateway_url};
        
        verbose("Bot is ready!");
        verbose("Logged in as: " . get_bot_user()->{username});
        
        my $guilds = get_guilds();
        %$guilds = ();
        if ($data->{guilds}) {
            for my $guild (@{$data->{guilds}}) {
                $guilds->{$guild->{id}} = {
                    name => '',
                    members => {},
                };
            }
        }

        Mojo::IOLoop->remove($contact_request_timer) if $contact_request_timer;
        $contact_request_timer = Mojo::IOLoop->recurring(3600, sub {
            request_pending_contacts();
        });

        Mojo::IOLoop->remove($scammer_warning_timer) if $scammer_warning_timer;
        $scammer_warning_timer = Mojo::IOLoop->recurring(3600, sub {
            request_pending_scammer_warnings();
        });
    }
    elsif ($event eq 'GUILD_CREATE') {
        my $guild = $data;
        verbose("Guild available: [$guild->{name}]");
        
        db_upsert_server($guild->{id}, $guild->{name}, 'active');

        my $guilds = get_guilds();
        $guilds->{$guild->{id}} = {
            name    => $guild->{name},
            members => {},
            roles   => {},
        };
        if ($data->{roles}) {
            for my $role (@{$data->{roles}}) {
                $guilds->{$guild->{id}}{roles}{$role->{id}} = $role->{name};
            }
        }

        request_guild_members($guild->{id});
    }
    elsif ($event eq 'GUILD_DELETE') {
        my $guild_id = $data->{id};
        my $unavailable = $data->{unavailable};
        
        unless ($unavailable) {
            verbose("Guild [$guild_id] was deleted or bot was removed");
            db_mark_server_deleted($guild_id);
            my $guilds = get_guilds();
            delete $guilds->{$guild_id};
        }
    }
    elsif ($event eq 'GUILD_MEMBERS_CHUNK') {
        my $guild_id = $data->{guild_id};
        my $members = $data->{members};
        
        my $guilds = get_guilds();
        return unless exists $guilds->{$guild_id};
        
        my $user_cache = get_user_cache();
        my $bot_id = get_bot_user()->{id};
        my $delay = 0;

        if (!@$members && ($data->{chunk_count} // 1) > 1) {
            verbose("WARNING: Empty member chunk received for [$guilds->{$guild_id}{name}] (chunk $data->{chunk_index}/$data->{chunk_count})");
        }

        for my $member (@$members) {
            my $user = $member->{user};
            next if $user->{id} eq $bot_id;

            my $username = $user->{username};
            $username .= "#" . $user->{discriminator}
                if $user->{discriminator} && $user->{discriminator} ne '0';

            db_upsert_user($user->{id}, $username, $user->{global_name});
            db_upsert_membership($guild_id, $user->{id}, $member->{nick}, 'member', $member->{joined_at});

            $guilds->{$guild_id}{members}{$user->{id}} = {
                username    => $username,
                nick        => $member->{nick},
                global_name => $user->{global_name},
                joined      => $member->{joined_at},
                pending     => $member->{pending} // 0,
                roles       => { map { $_ => 1 } @{$member->{roles} // []} },
            };

            my $cache_name = lc($user->{username});
            $user_cache->{$cache_name} = $user->{id};

            my $contact_info = db_get_user_contact_info($user->{id});
            my $uid     = $user->{id};
            my $uname   = $username;
            my $display = extract_display_name($member, $username);

            # Catch approval role grants that happened while the bot was offline
            if ($require_role_grant &&
                $contact_info &&
                $contact_info->{approval_status} eq APPROVAL_PENDING &&
                $approval_role &&
                @{$member->{roles} // []}) {
                for my $role_id (@{$member->{roles}}) {
                    my $role_name = $guilds->{$guild_id}{roles}{$role_id} // next;
                    if ($role_name eq $approval_role) {
                        verbose("Detected offline approval role [$role_name] for [$username]");
                        db_set_user_approved($uid);
                        $contact_info = db_get_user_contact_info($uid);  # refresh
                        last;
                    }
                }
            }

            if ($contact_info && !$contact_info->{scammer_ack} &&
                $contact_info->{contact_status} ne STATUS_STOPPED &&
                $contact_info->{contact_status} ne STATUS_BANNED &&
                !$contact_info->{last_scammer_warning} &&
                !$scammer_warning_scheduled{$uid}) {

                $scammer_warning_scheduled{$uid} = 1;
                Mojo::IOLoop->timer($delay, sub {
                    send_scammer_warning($uid, $uname, $display);
                });
                $delay += CONTACT_REQUEST_DELAY;
                $delay = 60 if $delay > 60;

            } elsif ($contact_info &&
                     $contact_info->{approval_status} eq APPROVAL_APPROVED &&
                     $contact_info->{contact_status} ne STATUS_PROVIDED &&
                     $contact_info->{contact_status} ne STATUS_STOPPED &&
                     !was_contacted_within_interval($uid, $contact_info) &&
                     !$contact_request_scheduled{$uid}) {

                $contact_request_scheduled{$uid} = 1;
                if (can_send_contact_request()) {
                    # Schedule non-blocking contact request
                    Mojo::IOLoop->timer($delay, sub {
                        send_contact_request($uid, $uname, $display);
                    });
                    $delay += CONTACT_REQUEST_DELAY;
                    $delay = 60 if $delay > 60;
                } else {
                    my $stagger = $delay;
                    verbose_rate_limit_skip("contact request for $display ($username)");
                    schedule_with_retry(sub { send_contact_request($uid, $uname, $display) },
                                        "contact request for $display ($username)", $stagger);
                    $delay += CONTACT_REQUEST_DELAY;
                    $delay = 60 if $delay > 60;
                }
            }
        }

        verbose("Updated members for [$guilds->{$guild_id}{name}]: " .
                scalar(keys %{$guilds->{$guild_id}{members}}) . " total members");

        if ($data->{chunk_index} == $data->{chunk_count} - 1) {
            sync_guild_bans($guild_id);
        }
    }
    elsif ($event eq 'GUILD_MEMBER_ADD') {
        my $member = $data;
        my $guild_id = $member->{guild_id};
        my $user = $member->{user};
        
        return if $user->{id} eq get_bot_user()->{id};
        
        my $guilds = get_guilds();
        return unless exists $guilds->{$guild_id};
        
        my $username = $user->{username};
        $username .= "#" . $user->{discriminator} 
            if $user->{discriminator} && $user->{discriminator} ne '0';
        
        db_upsert_user($user->{id}, $username, $user->{global_name});
        db_reset_user_on_rejoin($user->{id});
        db_upsert_membership($guild_id, $user->{id}, $member->{nick}, 'member', $member->{joined_at});

        $guilds->{$guild_id}{members}{$user->{id}} = {
            username    => $username,
            nick        => $member->{nick},
            global_name => $user->{global_name},
            joined      => $member->{joined_at},
            pending     => $member->{pending} // 0,
            roles       => { map { $_ => 1 } @{$member->{roles} // []} },
        };

        my $user_cache = get_user_cache();
        my $cache_name = lc($user->{username});
        $user_cache->{$cache_name} = $user->{id};

        my $server_name = $guilds->{$guild_id}{name};
        verbose("Member [$username] joined [$server_name]");

        my $contact_info = db_get_user_contact_info($user->{id});

        unless ($contact_info) {
            verbose("ERROR: No contact_info for [$username] <$user->{id}>");
            return;
        }

        my $needs_scammer_warning = !$contact_info->{scammer_ack} &&
            $contact_info->{contact_status} ne STATUS_STOPPED &&
            $contact_info->{contact_status} ne STATUS_BANNED &&
            !$contact_info->{last_scammer_warning} &&
            !$scammer_warning_scheduled{$user->{id}};

        my $join_display = extract_display_name($member, $username);
        my $join_label = $needs_scammer_warning ? "$join_display (sending scammer warning)" : $join_display;
        queue_join_notification($user->{id}, $join_label, $server_name);

        debug("Contact info for [$username]:");
        debug("  Status:          $contact_info->{contact_status}");
        debug("  Approval:        $contact_info->{approval_status}");
        debug("  Scammer ACK:     $contact_info->{scammer_ack}");
        debug("  Email:           " . ($contact_info->{email} || "none"));
        debug("  Phone:           " . ($contact_info->{phone} || "none"));
        debug("  Last contacted:  " . ($contact_info->{last_contact_request} || "never"));

        my $display = extract_display_name($member, $username);

        if ($needs_scammer_warning) {
            $scammer_warning_scheduled{$user->{id}} = 1;
            if (can_send_contact_request()) {
                debug("Sending scammer warning to [$username] (no ACK yet)");
                send_scammer_warning($user->{id}, $username, $display);
            } else {
                verbose_rate_limit_skip("scammer warning for $display ($username)");
                my ($uid, $uname) = ($user->{id}, $username);
                schedule_with_retry(sub { send_scammer_warning($uid, $uname, $display) },
                                    "scammer warning for $display ($username)");
            }
        }
        elsif ($contact_info->{approval_status} eq APPROVAL_APPROVED) {
            # User has ACKed scammer warning and been approved by Discord server admin:
            # send contact request if we haven't yet and aren't rate-limited
            my $recently_contacted = was_contacted_within_interval($user->{id}, $contact_info);

            if ($contact_info->{contact_status} ne STATUS_PROVIDED &&
                $contact_info->{contact_status} ne STATUS_STOPPED &&
                !$recently_contacted &&
                !$contact_request_scheduled{$user->{id}}) {

                $contact_request_scheduled{$user->{id}} = 1;
                if (can_send_contact_request()) {
                    debug("Sending contact request to [$username]");
                    send_contact_request($user->{id}, $username, $display);
                } else {
                    verbose_rate_limit_skip("contact request for $display ($username)");
                    my ($uid, $uname) = ($user->{id}, $username);
                    schedule_with_retry(sub { send_contact_request($uid, $uname, $display) },
                                        "contact request for $display ($username)");
                }
            } else {
                if ($contact_info->{contact_status} eq STATUS_PROVIDED) {
                    debug("NOT sending: already provided contact info");
                } elsif ($contact_info->{contact_status} eq STATUS_STOPPED) {
                    debug("NOT sending: user opted out (STOP)");
                } elsif ($recently_contacted) {
                    debug("NOT sending: already contacted within interval");
                }
            }
        }
    }
    elsif ($event eq 'GUILD_MEMBER_REMOVE') {
        my $guild_id = $data->{guild_id};
        my $user = $data->{user};
        
        my $guilds = get_guilds();
        return unless exists $guilds->{$guild_id};
        
        my $display_name = get_display_name_in_guild($user->{id}, $guild_id);
        my $full_username = get_username_in_guild($user->{id}, $guild_id);
        my $server_name = $guilds->{$guild_id}{name};
        
        db_mark_member_left($guild_id, $user->{id});
        delete $guilds->{$guild_id}{members}{$user->{id}};
        
        verbose("Member [$full_username] left [$server_name]");
     
        # Only notify admins if it's NOT the bot leaving
        if ($user->{id} ne get_bot_user()->{id}) {
            flush_join_for_user($user->{id});
            queue_leave_notification($user->{id}, $display_name, $full_username, $server_name);
        } else {
            debug("Bot left [$server_name] - not notifying admins");
        }
    }
    elsif ($event eq 'GUILD_MEMBER_UPDATE') {
        my $member = $data;
        my $guild_id = $member->{guild_id};
        my $user = $member->{user};

        my $guilds = get_guilds();
        return unless exists $guilds->{$guild_id};

        my $username = $user->{username};
        $username .= "#" . $user->{discriminator}
            if $user->{discriminator} && $user->{discriminator} ne '0';

        my $display = extract_display_name($member, $username);
        my $server_name = $guilds->{$guild_id}{name};

        debug("GUILD_MEMBER_UPDATE for [$username] in [$server_name]");

        if (my $old = $guilds->{$guild_id}{members}{$user->{id}}) {
            my $old_nick    = $old->{nick}        // '';
            my $new_nick    = $member->{nick}      // '';
            my $old_global  = $old->{global_name}  // '';
            my $new_global  = $user->{global_name} // '';
            my $old_uname   = $old->{username}     // '';

            debug("  username:     [$old_uname] -> [$username]")     if $old_uname   ne $username;
            debug("  nick:         [$old_nick] -> [$new_nick]")       if $old_nick    ne $new_nick;
            debug("  global_name:  [$old_global] -> [$new_global]")   if $old_global  ne $new_global;
            debug("  pending:      [$old->{pending}] -> [" . ($member->{pending} // 0) . "]")
                if ($old->{pending} // 0) != ($member->{pending} // 0);

            my %new_role_ids = map { $_ => 1 } @{$member->{roles} // []};
            my @lost = grep { !$new_role_ids{$_} } keys %{$old->{roles} // {}};
            my @gained = grep { !$old->{roles}{$_} } keys %new_role_ids;
            for my $rid (@lost) {
                debug("  role lost:    [" . ($guilds->{$guild_id}{roles}{$rid} // $rid) . "]");
            }
            for my $rid (@gained) {
                debug("  role gained:  [" . ($guilds->{$guild_id}{roles}{$rid} // $rid) . "]");
            }

            if (!@lost && !@gained &&
                $old_uname eq $username && $old_nick eq $new_nick &&
                $old_global eq $new_global &&
                ($old->{pending} // 0) == ($member->{pending} // 0)) {
                debug("  (no tracked fields changed)");
            }
        } else {
            debug("  (no prior cache entry for this member)");
        }

        # Check if member was just approved (pending -> false, Discord Membership Screening)
        my $was_pending = exists $guilds->{$guild_id}{members}{$user->{id}}
            ? $guilds->{$guild_id}{members}{$user->{id}}{pending}
            : undef;
        my $is_pending = $member->{pending} // 0;

        if (defined($was_pending) && $was_pending && !$is_pending) {
            verbose("Member [$username] approved (screening) in [$server_name]");
            flush_join_for_user($user->{id});
            db_set_user_approved($user->{id});
            notify_admins("**USER APPROVED** `$display` <`$username`> has been approved in `$server_name`");
        }

        # Check for role changes
        my $old_roles = exists $guilds->{$guild_id}{members}{$user->{id}}
            ? ($guilds->{$guild_id}{members}{$user->{id}}{roles} // {})
            : {};
        my %new_roles = map { $_ => 1 } @{$member->{roles} // []};

        for my $role_id (keys %$old_roles) {
            next if $new_roles{$role_id};
            my $role_name = $guilds->{$guild_id}{roles}{$role_id} // $role_id;
            verbose("Member [$username] lost role [$role_name] in [$server_name]");
            notify_admins("**ROLE REVOKED** `$display` <`$username`> had the `$role_name` role removed in `$server_name`");
        }

        for my $role_id (keys %new_roles) {
            next if $old_roles->{$role_id};
            my $role_name = $guilds->{$guild_id}{roles}{$role_id} // $role_id;
            handle_role_granted($user->{id}, $username, $display, $role_name, $server_name);
        }

        db_upsert_user($user->{id}, $username, $user->{global_name});
        db_upsert_membership($guild_id, $user->{id}, $member->{nick}, 'member', undef);

        if (exists $guilds->{$guild_id}{members}{$user->{id}}) {
            my $old_username = $guilds->{$guild_id}{members}{$user->{id}}{username};
            my $user_cache = get_user_cache();

            if ($old_username && lc($old_username) ne lc($username)) {
                my $old_cache_name = lc($old_username);
                $old_cache_name =~ s/#.*$//;
                delete $user_cache->{$old_cache_name};
            }
            $user_cache->{lc($user->{username})} = $user->{id};

            $guilds->{$guild_id}{members}{$user->{id}}{username}    = $username;
            $guilds->{$guild_id}{members}{$user->{id}}{nick}        = $member->{nick};
            $guilds->{$guild_id}{members}{$user->{id}}{global_name} = $user->{global_name};
            $guilds->{$guild_id}{members}{$user->{id}}{pending}     = $is_pending;
            $guilds->{$guild_id}{members}{$user->{id}}{roles}       = \%new_roles;
        }
    }
    elsif ($event eq 'GUILD_BAN_ADD') {
        my $guild_id = $data->{guild_id};
        my $user     = $data->{user};

        my $guilds = get_guilds();
        return unless exists $guilds->{$guild_id};

        my $username = $user->{username};
        $username .= "#" . $user->{discriminator}
            if $user->{discriminator} && $user->{discriminator} ne '0';
        my $server_name = $guilds->{$guild_id}{name};

        db_update_contact_status($user->{id}, STATUS_BANNED);
        verbose("Member [$username] banned from [$server_name]");
        flush_join_for_user($user->{id});
        queue_ban_notification($user->{id}, $username, $server_name);
    }
    elsif ($event eq 'GUILD_BAN_REMOVE') {
        my $guild_id = $data->{guild_id};
        my $user     = $data->{user};

        my $guilds = get_guilds();
        return unless exists $guilds->{$guild_id};

        my $username = $user->{username};
        $username .= "#" . $user->{discriminator}
            if $user->{discriminator} && $user->{discriminator} ne '0';
        my $server_name = $guilds->{$guild_id}{name};

        my $contact_info = db_get_user_contact_info($user->{id});
        my $new_status = ($contact_info && ($contact_info->{email} || $contact_info->{phone}))
            ? STATUS_PROVIDED : STATUS_PENDING;
        db_update_contact_status($user->{id}, $new_status);
        verbose("Member [$username] unbanned from [$server_name] (status -> $new_status)");
        notify_admins("NOTICE: `$username` has been unbanned from `$server_name`");
    }
    elsif ($event eq 'MESSAGE_CREATE') {
        RosterBot::Commands::handle_message($data, \&send_message, \&send_dm_to_user, \&notify_admins, \&send_contact_request);
    }
}

sub connect_gateway {
    verbose("Getting gateway URL...");
    my $gateway_info = discord_api('GET', '/gateway/bot');
    
    die "Failed to get gateway URL\n" unless $gateway_info;
    
    my $gateway_url = $resume_gateway_url // $gateway_info->{url};
    verbose("Gateway URL: $gateway_url");
    
    $gateway_url .= '/?v=10&encoding=json';
    
    verbose("Connecting to gateway...");
    $ua->websocket($gateway_url => sub {
        my ($ua, $tx) = @_;
        
        unless ($tx->is_websocket) {
            verbose("WebSocket handshake failed!");
            $reconnect_attempts++;

            if ($reconnect_attempts >= $max_reconnect_attempts) {
                verbose("Max reconnection attempts reached ($max_reconnect_attempts). Exiting.");
                Mojo::IOLoop->stop();
                exit 1;
            }

            # Exponential backoff: 2^attempts seconds, capped at 300 (5 minutes)
            my $delay = 2 ** $reconnect_attempts;
            $delay = 300 if $delay > 300;
            verbose("Reconnecting in $delay seconds (attempt $reconnect_attempts/$max_reconnect_attempts)...");

            Mojo::IOLoop->timer($delay, sub {
                connect_gateway();
            });
            return;
        }
        
        verbose("WebSocket connected!");
        $tx->max_websocket_size(10 * 1024 * 1024);  # 10 MB; default 256 KB is too small for large guild member chunks
        $ws = $tx;
        $reconnect_attempts = 0;  # Reset on successful connection
        
        $tx->on(json => sub {
            my ($tx, $payload) = @_;
            handle_gateway_event($payload);
        });
        
        $tx->on(finish => sub {
            my ($tx, $code, $reason) = @_;
            verbose("WebSocket closed: $code " . ($reason // ''));
            if ($heartbeat_timer) {
                Mojo::IOLoop->remove($heartbeat_timer);
                $heartbeat_timer = undef;
            }
            if ($shutting_down) {
                verbose("WebSocket closed cleanly, disconnecting");
                Mojo::IOLoop->stop();
                return;
            }

            $reconnect_attempts++;

            if ($reconnect_attempts >= $max_reconnect_attempts) {
                verbose("Max reconnection attempts reached ($max_reconnect_attempts). Exiting.");
                Mojo::IOLoop->stop();
                exit 1;
            }

            # Exponential backoff: 2^attempts seconds, capped at 300 (5 minutes)
            my $delay = 2 ** $reconnect_attempts;
            $delay = 300 if $delay > 300;
            verbose("Reconnecting in $delay seconds (attempt $reconnect_attempts/$max_reconnect_attempts)...");

            Mojo::IOLoop->timer($delay, sub {
                connect_gateway();
            });
        });
        
        $tx->on(error => sub {
            my ($tx, $err) = @_;
            verbose("WebSocket error: $err");
        });
    });
}

1;
