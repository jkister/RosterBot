package RosterBot::Commands;
use strict;
use warnings;
use 5.020;

use Mojo::IOLoop;
use Exporter 'import';
use Date::Parse;

use RosterBot::Database;
use RosterBot::Utils;
use RosterBot::Contact qw(:DEFAULT CONTACT_REQUEST_INTERVAL);

our @EXPORT = qw(handle_message);

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
            my $invite_url = "https://discord.com/api/oauth2/authorize?client_id=$client_id&permissions=0&scope=bot";
            
            my $response = "**Bot Invite Link**\n\n" .
                          "Share this link with server administrators:\n\n" .
                          "$invite_url";
            
            $send_message->($msg->{channel_id}, $response);
        }
    }
    elsif ($content =~ /^contact print$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $contact_msg = get_contact_message();
            $send_message->($msg->{channel_id}, "**Contact Request Message:**\n\n$contact_msg");
        }
    }
    elsif ($content =~ /^contact resend (\S+)$/i) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $target_username = $1;
            my $target_user_id = find_user_by_name($target_username);
            
            if ($target_user_id) {
                # Force send - bypass all checks
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
                if (validate_email($email)) {
                    db_update_user_contact($target_user_id, $email, undef);
                    $send_message->($msg->{channel_id}, "Updated email for $target_username to: $email");
                } else {
                    $send_message->($msg->{channel_id}, "Invalid email address");
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
    elsif ($content =~ /^admin message (.+)$/is) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $message_content = $1;
            my @admin_ids = db_get_admin_user_ids();
            my $sent_count = 0;
            my $delay = 0;
            
            for my $admin_id (@admin_ids) {
                next if $admin_id eq $author_id;
                
                Mojo::IOLoop->timer($delay, sub {
                    my $result = $send_dm_to_user->($admin_id, $message_content);
                    verbose("Failed to send 'admin message' to [$admin_id]") unless $result;
                });
                $delay += 1;
                $sent_count++;
            }
            
            $send_message->($msg->{channel_id}, "Message sent to $sent_count admin(s)");
        }
    }
    elsif ($content =~ /^list users(?:\s+(pending|contacted|provided|stopped))?(?:\s+(count))?$/i) {
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
                
                if (length($response) > 1800) {
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
                $delay += 1;
            }
        }
    }
    elsif ($content =~ /^message all (.+)$/is) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $message_content = $1;
            my @members = db_get_all_active_members();
            my $bot_id = get_bot_user()->{id};
            my $sent_count = 0;
            my $delay = 0;

            for my $member (@members) {
                next if $member->{user_id} eq $bot_id;
                
                my $uid = $member->{user_id};
                Mojo::IOLoop->timer($delay, sub {
                    my $result = $send_dm_to_user->($uid, $message_content);
                    verbose("Failed to send 'message all' to [$uid]") unless $result;
                });
                $delay += 1;
                $sent_count++;
            }

            my $response = "Sending message to $sent_count users";
            $send_message->($msg->{channel_id}, $response);
        }
    }
    elsif ($content =~ /^message members "([^"]+)" (.+)$/is) {
        $is_command = 1;
        
        unless ($is_admin) {
            $rejected_command = 1;
        } else {
            my $server_name = $1;
            my $message_content = $2;
            
            my $guilds = get_guilds();
            my $found_guild;
            for my $guild_id (keys %$guilds) {
                if (lc($guilds->{$guild_id}{name}) eq lc($server_name)) {
                    $found_guild = $guild_id;
                    last;
                }
            }
            
            if ($found_guild) {
                my @members = db_get_active_members_in_server($found_guild);
                my $bot_id = get_bot_user()->{id};
                my $sent_count = 0;
                my $delay = 0;

                for my $member (@members) {
                    next if $member->{user_id} eq $bot_id;
                    
                    my $uid = $member->{user_id};
                    Mojo::IOLoop->timer($delay, sub {
                        my $result = $send_dm_to_user->($uid, $message_content);
                        verbose("Failed to send 'message members' to [$uid]") unless $result;
                    });
                    $delay += 1;
                    $sent_count++;
                }
                
                my $response = "Sending message to $sent_count users in `$server_name`";
                $send_message->($msg->{channel_id}, $response);
            } else {
                my @available = sort map { $guilds->{$_}{name} } keys %$guilds;
                my $response = "Could not find server '$server_name'.\n\n" .
                              "Available servers:\n" .
                              join("\n", map { "- `$_`" } @available);
                
                $send_message->($msg->{channel_id}, $response);
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

                    if (length($response) > 1800) {
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

                if (length($response) > 1800) {
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

- `list servers` - Show all servers I'm in
- `list members` - Show all members from all servers
- `list members "<server name>"` - Show members of a specific server
- `list users [status] [count]` - Show all users (optionally filter by: pending, contacted, provided, stopped; add 'count' to show only totals)
- `server leave "<server name>"` - Leave a server
- `message <username> <your message>` - Send a DM to a user
- `message all <your message>` - Send a DM to all known users
- `message members "<server name>" <your message>` - Send a DM to all users in a server
- `admin grant <username>` - Grant admin privileges for the bot
- `admin revoke <username>` - Revoke admin privileges from the bot
- `admin list` - List all admins of the bot
- `admin message <your message>` - Send message to all other admins
- `user show <username>` - Show user's contact information
- `user update <username> email <email>` - Update user's email
- `user update <username> phone <phone>` - Update user's phone
- `user delete <username> email` - Delete user's email
- `user delete <username> phone` - Delete user's phone
- `contact print` - Show contact request message
- `contact resend <username>` - Force send contact request
- `scheduler trigger` - Run contact scheduler immediately
- `generate invite` - Generate bot invite link

**User Commands (Anyone):**
- `update email <email>` - Update your email address
- `update phone <phone>` - Update your phone number
- `STOP` - Stop contact information requests

Examples:
- `list members "My Cool Server"`
- `list users pending`
- `message hackerx_67 Hey, how are you?`
- `contact resend someguy`
- `user update alice email alice@example.com`
- `admin message Emergency meeting in 5 minutes`
- `update email john@example.com`

Note: Server names must be in quotes. Usernames are case-insensitive.
HELP
            
            $send_message->($msg->{channel_id}, $response);
        }
    }
    
    # ========== NON-ADMIN COMMANDS ==========
    
    elsif ($content =~ /(?:^|\s)\bstop\b(?:\s|$)/i) {
        $is_command = 1;
        db_update_contact_status($author_id, 'stopped');
        $send_message->($msg->{channel_id}, "Understood. I will stop asking you for contact information.");
        verbose("User [$author_username] opted out of contact requests");
    }
    elsif ($content =~ /^update email (.+)$/i) {
        $is_command = 1;
        my $email = $1;
        $email =~ s/^\s+|\s+$//g;
        
        if (validate_email($email)) {
            db_update_user_contact($author_id, $email, undef);
            $send_message->($msg->{channel_id}, "Your email address has been updated to: $email");
            verbose("User [$author_username] updated email to [$email]");

            # Notify admins
            my $display_name = get_display_name($author_id);
            my $notification = "**CONTACT INFO UPDATED** `$display_name` `$author_username`:\nEmail: $email";
         
            $notify_admins->($notification);
        } else {
            $send_message->($msg->{channel_id}, "That doesn't look like a valid email address. Please try again.");
        }
    }
    elsif ($content =~ /^update phone (.+)$/i) {
        $is_command = 1;
        my $phone = $1;
        $phone =~ s/^\s+|\s+$//g;
        
        if (validate_phone($phone)) {
            my $normalized_phone = normalize_phone_to_e164($phone);
            db_update_user_contact($author_id, undef, $normalized_phone);
            $send_message->($msg->{channel_id}, "Your phone number has been updated to: $normalized_phone");
            verbose("User [$author_username] updated phone to [$normalized_phone]");

           # Notify admins
            my $display_name = get_display_name($author_id);
            my $notification = "**CONTACT INFO UPDATED** `$display_name` `$author_username`:\nPhone: $normalized_phone";
         
            $notify_admins->($notification);
        } else {
            $send_message->($msg->{channel_id}, "That doesn't look like a valid phone number. Please try again.");
        }
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
            $response .= "\nYou can update this information anytime by messaging me:\n";
            $response .= "- `update email your.email\@example.com`\n";
            $response .= "- `update phone +1-555-123-4567`";
            
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
    
    elsif ($content =~ /^(list|message|admin|generate|user|contact|server)\s/i) {
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

1;
