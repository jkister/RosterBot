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
use RosterBot::Utils;
use RosterBot::Contact;
use RosterBot::Commands;

our @EXPORT = qw(start leave_guild trigger_contact_scheduler discord_shutdown);

# Configuration
my $DB_PATH = '@DBFILE@';
my $api_base = 'https://discord.com/api/v10';
my $PASSWD_FILE = '@PASSWDFILE@';
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
my $heartbeat_interval;
my $last_sequence;
my $session_id;
my $resume_gateway_url;
my $heartbeat_timer;
my $contact_request_timer;

sub discord_shutdown {
    verbose("Shutting down cleanly...");
    $shutting_down = 1;
    Mojo::IOLoop->remove($heartbeat_timer) if $heartbeat_timer;
    Mojo::IOLoop->remove($contact_request_timer) if $contact_request_timer;
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
    verbose("Starting Discord bot...");
    
    # Initialize database
    db_init($DB_PATH);
    verbose("Connected to database: $DB_PATH");
    
    # Initialize HTTP client
    $ua = Mojo::UserAgent->new;
    $ua->inactivity_timeout(300);
    
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
        my $code = $response->{code};
        # Any error should trigger 24-hour backoff
        return 1 if ($code == 50007 || $code == 340002 || $code == 20026);
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
    
    debug("Creating DM channel with user [$user_id]");
    
    my $dm_channel = discord_api('POST', "/users/\@me/channels", { 
        recipient_id => $user_id 
    });
    
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
    return send_message($channel_id, $content);
}

sub notify_admins {
    my ($message) = @_;
    
    my $notify_only = RosterBot::Utils::get_notify_only_user();
    
    if ($notify_only) {
        my $user_id = RosterBot::Utils::find_user_by_name($notify_only);
        if ($user_id) {
            send_dm_to_user($user_id, $message);
        } else {
            verbose("WARNING: Could not find user '$notify_only' for notification");
        }
    } else {
        my @admin_ids = db_get_admin_user_ids();
        for my $admin_id (@admin_ids) {
            send_dm_to_user($admin_id, $message);
        }
    }
}

sub send_contact_request {
    my ($user_id, $username, $display_name) = @_;
    
    # If not provided, look them up
    $display_name //= get_display_name($user_id);
    $username //= get_username($user_id);
    
    my $message = get_contact_message();
    
    my $result = send_dm_to_user($user_id, $message);
    
    if ($result) {
        if (is_dm_blocked($result)) {
            verbose("DM blocked for [$display_name] [$username] - not updating last_contact_request");
            return undef;
        }
        
        db_update_last_contact_request($user_id);
        db_update_contact_status($user_id, 'contacted');
        increment_contact_request_count();
        verbose("Sent contact request to [$display_name] [$username]");
        return 1;
    } else {
        verbose("Failed to send contact request to [$display_name] [$username]");
        db_update_last_contact_request($user_id);
        return undef;
    }
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
        my $display = $user->{display_name} || $user->{username};
        $display =~ s/#.*$//;
        
        # Schedule non-blocking
        Mojo::IOLoop->timer($delay, sub {
            send_contact_request($uid, $uname, $display);
        });
        
        $delay += CONTACT_REQUEST_DELAY;
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
    debug("Sending heartbeat (seq: " . ($last_sequence // 'null') . ")");
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
            db_update_contact_status($user->{id}, 'banned');
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
    
    debug("Gateway event: OP=$op" . (defined $event ? " Event=$event" : ""));
    
    if ($op == 10) {
        $heartbeat_interval = $data->{heartbeat_interval};
        verbose("Received HELLO (heartbeat interval: ${heartbeat_interval}ms)");
        
        Mojo::IOLoop->remove($heartbeat_timer) if $heartbeat_timer;
        $heartbeat_timer = Mojo::IOLoop->recurring($heartbeat_interval / 1000, sub { send_heartbeat() });
        
        if ($session_id) {
            send_resume();
        } else {
            send_identify();
        }
    }
    elsif ($op == 11) {
        debug("Received heartbeat ACK");
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
    }
    elsif ($event eq 'GUILD_CREATE') {
        my $guild = $data;
        verbose("Guild available: [$guild->{name}]");
        
        db_upsert_server($guild->{id}, $guild->{name}, 'active');
        
        my $guilds = get_guilds();
        $guilds->{$guild->{id}} = {
            name => $guild->{name},
            members => {},
        };
        
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
        my @rate_limited_queue;

        for my $member (@$members) {
            my $user = $member->{user};
            next if $user->{id} eq $bot_id;

            my $username = $user->{username};
            $username .= "#" . $user->{discriminator}
                if $user->{discriminator} && $user->{discriminator} ne '0';

            db_upsert_user($user->{id}, $username, $user->{global_name});
            db_upsert_membership($guild_id, $user->{id}, $member->{nick}, 'member', $member->{joined_at});

            $guilds->{$guild_id}{members}{$user->{id}} = {
                username => $username,
                nick => $member->{nick},
                global_name => $user->{global_name},
                joined => $member->{joined_at},
            };

            my $cache_name = lc($user->{username});
            $user_cache->{$cache_name} = $user->{id};

            my $contact_info = db_get_user_contact_info($user->{id});
            if ($contact_info && $contact_info->{contact_status} eq 'pending' &&
                !$contact_info->{email} && !$contact_info->{phone} &&
                !was_contacted_within_interval($user->{id}, $contact_info)) {

                if (can_send_contact_request()) {
                    my $uid = $user->{id};
                    my $uname = $username;
                    my $display = $member->{nick} || $user->{global_name} || $username;
                    $display =~ s/#.*$//; # Strip discriminator

                    # Schedule non-blocking
                    Mojo::IOLoop->timer($delay, sub {
                        send_contact_request($uid, $uname, $display);
                    });
                    $delay += CONTACT_REQUEST_DELAY;
                } else {
                    my $display = $member->{nick} || $user->{global_name} || $username;
                    $display =~ s/#.*$//;
                    push @rate_limited_queue, "$display ($username)";
                }
            }
        }

        if (@rate_limited_queue) {
            verbose("Rate limit reached; skipped " . scalar(@rate_limited_queue) . " user(s): " .
                    join(', ', @rate_limited_queue));
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
        db_upsert_membership($guild_id, $user->{id}, $member->{nick}, 'member', $member->{joined_at});
        
        $guilds->{$guild_id}{members}{$user->{id}} = {
            username => $username,
            nick => $member->{nick},
            global_name => $user->{global_name},
            joined => $member->{joined_at},
        };
        
        my $user_cache = get_user_cache();
        my $cache_name = lc($user->{username});
        $user_cache->{$cache_name} = $user->{id};
        
        verbose("Member [$username] joined [$guilds->{$guild_id}{name}]");
        
        # Check if we should send contact request
        my $contact_info = db_get_user_contact_info($user->{id});

        unless ($contact_info){
            verbose( "ERROR: No contact_info for [$username] <$user->{id}>" );
            return;
        }
        
        debug("Contact info for [$username]:");
        debug("  Status: $contact_info->{contact_status}");
        debug("  Email: " . ($contact_info->{email} || "none"));
        debug("  Phone: " . ($contact_info->{phone} || "none"));
        debug("  Last contacted: " . ($contact_info->{last_contact_request} || "never"));
        
        # Send contact request if:
        # - They haven't provided contact info yet (not 'provided')
        # - They haven't opted out (not 'stopped')
        # - We haven't contacted them within the contact interval
        # - We haven't hit the hourly rate limit
        my $recently_contacted = was_contacted_within_interval($user->{id}, $contact_info);

        if ($contact_info->{contact_status} ne 'provided' &&
            $contact_info->{contact_status} ne 'stopped' &&
            !$recently_contacted) {

            if (can_send_contact_request()) {
                my $display = $member->{nick} || $user->{global_name} || $username;
                $display =~ s/#.*$//; # Strip discriminator

                debug("Sending contact request to [$username]");
                send_contact_request($user->{id}, $username, $display);
            } else {
                my $display = $member->{nick} || $user->{global_name} || $username;
                $display =~ s/#.*$//;
                verbose("Rate limit reached; skipped 1 user: $display ($username)");
            }
        } else {
            if ($contact_info->{contact_status} eq 'provided') {
                debug("NOT sending: already provided contact info");
            } elsif ($contact_info->{contact_status} eq 'stopped') {
                debug("NOT sending: user opted out (STOP)");
            } elsif ($recently_contacted) {
                debug("NOT sending: already contacted within interval");
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
            my $notice = "NOTICE: `$display_name` <`$full_username`> has left `$server_name`";
            notify_admins($notice);
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

            $guilds->{$guild_id}{members}{$user->{id}}{username} = $username;
            $guilds->{$guild_id}{members}{$user->{id}}{nick} = $member->{nick};
            $guilds->{$guild_id}{members}{$user->{id}}{global_name} = $user->{global_name};
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

        db_update_contact_status($user->{id}, 'banned');
        verbose("Member [$username] banned from [$server_name]");
        notify_admins("NOTICE: `$username` has been banned from `$server_name`");
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

        db_update_contact_status($user->{id}, 'pending');
        verbose("Member [$username] unbanned from [$server_name]");
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
            Mojo::IOLoop->timer(15, sub {
                connect_gateway();
            });
            return;
        }
        
        verbose("WebSocket connected!");
        $tx->max_websocket_size(10 * 1024 * 1024);  # 10 MB; default 256 KB is too small for large guild member chunks
        $ws = $tx;
        
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
            Mojo::IOLoop->timer(5, sub {
                verbose("Reconnecting...");
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
