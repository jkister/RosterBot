# RosterBot

A Discord bot that automatically collects contact information (email address and/or phone number) from members of Discord servers it belongs to. When a new member joins, RosterBot sends them a private message requesting their contact details and stores the responses in a SQLite database.

Written entirely by Claude Code with only prompting.

---

## Table of Contents

1. [What RosterBot Does](#what-rosterbot-does)
2. [Setting Up a Discord Bot Application](#setting-up-a-discord-bot-application)
3. [Installation](#installation)
4. [Controlling RosterBot](#controlling-rosterbot)
5. [Admin Commands](#admin-commands)
6. [User Commands](#user-commands)
7. [Reading Logs](#reading-logs)
8. [Extracting Data](#extracting-data)

---

## What RosterBot Does

RosterBot monitors Discord servers for new and existing members and sends each member a private DM asking for their email address and/or phone number. Key behaviors:

- **Contact requests**: Sent automatically when a member joins a server or on a periodic schedule (once per week per member, up to 30 per hour).
- **Rate limiting**: No more than 30 contact requests per hour; re-contacts members at most once every 7 days until they respond or opt out.
- **Contact statuses**: Each member has one of four statuses: `pending`, `contacted`, `provided`, or `stopped` (STOP opt-out).
- **Admin notifications**: Admins are notified via DM when members provide contact info, join or leave servers, or send unrecognized messages.
- **Relay**: Non-command DMs from known members are forwarded to admins.
- **Privacy**: Members can opt out at any time by replying `STOP`.

---

## Setting Up a Discord Bot Application

Before installing RosterBot you need to create a Discord bot application and obtain a bot token. See [Discord's developer documentation](https://discord.com/developers/docs/getting-started) for full details.

### Quick steps:

1. Go to [https://discord.com/developers/applications](https://discord.com/developers/applications)
2. Click **New Application** and give it a name (e.g., "RosterBot").
3. In the left sidebar, click **Bot**.
4. Click **Reset Token**, then copy the token. You will paste this into the `etc/.passwd` file after installation.
5. Under **Privileged Gateway Intents**, enable:
   - **Server Members Intent**
   - **Message Content Intent**
6. Click **Save Changes**.

### Generating the invite link

To add the bot to a Discord server, you need to give the server owner an OAuth2 invite link. After RosterBot is running and you have admin access, DM the bot:

```
generate invite
```

RosterBot will reply with a URL. Share this URL with the Discord server administrator. They open the link, choose their server, and authorize the bot.

Alternatively, you can generate the link manually in the Discord Developer Portal:

1. In your application, go to **OAuth2 > URL Generator**.
2. Under Scopes, check **bot**.
3. Leave Bot Permissions unchecked (RosterBot only needs to send DMs and read member lists, which are covered by the `bot` scope).
4. Copy the generated URL.

---

## Installation

See the [INSTALL](INSTALL) file for full instructions. Quick summary:

```sh
# 1. Install dependencies
sudo sh scripts/install-deps.sh

# 2. Configure
./configure \
    --prefix=/usr/local/rosterbot \
    --process-manager=systemd \
    --admin-username=yourdiscordname \
    --admin-id=YOUR_DISCORD_USER_ID

# 3. Build (substitutes paths into build/)
make

# Optional: syntax-check the built files
make test

# 4. Install (as root)
sudo make install

# 5. Add your Discord token
sudo vi /usr/local/rosterbot/etc/.passwd
# Set: DISCORD_TOKEN=Bot.your.token.here

# 6. Restart the bot
sudo systemctl restart rosterbot    # systemd
sudo svc -t /service/rosterbot      # daemontools
sudo /etc/init.d/rosterbot restart  # init.d
```

### Finding your Discord user ID

1. Open Discord → **Settings** → **Advanced** → enable **Developer Mode**.
2. Right-click your username anywhere in Discord → **Copy User ID**.

The copied value (a large number like `123456789012345678`) is your user ID.

---

## Controlling RosterBot

RosterBot is controlled entirely via Discord Direct Messages (DMs). There are no web dashboards or configuration files to edit for day-to-day operation.

### Initial admin setup

The first administrator must be specified at install time via `--admin-id` and `--admin-username`. If you skipped that, add yourself via sqlite3 (see [INSTALL](INSTALL) section 6).

Once you have admin access, you can grant it to others via DM:

```
admin grant username
```

### Customizing the contact request message

The message sent to Discord members requesting their contact info is stored in:

```
$PREFIX/etc/contact_message.txt
```

Edit this file to customize the wording. The bot reads it fresh each time it sends
a contact request, so changes take effect immediately without a restart. The file is
installed with a sensible default and is **never overwritten during upgrades**.

To see the message currently in use, DM the bot:
```
contact print
```

### DMing RosterBot

All commands are sent as DMs to the bot. To start a DM:

1. Find the bot in your server's member list (or search for its username).
2. Click its name → **Send Message**.
3. Type a command and send.

Admin commands are only accepted from users in the `admins` table. Unknown commands from non-admins are silently forwarded to admins.

---

## Admin Commands

All admin commands are sent as DMs to the bot. Usernames are case-insensitive.

### Server management

| Command | Description |
|---------|-------------|
| `list servers` | List all servers the bot is in |
| `server leave "Server Name"` | Leave a server (server name in quotes) |
| `generate invite` | Generate a bot invite URL to share with server owners |

### Member management

| Command | Description |
|---------|-------------|
| `list members` | List all members across all servers |
| `list members "Server Name"` | List members of a specific server |
| `list users` | List all known users with contact status |
| `list users pending` | Filter by status: pending, contacted, provided, stopped |
| `list users pending count` | Show count only instead of full list |

### Messaging

| Command | Description |
|---------|-------------|
| `message username Your message here` | Send a DM to a specific user |
| `message all Your announcement` | Send a DM to all known members |
| `message members "Server Name" Your message` | Send a DM to all members of a server |

### User contact data

| Command | Description |
|---------|-------------|
| `user show username` | Show a user's contact info and status |
| `user update username email addr@example.com` | Set a user's email |
| `user update username phone +15551234567` | Set a user's phone number |
| `user delete username email` | Remove a user's email |
| `user delete username phone` | Remove a user's phone number |
| `contact print` | Print the contact request message |
| `contact resend username` | Force-send a contact request to a user |
| `scheduler trigger` | Immediately run the contact request scheduler |

### Admin management

| Command | Description |
|---------|-------------|
| `admin list` | List all bot administrators |
| `admin grant username` | Grant admin privileges to a user |
| `admin revoke username` | Revoke admin privileges from a user |
| `admin message Your message` | Send a DM to all other admins |

### Help

| Command | Description |
|---------|-------------|
| `help` | Show the full command reference |

---

## Runtime Flags and Configuration

RosterBot accepts command-line flags and also reads `$PREFIX/etc/rosterbot.conf`
at startup. CLI flags always override the config file.

### Command-line flags

| Flag | Short | Description |
|------|-------|-------------|
| `--debug` | `-D` | Enable verbose debug logging |
| `--no-contact` | `-n` | Disable automatic contact requests (useful during maintenance) |
| `--notify-only=USERNAME` | | Send admin notifications only to USERNAME instead of all admins |
| `--help` | `-h` | Do not print this help message |

### Config file

`$PREFIX/etc/rosterbot.conf` is installed with all settings commented out. Edit it to set persistent options without modifying the run script:

```ini
# Enable verbose debug logging
#debug=1

# Disable automatic contact requests
#no-contact=1

# Route all admin notifications to one user
#notify-only=yourusername
```

Valid boolean values: `1`, `yes`, `true` (anything else is false). The file is
never overwritten during upgrades.

---

## User Commands

Any Discord member can send these to the bot via DM:

| Command | Description |
|---------|-------------|
| `update email addr@example.com` | Update your email address |
| `update phone +15551234567` | Update your phone number |
| `STOP` | Stop receiving contact requests |

Members can also reply to the bot's initial contact request in freeform — the bot will try to parse email addresses and phone numbers from the message automatically.

---

## Reading Logs

All log output goes to stderr. How to read it depends on your process manager:

**systemd:**
```sh
# Follow live logs
journalctl -u rosterbot -f

# Show last 100 lines
journalctl -u rosterbot -n 100

# Show logs since a specific time
journalctl -u rosterbot --since "2024-01-01 00:00:00"
```

**daemontools (multilog):**
```sh
tail -f /var/log/rosterbot/current
```

**init.d:**
```sh
tail -f /var/log/rosterbot/rosterbot.log
```

Log entries are prefixed with a timestamp in brackets, e.g.:
```
[Wed Jan  1 12:00:00 2025] Bot is ready!
[Wed Jan  1 12:00:01 2025] Guild available: [My Server]
[Wed Jan  1 12:00:05 2025] Sent contact request to [Alice] [alice]
```

---

## Extracting Data

Use `scripts/export-users.pl` to extract contact data from the database.

```sh
# Default: text table with email and phone for all users
export-users.pl

# All fields for users who provided contact info, CSV format
export-users.pl --status=provided --format=csv --all

# Semicolon-separated, include display name
export-users.pl --format=ssv --display-name --email --phone

# JSON output of pending users
export-users.pl --status=pending --format=json --all

# Specify a non-default database path
export-users.pl --db=/home/users/rosterbot/sql/rosterbot.db
```

Available flags:

| Flag | Description |
|------|-------------|
| `--format=FORMAT` | `text` (default), `csv`, `ssv`, `json` |
| `--email` | Include email column |
| `--phone` | Include phone column |
| `--display-name` | Include Discord display name column |
| `--all` | Include all of the above |
| `--status=STATUS` | Filter: `pending`, `contacted`, `provided`, `stopped` |
| `--db=PATH` | Path to `rosterbot.db` |
| `--[no-]header` | Show/hide column headers |

You can also query the database directly with sqlite3:

```sh
sqlite3 /usr/local/rosterbot/sql/rosterbot.db \
  "SELECT username, display_name, email, phone, contact_status
   FROM users
   WHERE contact_status = 'provided'
   ORDER BY username;"
```
