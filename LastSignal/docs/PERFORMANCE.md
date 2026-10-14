# Performance

Budgets, estimates, and what has actually been measured.

---

## Measured

| Metric | Value | How |
| --- | ---: | --- |
| Place file size | 1,015 KB | `rojo build` output |
| Luau source | 65 files, ~33,400 lines | `wc -l` over `src/` |
| Parts in one expedition lane | 32,000+ | **Measured by the operator** from the server log on a real run |

**Everything else on this page is an estimate**, derived from counting the
parts each builder creates. The lane figure above is the exception: it is a
real number from a real server run, and it came in at roughly half my estimate
of 60,000. See [STATUS.md](STATUS.md).

Record real numbers here once you have them.

---

## Estimated part counts

| Object | Estimate |
| --- | ---: |
| Locomotive, including cab interior | 350 to 450 |
| Passenger carriage | 250 to 350 |
| A two-carriage consist (Warden) | ~1,000 |
| One tree | 9 to 16 |
| Forest, per 1,000 studs of corridor | ~2,500 |
| Full forest, one lane | ~35,000 |
| Track, one lane | ~9,000 |
| One station | 2,000 to 5,000 |
| Five stations | ~16,000 |
| **One complete lane** | **~60,000** |
| Lobby | ~4,000 |

Two lanes plus the lobby is therefore in the region of 125,000 parts. That is a
lot, and it is why `MaxConcurrentExpeditions` defaults to 2 rather than 4.

If the server struggles, reduce in this order:

1. `GameConfig.MaxConcurrentExpeditions` to 1. Halves everything.
2. `GameConfig.ForestDensity` from 3.5 to 2.5. Removes roughly a third of the
   forest, which is the single largest consumer.
3. `GameConfig.ForestCorridorHalfWidth` from 280 to 220. The fog ends at 460
   studs, so trees beyond the corridor are rarely visible anyway.
4. `TrainRegistry` `detailLevel` per train, from 3 to 2.

---

## What keeps it affordable

**Streaming is on.** `StreamingEnabled` with a 192 stud minimum and a 640 stud
target. A client only ever holds the part of the world it is near, which is why
a 14,000 stud corridor is viable at all. Lanes are 9,000 studs apart in X
specifically so streaming never loads two at once.

**Almost nothing is collidable.** Every decorative part goes through
`BuildKit.detail`, which sets `CanCollide = false`, `CanQuery = false` and
`CastShadow = false`. Only floors, walls, platforms and tree bases collide.
Rivets, pipes, handrail posts, foliage and trim cost nothing for physics or
raycasts.

**Nothing scenic has touch events.** Every part built by `BuildKit` has
`CanTouch = false`. Touch events on scenery are the largest avoidable server
cost in Roblox, and this project has none.

**Repeated geometry is cloned.** Sleepers are one template cloned four thousand
times. Trees are four variants per archetype, cloned and then jittered in
colour and rotation, which is what makes the forest look varied without paying
to build each tree individually.

**The train is one assembly.** A thousand parts welded to one anchored root.
Moving it is one CFrame write per tick, not a thousand.

**Fixed tick rates.** Train at 20 Hz, creatures at 10 Hz, survival at 8 Hz, the
director at 1 Hz. Nothing gameplay-authoritative runs per frame, so server CPU
is predictable with six players, two creatures and a moving train.

**Lanes are reused, not rebuilt.** Between expeditions a lane is reset: loot
nodes reopened, lights off, doors closed, fixtures returned to idle, spawned
objects cleared. Rebuilding a forest takes seconds; resetting takes
milliseconds.

**Lights are bounded.** `GameConfig.MaxActiveLights` is 26. Station lights
start disabled and only come on when a station is powered, which means most of
the world's lights are off most of the time.

---

## Client cost

The heaviest client work is:

- **The viewmodel**, one render step binding that positions a welded model.
- **The camera**, one render step binding with five springs.
- **The train ride**, one `Stepped` binding doing a bounding box test and one
  CFrame multiply.

None of those iterate over the world. The HUD updates on state change rather
than per frame, except the bleedout clock which ticks at 10 Hz while downed.

---

## What to measure first

1. **Time to build lane one.** It is built in the background at boot with
   yields between phases, so it cannot stall the server, but the wall clock
   matters: a crew departing in the first minute waits for it.
2. **Server frame time with two expeditions running.** Run `world` from the
   admin console to see lane and expedition state.
3. **Client frame rate at a station with a crew of six**, which is the worst
   case for lights, players and loot in view at once.
4. **Memory after five expeditions have started and ended.** This is the test
   that proves the lane reset frees what it should. If memory climbs run over
   run, something is being retained.

---

## Measurements, 2026-10-14 (Studio play test)

Environment: Roblox Studio 0.742 on the development Windows 11 machine, one
local player, Studio graphics defaults. **Client frame rate could not be
measured**: Studio throttles an unfocused viewport to a flat 15 fps (66.7 ms)
whatever the scene, and the test harness cannot keep it focused. No phone,
tablet or console has been tested.

| Measure | Before | After |
| --- | --- | --- |
| Expedition line geometry (excl. train) | 33,521 parts | 28,021 parts |
| Forest | 25,937 | 20,437 |
| Sleepers | 4,493 (collidable) | 4,493 (not collidable) |
| Collidable parts on a line | 7,734 | 3,071 |
| Line build time (server) | 0.7 s | 0.7 s |
| Lobby | 3,460 parts | 4,125 parts (Platform 1, tunnel, live yard train added) |
| Train | 1,479 parts | unchanged |
| Server heartbeat work / physics step | 0.20 ms / 0.30 ms at 60 Hz with a 39k-part workspace | — |
| Client parts streamed in at the line start | 10,179 | — |

What changed:

* Trees more than 100 studs from the track are built without root flares and
  dead branches (the parts nobody walks close enough to see); silhouettes are
  unchanged. The yard forest keeps full detail.
* Sleepers no longer collide; the ballast under them is the walking surface.

Repeated runs: two expeditions in one session left one expedition train, one
yard train and one prompt per fixture; a crew wipe and retry left every audio
loop playing once and cleared creatures and drops.

Untested: real device frame rates, memory on mobile, multiplayer replication
load, two simultaneous expeditions.
