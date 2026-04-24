package RosterBot::Commands;
use strict;
use warnings;
use 5.020;

use Mojo::IOLoop;
use Exporter 'import';
use Date::Parse;

use RosterBot::Database;
use RosterBot::Utils qw(:DEFAULT set_notify_only_override reset_notify_only_override);
use RosterBot::Contact qw(:DEFAULT CONTACT_REQUEST_INTERVAL);

our @EXPORT = qw(handle_message);

use constant DISCORD_MESSAGE_CHUNK_LIMIT => DISCORD_MESSAGE_LIMIT;

sub handle_message {
    my ($msg, $send_message, $send_dm_to_user, $notify_admins, $send_contact_request) = @_;
    
    return if $msg->{author}{bot};
    return if $msg->{guild_id};
    
    my $content = normalize_unicode($msg->{content});
    my $author_id = $msg->{author}{id};
    my $author_username = $msg->{author}{username};
    $author_username .= "#" . $msg->{author}{discriminator}
        if $msg->{author}{discriminator} && $msg->{author}{discriminator} ne '0';
    
    debug("Processing DM from [$author_username]: $content");
    
    my $is_admin = db_is_admin($author_id);
    debug("User [$author_username] is admin: " . ($is_admin ? "yes" : "no"));
    
    my $is_command = 0;
    my $syntax_error = 0;
    my $rejected_command = 0;
    
    # ========== ADMIN COMMANDS ==========
    
    if ($content =~ /^generate invite$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $client_id = get_bot_user()->{id};
            my $invite_url = "https://discord.com/api/oauth2/authorize?client_id=$client_id&permissions=4&scope=bot";
            
            my $response = "**Bot Invite Link**\n\n" .
                          "Share this link with server administrators:\n\n" .
                          "$invite_url";
            
            $send_message->($msg->{channel_id}, $response);
        }
    }
    elsif ($content =~ /^print contact$/i) {
        $is_command = 1;

        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $contact_msg = get_contact_message();
            $send_message->($msg->{channel_id}, "**Contact Request Message:**\n\n$contact_msg");
        }
    }
    elsif ($content =~ /^resend contact (\S+)$/i) {
        $is_command = 1;

        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $target_user_id = find_user_by_name($target_username);

            if ($target_user_id) {
                my $result = $send_contact_request->($target_user_id);

                if ($result) {
                    $send_message->($msg->{channel_id}, "Contact request sent to $target_username");
                    verbose("Admin forced contact request to [$target_username]");
                } else {
                    $send_message->($msg->{channel_id}, "Failed to send contact request to $target_username");
                }
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^print scammer$/i) {
        $is_command = 1;

        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $scammer_msg = get_scammer_warning_message();
            $send_message->($msg->{channel_id}, "**Scammer Warning Message:**\n\n$scammer_msg");
        }
    }
    elsif ($content =~ /^resend scammer (\S+)$/i) {
        $is_command = 1;

        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $target_user_id = find_user_by_name($target_username);

            if ($target_user_id) {
                my $scammer_msg = get_scammer_warning_message();
                my $result = $send_dm_to_user->($target_user_id, $scammer_msg);

                if ($result) {
                    $send_message->($msg->{channel_id}, "Scammer warning sent to $target_username");
                    verbose("Admin forced scammer warning to [$target_username]");
                } else {
                    $send_message->($msg->{channel_id}, "Failed to send scammer warning to $target_username");
                }
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^scheduler trigger$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            debug("Admin triggered scheduler manually");
            
            # Call the Discord module's contact request function directly
            RosterBot::Discord::trigger_contact_scheduler();
            
            $send_message->($msg->{channel_id}, "Scheduler triggered - checking for pending contact requests");
        }
    }
    elsif ($content =~ /^server leave "([^"]+)"$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $server_name = $1;
            
            my $guilds = get_guilds();
            my $found_guild;
            for my $guild_id (keys %$guilds) {
                if (lc($guilds->{$guild_id}{name}) eq lc($server_name)) {
                    $found_guild = $guild_id;
                    last;
                }
            }
            
            if ($found_guild) {
                my $api_result = RosterBot::Discord::leave_guild($found_guild);
                
                if ($api_result) {
                    $send_message->($msg->{channel_id}, "Left server `$server_name`");
                    verbose("Left guild [$server_name] by admin request");
                } else {
                    $send_message->($msg->{channel_id}, "Failed to leave server `$server_name`");
                }
            } else {
                my @available = sort map { $guilds->{$_}{name} } keys %$guilds;
                my $response = "Could not find server '$server_name'.\n\n" .
                              "Available servers:\n" .
                              join("\n", map { "- `$_`" } @available);
                
                $send_message->($msg->{channel_id}, $response);
            }
        }
    }
    elsif ($content =~ /^user update (\S+) email (.+)$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $email = $2;
            $email =~ s/^\s+|\s+$//g;
            
            my $target_user_id = find_user_by_name($target_username);
            
            if ($target_user_id) {
                my ($email_ok, $email_reason) = validate_email($email);
                if ($email_ok) {
                    db_update_user_contact($target_user_id, $email, undef);
                    $send_message->($msg->{channel_id}, "Updated email for $target_username to: $email");
                } else {
                    $send_message->($msg->{channel_id}, "Invalid email address: $email_reason");
                }
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^user update (\S+) phone (.+)$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $phone = $2;
            $phone =~ s/^\s+|\s+$//g;
            
            my $target_user_id = find_user_by_name($target_username);
            
            if ($target_user_id) {
                if (validate_phone($phone)) {
                    my $normalized_phone = normalize_phone_to_e164($phone);
                    db_update_user_contact($target_user_id, undef, $normalized_phone);
                    $send_message->($msg->{channel_id}, "Updated phone for $target_username to: $normalized_phone");
                } else {
                    $send_message->($msg->{channel_id}, "Invalid phone number");
                }
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^user delete (\S+) email$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $target_user_id = find_user_by_name($target_username);
            
            if ($target_user_id) {
                RosterBot::Database::db_delete_user_email($target_user_id);
                $send_message->($msg->{channel_id}, "Deleted email for $target_username");
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^user delete (\S+) phone$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $target_user_id = find_user_by_name($target_username);
            
            if ($target_user_id) {
                RosterBot::Database::db_delete_user_phone($target_user_id);
                $send_message->($msg->{channel_id}, "Deleted phone for $target_username");
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^user show (\S+)$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $target_user_id = find_user_by_name($target_username);
            
            if ($target_user_id) {
                my $contact_info = db_get_user_contact_info($target_user_id);
                my $display_name = get_display_name($target_user_id);
                my $full_username = get_username($target_user_id);
                
                my $response = "**User Information:**\n\n";
                $response .= "Display Name: `$display_name`\n";
                $response .= "Username: `$full_username`\n";
                $response .= "Email: " . ($contact_info->{email} || "none") . "\n";
                $response .= "Phone: " . ($contact_info->{phone} || "none") . "\n";
                $response .= "Status: " . ($contact_info->{contact_status} || "unknown") . "\n";
                $response .= "Last contacted: " . ($contact_info->{last_contact_request} || "never");
                
                $send_message->($msg->{channel_id}, $response);
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^user\s+/i) {
        $is_command = 1;
        $syntax_error = 1;
    
        if ($is_admin) {
            $send_message->($msg->{channel_id}, "Syntax error in 'user' command. Type `help` for command list.");
        }
    }
    elsif ($content =~ /^admin grant (\S+)$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $target_user_id = find_user_by_name($target_username);
            
            if ($target_user_id) {
                my $target_full_username = get_username($target_user_id);
                my $added = db_add_admin($target_user_id, $target_full_username, $author_id);
                
                if ($added) {
                    $send_message->($msg->{channel_id}, "Admin privileges granted to `$target_full_username`");
                    
                    my $notify_msg = "You have been granted administrator privileges for the RosterBot. Type `help` to see available commands.";
                    $send_dm_to_user->($target_user_id, $notify_msg);
                } else {
                    $send_message->($msg->{channel_id}, "`$target_full_username` is already an admin.");
                }
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^admin revoke (\S+)$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $target_user_id = find_user_by_name($target_username);
            
            if ($target_user_id) {
                my $target_full_username = get_username($target_user_id);
                my $removed = db_remove_admin($target_user_id);
                
                if ($removed) {
                    $send_message->($msg->{channel_id}, "Admin privileges revoked from `$target_full_username`");
                } else {
                    $send_message->($msg->{channel_id}, "`$target_full_username` is not an admin.");
                }
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^admin notify_only --reset$/i) {
        $is_command = 1;

        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            reset_notify_only_override();
            my $config_target = get_notify_only_user() // "all admins";
            $send_message->($msg->{channel_id}, "Notification target reset to config value: $config_target");
            verbose("Admin [$author_username] reset notify_only override");
        }
    }
    elsif ($content =~ /^admin notify_only (\S+)$/i) {
        $is_command = 1;

        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $target_user_id = find_user_by_name($target_username);

            if ($target_user_id) {
                unless (db_is_admin($target_user_id)) {
                    $send_message->($msg->{channel_id}, "Cannot set notify_only: '$target_username' is not an admin");
                } else {
                    my $target_full_username = get_username($target_user_id);
                    set_notify_only_override($target_full_username);
                    $send_message->($msg->{channel_id}, "Admin notifications temporarily redirected to: `$target_full_username`\nUse `admin notify_only --reset` to restore.");
                    verbose("Admin [$author_username] set notify_only override to [$target_full_username]");
                }
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^admin list$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my @admins = db_get_admins();
            my $response = "**Administrators** (" . scalar(@admins) . " total):\n\n";
            
            for my $admin (@admins) {
                $response .= "- `$admin->{username}` (granted: $admin->{granted_at})\n";
            }
            
            $send_message->($msg->{channel_id}, $response);
        }
    }
    elsif ($content =~ /^list users(?:\s+(pending|contacted|provided|stopped|banned))?(?:\s+(count))?$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $status_filter = $1 ? lc($1) : undef;
            my $count_only = $2 ? 1 : 0;
            
            my @users = db_get_all_users_with_contact($status_filter);
            
            # If count only, just show the number
            if ($count_only) {
                my $status_text = $status_filter ? "with status '$status_filter'" : "total";
                my $response = "**User count $status_text:** " . scalar(@users);
                $send_message->($msg->{channel_id}, $response);
                return;
            }
            
            # Otherwise show full list
            my $status_text = $status_filter ? "with status '$status_filter'" : "All Known Users";
            my $response = "**$status_text** (" . scalar(@users) . " total):\n\n";
            my @chunks;
            
            for my $user (@users) {
                my $display = $user->{display_name} || $user->{username};
                $display =~ s/#.*$//;
                
                $response .= "- `$display` `$user->{username}`";
                $response .= " [" . ($user->{email} || "no email") . "]";
                $response .= " [" . ($user->{phone} || "no phone") . "]";
                $response .= " [contacted " . ($user->{contact_count} || 0) . "x]";
                
                # For contacted status, show next eligible contact time
                if ($status_filter && $status_filter eq 'contacted' && $user->{last_contact_request}) {
                    my $last_contact_time = str2time($user->{last_contact_request}, 'UTC');
                    my $next_eligible = $last_contact_time + CONTACT_REQUEST_INTERVAL;
                    my $seconds_until = $next_eligible - time();
                    
                    if ($seconds_until > 0) {
                        my $days = int($seconds_until / 86400);
                        my $hours = int(($seconds_until % 86400) / 3600);
                        my $mins = int(($seconds_until % 3600) / 60);
                        my $secs = int($seconds_until % 60);
                        $response .= " [Next: ${days}d ${hours}h ${mins}m ${secs}s]";
                    } else {
                        $response .= " [Next: eligible now]";
                    }
                }


                $response .= "\n";

                if (length($response) > DISCORD_MESSAGE_CHUNK_LIMIT) {
                    push @chunks, $response;
                    $response = "";
                }
            }
            
            if (!@users) {
                $response = $status_filter ? "No users found with status '$status_filter'." : "No users found.";
            }
            
            push @chunks, $response if $response;

            my $delay = 0;
            my $cid = $msg->{channel_id};
            for my $chunk (@chunks) {
                Mojo::IOLoop->timer($delay, sub { $send_message->($cid, $chunk) });
                $delay = ($delay + 1) > 60 ? 60 : ($delay + 1);  # Cap at 60 seconds
            }
        }
    }
    elsif ($content =~ /^message (\S+) (.+)$/is) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $message_content = $2;
            
            my $target_user_id = find_user_by_name($target_username);
            
            if ($target_user_id) {
                if ($target_user_id eq get_bot_user()->{id}) {
                    $send_message->($msg->{channel_id}, "I cannot send messages to myself!");
                    return;
                }
                
                if ($target_user_id eq $author_id) {
                    $send_message->($msg->{channel_id}, "You cannot send messages to yourself!");
                    return;
                }
                
                my $result = $send_dm_to_user->($target_user_id, $message_content);
                
                if ($result) {
                    $send_message->($msg->{channel_id}, "Message sent to $target_username");
                } else {
                    $send_message->($msg->{channel_id}, 
                        "Failed to send message to $target_username. They may have DMs disabled.");
                }
            } else {
                $send_message->($msg->{channel_id}, "Could not find user '$target_username'");
            }
        }
    }
    elsif ($content =~ /^list members "([^"]+)"$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $server_name = $1;
            
            my $guilds = get_guilds();
            my $found_guild;
            for my $guild_id (keys %$guilds) {
                if (lc($guilds->{$guild_id}{name}) eq lc($server_name)) {
                    $found_guild = $guild_id;
                    last;
                }
            }
            
            if ($found_guild) {
                my $guild = $guilds->{$found_guild};
                my @members = sort { 
                    lc($a->{username}) cmp lc($b->{username}) 
                } values %{$guild->{members}};
                
                my $response = "**Members of `$guild->{name}`** (" . scalar(@members) . " total):\n\n";
                my @chunks;

                for my $member (@members) {
                    my $display_name;
                    if ($member->{nick} && $member->{nick} ne '') {
                        $display_name = $member->{nick};
                    } elsif ($member->{global_name} && $member->{global_name} ne '') {
                        $display_name = $member->{global_name};
                    } else {
                        $display_name = $member->{username};
                        $display_name =~ s/#.*$//;
                    }

                    $response .= "- `$display_name` -> `$member->{username}`\n";

                    if (length($response) > DISCORD_MESSAGE_CHUNK_LIMIT) {
                        push @chunks, $response;
                        $response = "";
                    }
                }

                push @chunks, $response if $response;
                my $delay = 0;
                my $cid = $msg->{channel_id};
                for my $chunk (@chunks) {
                    Mojo::IOLoop->timer($delay, sub { $send_message->($cid, $chunk) });
                    $delay += 1;
                }
            } else {
                my @available = sort map { $guilds->{$_}{name} } keys %$guilds;
                my $response = "Could not find server '$server_name'.\n\n" .
                              "Available servers:\n" .
                              join("\n", map { "- `$_`" } @available);
                
                $send_message->($msg->{channel_id}, $response);
            }
        }
    }
    elsif ($content =~ /^list members$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $guilds = get_guilds();
            my %all_members;
            for my $guild_id (keys %$guilds) {
                for my $user_id (keys %{$guilds->{$guild_id}{members}}) {
                    $all_members{$user_id} = $guilds->{$guild_id}{members}{$user_id};
                }
            }
            
            my @members = sort { 
                lc($a->{username}) cmp lc($b->{username}) 
            } values %all_members;
            
            my $response = "**All Members** (" . scalar(@members) . " total):\n\n";
            my @chunks;

            for my $member (@members) {
                my $display_name;
                if ($member->{nick} && $member->{nick} ne '') {
                    $display_name = $member->{nick};
                } elsif ($member->{global_name} && $member->{global_name} ne '') {
                    $display_name = $member->{global_name};
                } else {
                    $display_name = $member->{username};
                    $display_name =~ s/#.*$//;
                }

                $response .= "- `$display_name` -> `$member->{username}`\n";

                if (length($response) > DISCORD_MESSAGE_CHUNK_LIMIT) {
                    push @chunks, $response;
                    $response = "";
                }
            }

            push @chunks, $response if $response;
            my $delay = 0;
            my $cid = $msg->{channel_id};
            for my $chunk (@chunks) {
                Mojo::IOLoop->timer($delay, sub { $send_message->($cid, $chunk) });
                $delay = ($delay + 1) > 60 ? 60 : ($delay + 1);  # Cap at 60 seconds
            }
        }
    }
    elsif ($content =~ /^list servers$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $guilds = get_guilds();
            my @servers = sort map { $guilds->{$_}{name} } keys %$guilds;
            my $response = "**Servers I'm in** (" . scalar(@servers) . " total):\n\n" .
                          join("\n", map { "- `$_`" } @servers) .
                          "\n\nTo see members, use: `list members \"<server name>\"`";
            
            $send_message->($msg->{channel_id}, $response);
        }
    }
    elsif ($content =~ /^help$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $response = <<'HELP';
**RosterBot Commands (Admin Only)**

- `admin grant <username>` - Grant admin privileges for the bot
- `admin list` - List all admins of the bot
- `admin notify_only <username>` - Temporarily redirect all admin notifications to one admin (runtime only, resets on restart)
- `admin notify_only --reset` - Restore notification target to config value
- `admin revoke <username>` - Revoke admin privileges from the bot
- `generate invite` - Generate bot invite link
- `list members` - Show all members from all servers
- `list members "<server name>"` - Show members of a specific server
- `list servers` - Show all servers I'm in
- `list users [status] [count]` - Show all users (optionally filter by: pending, contacted, provided, stopped, banned; add 'count' to show only totals)
- `message <username> <your message>` - Send a DM to a user
- `print contact` - Show contact request message
- `print scammer` - Show scammer warning message
- `resend contact <username>` - Force send contact request
- `resend scammer <username>` - Force send scammer warning
- `scheduler trigger` - Run contact scheduler immediately
- `server leave "<server name>"` - Leave a server
- `user delete <username> email` - Delete user's email
- `user delete <username> phone` - Delete user's phone
- `user show <username>` - Show user's contact information
- `user update <username> email <email>` - Update user's email
- `user update <username> phone <phone>` - Update user's phone

**User Commands (Anyone):**
- `STOP` - Stop contact information requests

Examples:
- `list members "My Cool Server"`
- `list users pending`
- `message hackerx_67 Hey, how are you?`
- `resend contact someguy`
- `user update alice email alice@example.com`

Note: Server names must be in quotes. Usernames are case-insensitive.
HELP
            
            $send_message->($msg->{channel_id}, $response);
        }
    }
    
    # ========== NON-ADMIN COMMANDS ==========

    elsif (_fuzzy_scammer_ack($content)) {
        $is_command = 1;

        my $contact_info = db_get_user_contact_info($author_id);

        if ($contact_info && !$contact_info->{scammer_ack}) {
            db_set_scammer_ack($author_id);
            verbose("User [$author_username] acknowledged scammer warning");

            my $display_name = get_display_name($author_id);

            if (RosterBot::Discord::get_require_role_grant()) {
                $send_message->($msg->{channel_id}, "Good. An admin will now review your request to join the server - it takes a day or two.");
                $notify_admins->("**USER READY FOR APPROVAL** `$display_name` `$author_username` agreed about scammers");
            } else {
                db_set_user_approved($author_id);
                $send_message->($msg->{channel_id}, "Good. I'll be in touch shortly with more information.");
                $notify_admins->("**USER SCAMMER ACK** `$display_name` `$author_username` agreed about scammers (auto-approved)");

                my $updated = db_get_user_contact_info($author_id);
                if ($updated &&
                    $updated->{contact_status} ne STATUS_PROVIDED &&
                    $updated->{contact_status} ne STATUS_STOPPED &&
                    $updated->{contact_status} ne STATUS_BANNED &&
                    !was_contacted_within_interval($author_id, $updated)) {

                    $send_contact_request->($author_id);
                }
            }
        } else {
            $send_message->($msg->{channel_id}, "Already received, thank you.");
        }
    }
    elsif ($content =~ /(?:^|\s)\bstop\b(?:\s|$)/i) {
        $is_command = 1;
        db_update_contact_status($author_id, STATUS_STOPPED);
        $send_message->($msg->{channel_id}, "Understood. I will stop asking you for contact information.");
        verbose("User [$author_username] opted out of contact requests");
    }
    # ========== CONTACT INFO DETECTION (catch-all for unstructured input) ==========
    
    elsif ($content =~ /email\s*:/i || $content =~ /phone\s*:/i || 
           $content =~ /\S+@\S+\.\S+/ || $content =~ /\(?\d{3}\)?[\s\-]?\d{3}[\s\-]?\d{4}/) {
        $is_command = 1;
        my ($email, $phone) = process_contact_info($content);
        
        if ($email || $phone) {
            my $normalized_phone = $phone ? normalize_phone_to_e164($phone) : undef;
            db_update_user_contact($author_id, $email, $normalized_phone);
            
            my $response = "Thank you! I've recorded your contact information:\n";
            $response .= "Email: $email\n" if $email;
            $response .= "Phone: $normalized_phone\n" if $normalized_phone;
            $response .= "\nYou can update this information anytime by messaging me your email/phone again.";
            
            $send_message->($msg->{channel_id}, $response);
            verbose("User [$author_username] provided contact info");

            # Notify admins
            my $display_name = get_display_name($author_id);
            my $notification = "**CONTACT INFO COLLECTED** from `$display_name` `$author_username`:\n";
            $notification .= "Email: $email\n" if $email;
            $notification .= "Phone: $normalized_phone" if $normalized_phone;
         
            $notify_admins->($notification);
        } else {
            $send_message->($msg->{channel_id}, 
                "I couldn't validate the contact information you provided. Please check the format and try again.\n\n" .
                "Expected format:\nEmail: your.email\@example.com\nPhone: +1-555-123-4567");
        }
    }
    
    # ========== SYNTAX ERROR CATCH-ALL ==========
    
    elsif ($content =~ /^(list|message|admin|generate|user|server|print|resend)\s/i) {
        $is_command = 1;
        $syntax_error = 1;
        
        if ($is_admin) {
            $send_message->($msg->{channel_id}, "Syntax error. Type `help` for command list.");
        }
    }
    
    # ========== RELAY LOGIC ==========
    
    if ($rejected_command || (!$is_admin && $syntax_error)) {
        my $display_name = get_display_name($author_id);
        my $notification = "**COMMAND REJECTED** **From `$display_name` `$author_username`:** $content";
     
        $notify_admins->($notification);
    }
    elsif (!$is_command && is_known_member($author_id) && !$is_admin) {
        my $display_name = get_display_name($author_id);
        my $notification = "**[RELAYED] From `$display_name` `$author_username`:** $content";
     
        $notify_admins->($notification);

        $send_message->($msg->{channel_id}, "I'm just a simple bot, I'm not sure what you mean - please ask in main channel");
    }
}

sub _fuzzy_scammer_ack {
    my ($input) = @_;
    my $canonical = 'scammers are everywhere and i have read the above';
    # normalize: lowercase, collapse whitespace
    (my $normalized = lc($input)) =~ s/\s+/ /g;
    $normalized =~ s/^\s+|\s+$//g;
    return 1 if $normalized eq $canonical;
    # allow up to 5 edit-distance errors (covers ~10% of phrase length)
    return _levenshtein($normalized, $canonical) <= 5;
}

sub _levenshtein {
    my ($s, $t) = @_;
    my ($n, $m) = (length($s), length($t));
    return $m unless $n;
    return $n unless $m;
    my @d;
    $d[$_][0] = $_ for 0 .. $n;
    $d[0][$_] = $_ for 0 .. $m;
    for my $i (1 .. $n) {
        for my $j (1 .. $m) {
            my $cost = substr($s, $i-1, 1) eq substr($t, $j-1, 1) ? 0 : 1;
            $d[$i][$j] = _min3($d[$i-1][$j] + 1, $d[$i][$j-1] + 1, $d[$i-1][$j-1] + $cost);
        }
    }
    return $d[$n][$m];
}

sub _min3 { $_[0] < $_[1] ? ($_[0] < $_[2] ? $_[0] : $_[2]) : ($_[1] < $_[2] ? $_[1] : $_[2]) }

1;
