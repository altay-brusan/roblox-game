# Last Signal: delivery report (V2 §20–21)

Date: 2026-10-14. Branch `boarding-journey`. This is the document to trust;
it replaces the old STATUS.md and CHECKLIST.md, which were written before the
game could be played.

**Verdict: playable end to end, not a finished game.** The story can be
played from the lobby through all eight stations to the ending with free
equipment, and the Endless Railway opens after it. It is not ready to publish:
no Game Pass or product exists on Roblox yet, 22 of 91 audio cues have no
sound, there are no recorded voices, and nothing has been tested with more
than one player.

---

## 1. The file

* **Saved place:** `LastSignal/build/LastSignal.rbxlx`, built by
  `bash LastSignal/scripts/build.sh` from `LastSignal/src` at the commit that
  carries this report.
* **What was tested:** that file, open in Roblox Studio (place name
  `LastSignal.rbxlx`), with scripts kept equal to the same sources by the dev
  sync tool. The dev harness (`ReplicatedStorage.DevHarness`) is a Studio-only
  addition and is not in the built file.
* **Not done:** closing Studio, reopening the freshly built file and repeating
  the full run from it. Smallest action: open `build/LastSignal.rbxlx`, press
  Play, depart solo from the crew panel (M), and play to Marrow Halt.

## 2. How the tests were run, and what they mean

All play testing used Studio Play with one local player, driven by a harness
that calls the same remotes the UI calls and performs every objective through
the real interaction (prompt, hold, carry, deliver). The harness **teleports
the player to each fixture** instead of walking, and teleports them aboard the
yard train. Objectives were never forced complete and no success handler was
called directly. Rows marked *dev-assisted* used a Studio-only hook (listed
in section 9) and are not player tests.

## 3. Acceptance run (V2 §20), this session

| # | Check | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Fresh session, safe spawn | Pass | spawned in the yard at full health; mock profile created; boot log clean |
| 2 | Introduction, then normal camera and controls | Pass | prologue played; `cinematic finished; control restored`; camera first person, mouse locked |
| 3 | Lobby: mission start and train guidance | Pass (earlier tasks) | crew board, Platform 1 signage, yard train with open doors (tasks 1, 2, 6) |
| 4 | Start the mission through its real interaction | Pass | crew panel opened with M; solo departure |
| 5 | Platform, board, departure, travel, arrival | Pass | the 02:17 boarded at Platform 1, tunnel crossing, drive to each station |
| 6–7 | Every station's required objectives, to the ending | **Pass: 8/8 in one sitting, 19 minutes** | log: Marrow, Tolbridge, Ninety-Three, Hallow Bridge, Calder, Blackglass, Station Zero, Ward Hill; `RESULTS success=true stations 8/8` |
| 8 | Failure and retry, then complete after retry | Pass (task 4) and abandon/retry this session | crew wipe, auto-retry and a completed station after retry (task 4); Endless abandon then a fresh night |
| 9 | Death, respawn, cutscene interruption | Pass (task 4, 5) | downed, bleed-out, respawn; skipping the cinematic restores camera and input |
| 10 | Replay: duplicates, stale objectives, camera, audio | Pass | three runs in one session: one train per crew, objectives fresh each run, no audio stacking (task 8); camera fault found and fixed below |
| 11 | Runtime errors and performance | Pass, partial | no script errors across three runs; performance in section 8 |

Also exercised this session: the Dispatcher at Ward Hill hurt the player to
37 health but could not down them, and the final hold was won solo without
stopping the tape; six parts were awarded at the run's end; the results
screen announced the Endless Railway.

### Faults found by this pass and fixed

* **Crewmates rode out stuck in a menu.** Departing left any open panel open,
  so a crewmate waiting in the crew panel started the run with the camera held
  by the menu. Panels now close at boarding. Re-tested: the panel opened with
  M, departed, the panel closed and the camera returned to first person.
* **Abandoning an Endless night kept the streak.** Leaving skipped the night's
  report. Abandoning now ends the streak, as failing does (type-checked; not
  observed, because a streak above zero needs a won night).

Both fixes were followed by a fresh departure and Marrow Halt cleared.

## 4. Systems, with evidence

Detail lives in each linked document; each has its own "not tested" list.

| System | Status | Where the player meets it | Evidence | Doc |
| --- | --- | --- | --- | --- |
| The train (the original missing-train fault) | Working | yard, Platform 1, every run | seven trains ridden this week | TRAINS.md |
| Prologue: the passengers vanish | Working | first departure | played every run; skip restores control | PROLOGUE.md |
| Eight stations | Working | the line | 8/8 run above | STATIONS.md |
| Signal Integrity Analyzer (V) | Working | 12 calls at stations 1–4 and Ward Hill | task 14 tests | SIGNALS.md |
| Entities and the train intrusion | Working | travel segments, Ward Hill | task 16, run above | ENTITIES.md |
| Horror director, signature moments | Working | whole route | console log of this run | HORROR.md |
| Night runs | Working | crew panel: Night run | task 11 seeds and events | NIGHT_RUNS.md |
| **Endless Railway** | **Working, new** | crew panel after the ending | section 5 | NIGHT_RUNS.md |
| Earned and premium trains, workshop | Working | loadout, Phantom Exchange | task 18 tests; parts at run end this session | TRAINS.md |
| RIP Coin and the Phantom Exchange | Working | Exchange terminal, results | task 13 ledger tests | MONETIZATION.md |
| Premium weapons and armory | Working in Studio | armory, loadout | simulated ownership tests | MONETIZATION.md, OWNERSHIP.md |
| Audio | Partial | everywhere | 69 of 91 cues have sound; untested by ear | AUDIO.md |
| Voices | **Missing** | radio, signals, prologue | every line is subtitle text | SIGNALS.md |

## 5. Endless Railway (V2 §19)

Opens when the player reaches the story's ending (the results screen says
so). Chosen on the crew panel under Night run. Each night is a seeded plan of
the authored emergencies, unannounced: four on the first night, then one more
emergency, two more tension and 8% less fuel for each night survived in a
row, up to five nights deep. A failure or abandon resets the count. Bonus RIP
Coin is 200 plus 60 per night of depth.

| Test | Result |
| --- | --- |
| Locked before the ending, open after | Pass (played) |
| Launch from the lobby, briefing | Pass: "Endless Railway, night 1, seed 1571: 4 emergencies expected" |
| A different run | Pass: seed 1571 (door, tree, fire, brakes) and seed 63082 (fire, inspection, signal, roof) |
| An emergency handled in play | Pass: "A door will not latch" resolved; inspection done |
| Planner, 200 seeds at each depth 0–5 (dev-assisted) | no invalid plan; 4/5/6/7/8 events by depth; safe fallback plan used for 1 seed at depth 3 and 11 at depth 4 |
| Same seed, same plan | Pass |
| Streak rising after a won night | **Not played** (needs a full won night) |

Known limit: at the deepest night about one seed in twenty falls back to the
small safe plan, an easier night than the depth promises.

## 6. Game Passes, products and the free path

* 20 products are defined (passes, RIP Coin packs, train passes); **0 have an
  ID**. Prices in the code are proposals. The shop shows every Robux item as
  Unavailable until IDs are filled in. Catalogue: MONETIZATION.md and
  TRAINS.md.
* Ownership was tested with Studio simulation (`SimulatePass_*`), never with a
  real purchase. **No live transaction has been made.**
* The story is finishable with free equipment: the run above used the starter
  Warden and the starting wrench.

## 7. Not tested, or blocked

* **Multiplayer (1–4 player lobby, crews, join, disconnect): never tested.**
  Studio's automated Play runs one player. Smallest action: in Studio,
  Test > Clients and Servers, 2 (then 4) players, form a crew and depart.
* Real Game Pass and product purchases (needs IDs from the Roblox site).
* Client frame rate and any device other than the development PC.
* Optional objectives at stations 5–7; signal calls at stations 5–7 (none
  authored); Hard Night and Last Train tiers in play; damage and fuel
  upgrades during a run.
* Reopening the freshly built file and repeating the run from it (section 1).
* Listening to the audio.

## 8. Performance (measured)

Line: 32,526 parts with eight stations (track 7,421, forest 20,627, stations
4,415), built in 1.0 s on the server. Lobby: 2,738 parts. Train: 1,479 parts.
Server heartbeat work 0.20 ms, physics step 0.30 ms (task 8, five stations).
Client frame rate unmeasured (Studio throttles the unfocused viewport to 15
fps).

## 9. External dependencies and configuration

| Item | Where | State |
| --- | --- | --- |
| Game Pass and product IDs | `Config/Monetization.luau` | all 0: create on the Roblox site |
| Admin user IDs | `Config/Admin.luau` | empty |
| Audio asset IDs | `Config/Audio` (AUDIO.md) | 69 of 91 set, Roblox-created or licensed library sounds |
| DataStores | DataService | Studio uses a mock store; enable API access on the live place |
| Leaderboards | OrderedDataStore | disabled in Studio, untested live |
| Voice recordings | none | not produced |

Studio-only test hooks, inert in a live server: `StartAtStation`,
`EntityTest`, `JourneyForce`, `SimulatePass_*`, `TestAllTrains`,
`TestParts`.

## 10. Remaining quality shortcomings

* No recorded voices, and 22 silent cues, weaken the horror more than any
  other gap.
* The longer line meant a thinner forest.
* The harness never walked the route, so walking distances, getting lost and
  how long a real player takes at each station are not measured; the
  19-minute run is a lower bound.
* This is a repaired, extended prototype that plays through. It has not had a
  polish pass or a playtest with real players.
