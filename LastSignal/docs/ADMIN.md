# Administration

Roles, commands, and the rails that stop a command doing damage.

---

## Turning it on

**File:** `src/shared/Config/Admin.luau`

```lua
Admin.Roles = {
    {
        userId = 0,                        -- <-- RIPjafar1's numeric user ID
        username = "RIPjafar1",
        role = "owner",
    },
    {
        userId = 0,                        -- <-- shayanbrusan1234's numeric user ID
        username = "shayanbrusan1234",
        role = "admin",
    },
}
```

Find a numeric user ID by opening the profile in a browser. The URL is
`roblox.com/users/`**`1234567`**`/profile`; the number is the ID.

**Until you fill these in, nobody has administrative access.** That is
intentional. This project cannot verify which account a given username
currently belongs to, Roblox usernames can be changed, and a wrong guess would
hand the owner role to a stranger. A role with `userId = 0` is inert.

The boot log tells you the state every time the server starts:

```
[LAST SIGNAL][Boot] Administration: no user IDs configured. Nobody has admin access.
```

---

## How authorisation actually works

Every command resolves the caller's role from `Player.UserId`, on the server,
on every single call.

Nothing trusts a client flag, a username string, a display name, or a session
token issued earlier. The client is told its own role so it can show or hide
the Control panel, but that is cosmetic: a client that lies about its role gets
a panel it cannot use, because every command is re-authorised server-side
before it runs.

Display names are never used for anything but display. A display name can be
set to almost anything, including another player's name.

An unknown capability is denied rather than allowed. A typo in a command
definition switches that command off; it does not open it to everybody.

---

## Roles

| Role | Rank | Intended for |
| --- | ---: | --- |
| `owner` | 40 | RIPjafar1. Everything, including destructive resets. |
| `admin` | 30 | shayanbrusan1234. Everything except resets. |
| `moderator` | 20 | Announcements, kicks, player inspection. |
| `tester` | 10 | Self-teleport only. |
| `player` | 0 | The default. No access. |

A moderator or admin cannot kick somebody of equal or higher rank.

---

## Using the console

Open the menu (**M**), then **Control**. Type a command and press Enter or the
Run button. Arguments are separated by spaces; numeric arguments are converted
automatically.

The panel lists every command your role can use, with its usage line.

---

## Commands

| Command | Capability | Usage |
| --- | --- | --- |
| `help` | tester | `help` |
| `tp` | tester | `tp lobby` / `tp train` / `tp station 3` |
| `inspect` | moderator | `inspect <player>` |
| `announce` | moderator | `announce <message>` |
| `kick` | moderator | `kick <player> <reason>` |
| `bring` | admin | `bring <player>` |
| `credits` | admin | `credits <player> <amount>` |
| `xp` | admin | `xp <player> <amount>` |
| `item` | admin | `item <player> <itemId> [quantity]` |
| `unlock` | admin | `unlock <player> <kind> <id>` |
| `godmode` | admin | `godmode <player>` |
| `threat` | admin | `threat <amount>` |
| `station` | admin | `station <index>` |
| `event` | admin | `event start\|stop\|status [id] [hours]` |
| `world` | admin | `world` |
| `resetplayer` | **owner** | `resetplayer <player>` |
| `resetme` | **owner** | `resetme` |

Player arguments accept a full username, a display name, a numeric user ID, or
a unique prefix of a username.

### Notes on the less obvious ones

**`inspect`** reports level, XP, credits, session count, whether the profile is
writable and why not, current expedition and station, vitals, role, and total
Robux spent. It is the first thing to run on any bug report.

**`world`** reports lane state (built, claimed, part count), every active
expedition with its threat level, the data layer's status, and the build ID.
Run it when the server feels wrong.

**`threat`** adds to your own expedition's threat meter. Useful for forcing the
horror director to escalate during testing without waiting.

**`station`** completes every outstanding objective at your current station,
which advances the expedition through its normal path rather than teleporting
past it. Use it to reach a later station quickly for testing.

**`item`** only works on a player who is on an expedition, because inventories
are per-expedition and do not exist in the lobby.

---

## Destructive commands

`resetplayer` and `resetme` require confirmation. Run the command once; it
returns a message telling you to run exactly the same command again within 30
seconds. The second identical call executes it.

**Resets preserve purchase records.** Credits, XP, levels, unlocks, quests,
achievements and statistics are wiped. `purchases.receipts`,
`purchases.products` and `purchases.robuxSpent` are carried across untouched,
and the entitlements those purchases grant are re-applied. Somebody who spent
Robux keeps what they paid for regardless of what else is reset.

A reset only works on a writable session. If the target's profile is
read-only, the command refuses rather than pretending to succeed.

There is no command that resets every player at once. `reset_all_data` exists
in the capability matrix as a reserved name; no command implements it. Wiping a
whole player base is not something that should be one typo away.

---

## Announcements

`announce` passes the message through `TextService:FilterStringAsync` before
broadcasting. If filtering fails for any reason, the announcement is suppressed
rather than sent unfiltered.

---

## The audit log

Every command attempt is recorded with the time, the caller's user ID and name,
the command, its arguments, and the result, including denials. The log is
capped at 250 entries so a long-running server cannot grow without bound, and
every entry is also written to the server output where it appears in the live
server logs.

Denied attempts are logged. If somebody is probing for access, it will show up.
