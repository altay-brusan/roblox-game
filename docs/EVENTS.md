# Live events

Running The Lost Conductor, and writing the next one.

---

## The Lost Conductor

Ships complete and dormant. It is fully built; it simply has no schedule.

**The premise.** Punched tickets have started appearing along the line, for a
sleeper service that was cancelled before it ever left the yard. Somebody is
still walking the train checking them.

**The token.** Punched Tickets spawn three per station, scattered around the
clearing with a faint glow, because a paper ticket on a forest floor at night
is otherwise genuinely invisible and that is not a fun hunt.

**The encounter.** The Conductor appears during travel, never on a station stop
and never during the cinematic. He walks the length of the consist from the
rear to the cab at a fixed, unhurried pace. He cannot be stopped and he does no
damage.

If he reaches a player holding a ticket, it is punched and consumed, and he
moves on. If he reaches a player holding none, their lamp goes out and stays
out until the next station. The penalty is inconvenience, never damage: an
event encounter that can kill you turns a limited cosmetic into a tax.

He can be avoided completely by being in a different carriage.

**The ladder.**

| Tickets | Reward |
| ---: | --- |
| 5 | 400 credits, 300 XP |
| 15 | 900 credits, 700 XP, the Lost Conductor patch |
| 30 | 1,600 credits, 1,200 XP, the Sleeper lamp |
| 50 | 2,600 credits, 2,000 XP, the Sleeper Maroon livery |

Nothing in the ladder can be bought. There is no way to convert Robux into
tickets, deliberately.

---

## Running it

From the Control panel, as an administrator:

```
event start lost_conductor 168        # start it, for 168 hours (one week)
event status                          # what is live, and until when
event stop lost_conductor             # stop new progress
```

`event start` announces it to everybody on the server and pushes the event
panel to their menu.

`event stop` stops new tokens being earned. It does not remove tokens already
collected or rewards already claimed, and earned rewards stay claimable for the
grace period, which is seven days.

You can also set the window permanently in
`src/shared/Registry/EventRegistry.luau` by giving `startsAt` and `endsAt` real
Unix timestamps. The admin command overrides whatever is in the file, at
runtime, per server.

---

## The four safety properties

These are the parts that go wrong in live events, and what is done about each.

**Claims are idempotent.** A reward threshold is marked claimed inside the same
profile update that checks whether it was already claimed. A double click, a
reconnect, or two servers racing cannot grant the same threshold twice.

**Nothing is ever removed.** Ending an event stops new progress. Tokens already
collected stay on the profile. Rewards already claimed stay granted. Cosmetics
awarded remain owned forever, including after the event is long gone.

**Expiry has a grace period.** After the window closes, earned rewards remain
claimable for seven days. An expedition that runs past the deadline does not
cost anybody what they earned during it.

**Stopping early is safe.** An administrator stopping an event sets its end to
now, which leaves the grace period intact. Nothing is settled destructively.

---

## Writing the next event

The design goal is that an event is data, not code.

Add a table to `EventRegistry.Events`:

```lua
my_event = {
    id = "my_event",
    name = "The Something",
    tagline = "One line that makes somebody want to read the next one.",
    description = "A paragraph of what is happening and what to do.",

    startsAt = 0,                 -- 0 means dormant; set by the admin command
    endsAt = 0,
    claimGraceSeconds = 7 * 86400,

    tokenItem = "conductor_ticket",   -- an ItemRegistry id
    tokenName = "Punched Ticket",
    tokensPerStation = 3,
    encounterChance = 0.45,

    encounter = {
        id = "the_thing",
        name = "The Thing",
        description = "What it does.",
        behaviour = "patrol_inspector",
        params = { speed = 6, dealsDamage = false },
    },

    rewards = {
        { threshold = 5,  credits = 400, xp = 300, title = "First", description = "..." },
        { threshold = 15, credits = 900, xp = 700, cosmetic = "patch_x", title = "Second", description = "..." },
    },

    minLevel = 0,
}
```

`EventService` reads all of that. Token spawning, the reward ladder, the claim
logic, the panel and the grace period all work with no further code.

The one thing that is code is the encounter behaviour. `patrol_inspector` is
implemented; a genuinely new kind of encounter means adding a function to
`EventService` and a branch that dispatches on `behaviour`. That is a
deliberate line: reward ladders should be data, and creatures should be
written.

**Constraints worth keeping.** Do not make an event encounter lethal. Do not
sell the token. Do not gate a limited cosmetic behind a level requirement,
which punishes new players for arriving during the event. Do not run two events
at once; overlapping token economies make the reward panel unreadable, and
`EventRegistry.activeEvent` deliberately returns only one.
