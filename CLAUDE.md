## What this is

RosterBot is a Discord bot that collects contact info (email/phone) from members of
known servers. When it finds a member without contact info on record, it DMs them
requesting it and saves the response to a database.

## Response Rules

- Answer questions with statements only - no code changes or actions.
- A prompt is a question if it starts with: am, is, are, was, were, do, does, did,
  can, could, should, will, would, what, where, when, why, who, which, or ends with `?`.

## General

- The system we are running on is only a development box with a git repo.**
- Nothing here runs locally.
  All runtime dependencies live on a separate target system.
  Do not attempt to install prerequisites on this system

## Tech Stack

- **Language**: Perl 5.020+
- **Discord integration**: Mojo::UserAgent, Mojo::IOLoop, Mojo::JSON (async WebSocket via Mojo framework)
- **Database**: SQLite via DBI
- **Validation**: Mail::VRFY syntax+DNS (method='compat', with English error reporting), regex/E.164 digit-count (phone)
- **Process supervision**: daemontools/supervise

## Source Files

| File | Role |
|------|------|
| `scripts/rosterbot.pl` | Entry point; CLI flags (--debug, --no-contact, --notify-only) |
| `lib/RosterBot/Discord.pm` | WebSocket gateway, event dispatching, message sending |
| `lib/RosterBot/Database.pm` | SQLite CRUD for users/servers/admins |
| `lib/RosterBot/Contact.pm` | Email/phone validation, normalization, contact request logic |
| `lib/RosterBot/Commands.pm` | DM parsing, admin and user command handlers |
| `lib/RosterBot/Utils.pm` | Logging, guild/user in-memory cache, user lookup |
| `sql/rosterbot.sql` | Schema init (servers, users, memberships, admins tables) |
| `supervise/run` | Daemontools run script (200 MB softlimit, rosterbot user) |

## Runtime Configuration

- Discord token: `/home/users/rosterbot/.passwd` (DISCORD_TOKEN= format)
- Database: `/home/users/rosterbot/sql/rosterbot.db`
- Discord API v10; intents: GUILDS, GUILD_MEMBERS, GUILD_BANS, GUILD_MESSAGES, DIRECT_MESSAGES

## Key Behavior

- DM rate limits: 2/minute, 8/10 minutes, 30/hour; rate-limited sends are queued and retried (not dropped) after the next bucket opens (62s/602s/3602s with jitter buffer)
- Scammer warning: sent once on join (timestamp recorded immediately to prevent multi-guild duplicates); resent every 24 hours until ACKed
- Contact request: sent after scammer ACK + role grant; resent every 7 days (604800s); 30s stagger between bulk sends
- Two-stage user flow: scammer ACK (user types exact phrase) → admin grants role in Discord server → contact request sent
- Approval: triggered by role grant (GUILD_MEMBER_UPDATE role diff) or Discord Membership Screening (pending→false); offline role grants detected on GUILD_MEMBERS_CHUNK startup
- Contact statuses: `pending`, `contacted`, `provided`, `stopped` (STOP command opt-out), `banned`
- Approval statuses: `pending`, `approved` — set to `approved` on role grant or screening approval; reset to `pending` on rejoin
- Scammer ACK: user must type exact phrase; sets `scammer_ack=1`; notifies admins; does NOT approve user
- ROLE GRANTED admin notice warns if user has not yet ACKed the scammer message
- Non-command DMs from known members are relayed to admins
- Significant events (joins, departures, role changes, contact updates) notify admins via DM
- Runtime-only notify_only override: `admin notify_only <username>` redirects all admin DMs to one admin; `admin notify_only --reset` restores config value; not persistent across restarts

## Discord Gateway Events

READY, GUILD_CREATE, GUILD_DELETE, GUILD_MEMBERS_CHUNK, GUILD_MEMBER_ADD,
GUILD_MEMBER_REMOVE, GUILD_MEMBER_UPDATE, GUILD_BAN_ADD, GUILD_BAN_REMOVE,
MESSAGE_CREATE; control: HELLO,
HEARTBEAT_ACK, INVALID_SESSION, RECONNECT
