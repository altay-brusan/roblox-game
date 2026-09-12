# Architecture

Where everything lives and how the pieces connect.

---

## Explorer placement

This is exactly what you will see after opening the built place.

```
game
├── ReplicatedStorage
│   └── LastSignal                        (Folder)
│       ├── Config                        (Folder)
│       │   ├── GameConfig                place topology, crew rules, pacing, difficulty
│       │   ├── Balance                   every tuning number in the game
│       │   ├── Monetization              products and their IDs
│       │   ├── Admin                     roles, capabilities, safety limits
│       │   └── Audio                     cue definitions, buses, ducking rules
│       ├── Core                          (Folder)
│       │   ├── Signal, Maid, Spring      events, lifecycle, motion
│       │   ├── Net                       the remote manifest and boundary
│       │   ├── Guard                     payload validation
│       │   ├── Protect                   typed pcall
│       │   ├── TableUtil, Format, Logger utilities
│       │   └── RateLimiter               token bucket
│       ├── Registry                      (Folder)
│       │   ├── ItemRegistry              23 items
│       │   ├── WeaponRegistry            7 weapons
│       │   ├── TrainRegistry             4 trains, 10 liveries, 5 interiors
│       │   ├── StationRegistry           5 stations, 4 travel events
│       │   ├── RadioScript               22 beats, 8 recordings
│       │   ├── QuestRegistry             12 daily, 6 weekly, 5 milestones
│       │   ├── CosmeticRegistry          24 cosmetics
│       │   └── EventRegistry             The Lost Conductor
│       └── Remotes                       (Folder, created at boot)
│
├── ServerScriptService
│   └── LastSignalServer                  (Script — the boot sequence)
│       ├── Services                      (20 ModuleScripts)
│       └── World                         (6 ModuleScripts)
│
├── StarterPlayer
│   └── StarterPlayerScripts
│       └── LastSignalClient              (LocalScript — the client boot)
│           ├── Controllers               (10 ModuleScripts)
│           └── UI                        Theme, Widgets
│
├── ReplicatedFirst
│   └── LoadingScreen                     (LocalScript)
│
├── ServerStorage                         (empty; nothing needs to hide here)
│
└── Workspace
    └── LastSignalWorld                   (Folder, created at runtime)
        ├── Lobby
        ├── Lane1                         Track, Stations, Forest, Drops, Creatures, Trains
        └── Lane2
```

Nothing is stored in Workspace in the saved file. The world is constructed at
runtime by the builders, which is why the place file is a megabyte rather than
a hundred, and why changing the world means changing a builder rather than
dragging parts.

---

## Server services, and what each owns

Started in this order by `init.server.luau`. The order is a dependency order.

| Stage | Service | Owns |
| --- | --- | --- |
| Data | `DataService` | Profile load, session locks, autosave, shutdown flush |
| | `ProfileSchema` | The save shape and the migration chain |
| Economy | `ProgressionService` | Credits, XP, levels, stats, achievements. The only place anything is awarded |
| | `RewardService` | Daily login, playtime |
| | `QuestService` | Daily, weekly and milestone quests. Owns the shared reward remote |
| | `PurchaseService` | Every MarketplaceService call, and ProcessReceipt |
| | `ShopService` | Catalogue assembly, credit purchases, prompt gating |
| | `InventoryService` | Per-expedition inventories, weight, transfer, the crew supply rack |
| World | `WorldService` | The lobby, the expedition lanes, lane claiming and reset, dropped item construction |
| Session | `CrewService` | Crews, readiness, leadership, the departure countdown |
| | `TrainService` | Train simulation, cab controls, lights, doors, resources |
| | `ExpeditionService` | The state machine, objectives, radio beats, results, teardown |
| Gameplay | `SurvivalService` | Health, stamina, lamp, downed, revive, spectate |
| | `InteractionService` | Every proximity interaction and held action |
| | `CreatureService` | The Signal-Eater: body, senses, behaviour |
| | `CombatService` | Weapons, server-side shot validation |
| | `HorrorDirector` | Threat, event scheduling, scripted beats |
| Live | `EventService` | Live events and The Lost Conductor |
| | `AdminService` | Commands and authorisation |
| | `AnalyticsService` | Funnel counters and derived rates |
| | `LeaderboardService` | Four OrderedDataStore boards |

A service that fails to start is logged by name and boot continues. A broken
leaderboard must not stop the game running.

---

## Client controllers

| Controller | Owns |
| --- | --- |
| `StateController` | The single copy of all replicated state. Nothing else binds a state remote |
| `InputController` | Action bindings for keyboard, gamepad and touch, and the touch layout |
| `CameraController` | Five camera modes through one apply function, plus a watchdog |
| `AudioController` | Buses, cues, ducking, enclosure, subtitles, directional indicators |
| `HUDController` | Vitals, objective, train gauges, quick slots, ammunition, notifications |
| `InteractionController` | Prompt appearance and the hold bar |
| `MenuController` | All eleven panels, and the one-panel-at-a-time rule |
| `CinematicController` | The opening sequence, the skip vote, and four exit paths |
| `WeaponController` | Viewmodels, firing input, local effects |
| `TrainRideController` | Keeping the player with the moving train |

---

## The rules that keep it coherent

**One place for each thing.** One award function. One purchase handler. One
camera apply. One open panel. One replicated store. Where a system could have
been split across two files, it was not, because the bugs live in the gap.

**The server decides, the client asks.** Every remote handler validates through
`Guard`, is rate limited by `Net`, and is wrapped in a pcall. The client sends
intent and never an outcome. Local effects exist for responsiveness and decide
nothing.

**State flows one way.** Server state changes, server pushes, `StateController`
stores, controllers react. A controller that wants a change sends a command and
waits for the state to come back.

**Registries are data.** Items, weapons, trains, stations, quests, cosmetics
and events are tables. Adding content means adding a table entry, not writing a
system. The registries are frozen at load so one system cannot mutate
definitions another system is reading.

**Failure is explicit.** Every function that can fail returns a reason. Nothing
returns a bare boolean where the caller needs to know why, and nothing silently
swallows an error that the operator should see.

---

## How a single expedition flows

1. `CrewService` counts down and fires `CrewDeparted`.
2. `ExpeditionService.begin` claims a lane from `WorldService`, reporting
   build progress to the crew so nobody watches a frozen screen.
3. `TrainService.spawn` builds the train from the leader's train, livery and
   interior choices.
4. Inventories are created, starting kit granted, players placed in the
   carriage, and the cinematic starts for the whole crew at once.
5. The cinematic ends, by its timer or by a crew skip vote. The train is
   released with a stop distance set to station one.
6. `TrainService` integrates movement on a 20 Hz tick and writes the root
   CFrame. Clients apply the delta to their own characters.
7. Arriving at the stop distance fires `ArrivedAt`; `ExpeditionService` matches
   the distance to a station and initialises its objectives.
8. `InteractionService` handles the objective fixtures.
   `HorrorDirector` raises threat from noise and schedules events against it.
   `CreatureService` hunts by hearing first.
9. Every required objective complete releases the train to the next station.
10. The final station completes, the ending fires, results are shown for
    eighteen seconds, then `close` returns everybody to the yard, tears down
    the train, releases the lane and closes the crew.

Every step of that has an explicit failure path, and they all converge on the
same teardown so a lane can never be leaked.

---

## Adding things

**A new item.** Add a table to `ItemRegistry`. It will appear in loot at its
tier, be carryable, droppable, transferable and usable. If it needs a new
effect, add one branch to `SurvivalService`'s `ItemUsed` handler.

**A new weapon.** Add a table to `WeaponRegistry`, including its `viewmodel`
and `model` blocks. Validation, reloading, noise and balance all follow from
the table.

**A new horror event.** Add a table to `HorrorDirector`'s `EVENTS` with a
`minBand`, a `cooldown`, an optional `requires`, and a `run` function. Nothing
else changes.

**A new station.** Add a table to `StationRegistry` with its layout, fixtures,
loot nodes and objectives. `StationBuilder` builds it from the `kind` strings;
add a branch there only if you need a building shape that does not exist yet.

**A new live event.** Add a table to `EventRegistry`. `EventService` runs
whatever it finds. See [EVENTS.md](EVENTS.md).
