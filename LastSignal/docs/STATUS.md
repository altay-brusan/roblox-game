# Implementation and verification status

This is the document to trust. It states what has been built, what has been
verified and by what method, and what has not been run at all.

Last updated against commit history in this repository.

---

## The headline

**Everything in this project has been verified statically. Nothing has been
verified by running it.**

Roblox Studio is not installed on the machine this was built on, and there is
no way to execute Luau against a live Roblox DataModel without it. Static
analysis against the real Roblox API catches a large class of errors: every
misspelled property, every wrong argument type, every call to a method that
does not exist, every unreachable branch the type system can see. It does not
catch logic that is wrong but well-typed, timing problems, physics behaviour,
or anything about how the game feels.

Treat every "Built" row below as "written, type-checked, and not yet run".

---

## What was actually verified, and how

| Check | Tool | Result |
| --- | --- | --- |
| Every file parses and compiles | `luau-compile` 0.738 | 64 of 64 files pass |
| Every file type-checks in strict mode against the real Roblox API | `luau-lsp analyze` 1.69.0 with `globalTypes.d.luau` | 0 errors |
| Cross-module `require` resolution | Rojo sourcemap fed to the analyzer | All resolve |
| The place file assembles | `rojo build` 7.7.0 | `build/LastSignal.rbxlx`, 1,015 KB |

These four checks are reproducible with `bash scripts/check.sh` and
`bash scripts/build.sh`.

The type check is not a formality. It was run after every module and it found
real defects during development, including wrong property names, mismatched
table shapes across module boundaries, and several places where a value that
could be `nil` was used as though it could not. All were fixed rather than
suppressed. There are no analyzer suppressions anywhere in this project.

---

## What was not verified

Nothing below has been executed even once.

- The game has never been launched.
- No expedition has been played, solo or in a crew.
- No multiplayer session has been run.
- No performance measurement has been taken on any device.
- No mobile or tablet layout has been seen on a real screen.
- No DataStore read or write has happened.
- No purchase has been attempted, in Studio or live.
- Nothing has been published.

Several systems are the kind that usually need a round of live tuning before
they are right. The ones most likely to need adjustment on first play, in the
order I would check them:

1. **Train and passenger interaction.** The reference-frame ride approach is
   sound and is the correct solution for a kinematic train, but the hysteresis
   margins and the falling-clear check are numbers chosen by reasoning, not by
   watching a player jump out of a moving door.
2. **Creature pacing.** Hearing radius, chase duration and the threat curve
   are the numbers most likely to be wrong in a way that only play reveals.
3. **World build time.** A lane is 14,000 studs of track, forest and five
   stations. It is built incrementally with yields so it cannot stall the
   server, but how many seconds it actually takes is unmeasured.
4. **Interface layout at phone width.** Every widget is scale-aware and
   respects the safe area by construction, and nothing uses a fixed pixel size
   for text, but no phone has rendered it.

---

## Feature status

### Core framework

| Feature | Status | Notes |
| --- | --- | --- |
| Signal, Maid, Spring, TableUtil, Format, Logger, Protect | Built | Pure Lua, the most likely parts of this project to be correct |
| Rate limiting | Built | Token bucket, per player, per remote |
| Remote manifest and network boundary | Built | 40 declared remotes, every server handler rate-limited and wrapped |
| Payload validation | Built | `Guard` validates every server-bound argument; no handler trusts a raw value |

### Data and persistence

| Feature | Status | Notes |
| --- | --- | --- |
| Profile schema | Built | Versioned, with a full template |
| Session locking | Built | Job ID plus heartbeat, with stale takeover |
| Migrations | Built | v1 to v2 and v2 to v3 written; a failing migration refuses to save rather than corrupting |
| Never overwrite progress with defaults | Built | Every failure path produces a read-only session, visibly flagged to the player |
| Autosave, leave-save, BindToClose | Built | Staggered by user ID; shutdown waits on real completion, not a fixed sleep |
| Studio mock store | Built | Live player data is never touched from Studio |

The reasoning here is careful and the failure paths are all explicitly handled.
It is also the system where a subtle bug is most expensive, and it has not been
run against a real DataStore.

### World

| Feature | Status | Notes |
| --- | --- | --- |
| Lobby yard | Built | Workshop with inspection pit and gantry crane, covered shelter with benches, stores hut, water column, three roads, buffer stops, yard lighting, perimeter fence, clutter |
| Locomotive | Built | Bogies with leaf springs, axleboxes and brake shoes; underframe and solebars with rivet strips; louvres, radiator grilles, exhaust stacks, roof fans; buffer beams with buffers, drawhook, three-link chain and air pipes; four nose profiles |
| Cab interior | Built | Sloped desk, throttle and brake levers with quadrants, emergency handle under a guard, reverser, horn, four switches, three needle gauges with tick marks, radio set, driver and mate seats, wiper arms |
| Carriages | Built | Real windows aligned inside and out, facing seat bays with tables, luggage racks, gangway connections with concertina shrouds and walk plates, pendant lighting, supply racks, workshop fittings |
| Forest | Built | Six tree archetypes, four variants each, jittered rejection sampling with soft clearing edges, undergrowth, deadfall, rocks, stumps |
| Five stations | Built | Every building marked `interior` gets a real enterable inside with segmented walls around genuine openings |
| Signal tower, lift bridge, lattice mast, timber loader, gantry | Built | Each purpose-built rather than a reskinned box |

Part counts per lane are estimated in [PERFORMANCE.md](PERFORMANCE.md) and have
not been measured.

### Gameplay

| Feature | Status | Notes |
| --- | --- | --- |
| Crews: create, join, ready, leader transfer, kick, countdown | Built | Every stranding case handled explicitly, including a member joining mid-countdown |
| Expedition state machine | Built | Seven states, one-way transitions |
| Five stations with five different objective shapes | Built | Sequence, simultaneous, relay, timed defend, converge |
| Train driving | Built | Eight notches, service and emergency brakes, reverser, doors, lights, wipers, horn, fuel, condition, needle gauges |
| Passenger ride | Built | Client-side reference frame; see the caveat above |
| Inventory | Built | Slots and weight, server-validated transfer, drop, use; essential items store in the train rather than being destroyed |
| Combat | Built | Four firearms with mechanism-accurate reloads, three melee weapons, full server validation of every shot |
| The Signal-Eater | Built | Four-state AI, hearing before sight, cannot be killed, four independent counterplays |
| Horror director | Built | Nine event types, threat bands, cooldowns, repetition control, hard rails against firing during loading, cinematics and respawn immunity |
| Downed, revive, bleedout, spectate | Built | Free teammate revive always available; paid self-revive narrowly gated |
| Radio story with the false-transmission device | Built | Twenty-two beats, eight recordings, four consistent tells that separate the dispatcher from what imitates him |

### Progression and live operations

| Feature | Status | Notes |
| --- | --- | --- |
| Credits, XP, levels, statistics | Built | One `award` entry point, so multipliers cannot be applied twice or missed |
| 15 achievements | Built | Driven by statistics, checked on every stat change |
| Daily and weekly quests | Built | Deterministic daily set so a whole server shares objectives |
| Daily login with forgiving streaks | Built | A missed day steps back one; nothing is ever taken away and no product protects a streak |
| Playtime rewards | Built | Capped per day so idling is not a strategy |
| Four leaderboards | Built | Nothing purchasable is ranked |
| The Lost Conductor event | Built | Complete: encounter, token, four-tier reward ladder, idempotent claims, grace period after expiry |
| Shop | Built | Live prices from MarketplaceService, ownership state, prompt gating during cinematics and encounters |
| Purchases | Built | Duplicate-safe ProcessReceipt that records before granting and defers rather than acknowledging on any failure |
| Administration | Built | 16 commands, capability matrix, confirmation on destructive commands, filtered announcements, audit log |
| Analytics | Built | Funnel counters and six derived rates, each defined as a ratio of two measured values |

### Interface

| Feature | Status | Notes |
| --- | --- | --- |
| Design system | Built | One palette, one type scale, platform-aware spacing, high-contrast variant |
| Widgets | Built | Text always wraps or truncates deliberately; touch targets clamped to platform minimum; no image assets anywhere |
| HUD | Built | Vitals, corner objective capped at two lines, train gauges, quick slots, ammunition, crew strip |
| Eleven panels | Built | Crew, loadout, inventory, shop, quests, rewards, achievements, leaderboard, settings, event, results, admin |
| Touch layout | Built | Thumb-placed clusters plus a tray; no drag-and-drop anywhere in the project |
| Camera | Built | Five modes through one apply function, plus a one-second watchdog that corrects the camera if anything leaves it wrong |
| Cinematic | Built | Eight camera keyframes, twelve text beats, crew skip vote, four independent exit paths all ending at one function |
| Accessibility | Built | Subtitles, directional sound indicators, reduced motion, reduced flashing, high contrast, eight separate volume buses, camera shake scaling |

---

## Known limitations

**Single-place mode caps concurrent expeditions.** Two lanes per server, set by
`GameConfig.MaxConcurrentExpeditions`. A third crew is told plainly that the
line is occupied rather than being left waiting. Two-place mode removes the cap
entirely and every teleport path for it is written, but it cannot be exercised
until both places are published. See [PUBLISHING.md](PUBLISHING.md).

**No third-party art or audio.** Everything is built from Roblox primitives at
runtime. That is a deliberate constraint, not an oversight: this project cannot
license, verify or attribute assets on your behalf, and shipping unlicensed
meshes is exactly what the brief forbids. The trade-off is that the world reads
as detailed constructed geometry rather than sculpted meshes.
[ASSETS.md](ASSETS.md) explains where to drop real meshes in later without
touching gameplay code.

**No character animations.** Roblox animations are asset IDs, with the same
licensing and upload constraints as audio. Weapons have a full first-person
viewmodel with hands, springs and recoil; what is missing is third-person
character animation for other players holding weapons. They will hold them in
the default Roblox pose.

**The run length is a target, not a measurement.** Twenty-five to forty minutes
is what the station pacing and travel distances were designed around. It has
not been timed.

---

## What I would do first, with Studio open

1. Run `scripts/check.sh` to confirm nothing regressed, then open
   `build/LastSignal.rbxlx` and press Play. Read the boot log in the F9
   console; it reports every service, and the configuration report tells you
   what is switched off.
2. Walk the yard. Confirm the geometry is where it should be and the lighting
   reads at night.
3. Depart alone. Watch the cinematic, skip it, confirm control returns.
4. Ride the train and walk around inside it while it moves. This is the single
   highest-risk behaviour in the project.
5. Clear Marrow Halt. Confirm the power sequence, the loot, and the objective
   panel.
6. Then work through [TESTING.md](TESTING.md), which lists every acceptance
   case the brief asks for.
