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
- **Validation**: Mail::VRFY (email), regex/E.164 digit-count (phone)
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
- Discord API v10; intents: GUILDS, GUILD_MEMBERS, GUILD_MESSAGES, DIRECT_MESSAGES

## Key Behavior

- Contact requests are rate-limited to 30/hour, re-sent after 7-day interval (30s stagger between sends)
- Contact statuses: `pending`, `contacted`, `provided`, `stopped` (STOP command opt-out)
- DM blocking (Discord errors 50007, 340002, 20026) triggers 24-hour backoff
- Non-command DMs from known members are relayed to admins
- Significant events (joins, departures, contact updates) notify admins via DM
- Default admin user ID: `1388031297036750958` (jkister), seeded in SQL

## Discord Gateway Events

READY, GUILD_CREATE, GUILD_DELETE, GUILD_MEMBERS_CHUNK, GUILD_MEMBER_ADD,
GUILD_MEMBER_REMOVE, GUILD_MEMBER_UPDATE, MESSAGE_CREATE; control: HELLO,
HEARTBEAT_ACK, INVALID_SESSION, RECONNECT
