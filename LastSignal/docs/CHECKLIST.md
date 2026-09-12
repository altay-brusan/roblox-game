# Requirement checklist

Every requirement from the brief, with an honest status.

---

## Read this first

**I could not play the game. Roblox Studio is not installed on the machine
this was built on, and I have no way to run Luau against a live DataModel.**

So the statuses below describe *code state*, verified by strict type checking
against the real Roblox API and by reading the code. They do not describe
observed behaviour. Nothing in this document should be read as "I saw this
work".

You ran the build and reported four things. All four were real, I found the
cause of each by inspection, and fixing them uncovered three more defects that
would have stopped a run being completable. Those are marked **Fixed** below.

| Status | Means |
| --- | --- |
| **Fixed** | Was broken or missing. Repaired this pass. Code-verified only, not played. |
| **Implemented** | Code complete, type-checks, logic reviewed. Not played. |
| **Partial** | Implemented, but reduced from what the brief described. The difference is stated. |
| **Missing** | Not implemented. |
| **Blocked** | Cannot be done from this environment. Reason stated. |

---

## What you reported, and what I found

| Your report | Root cause | Status |
| --- | --- | --- |
| "I cannot find any train" | Nothing ever built a train in the lobby. `LobbyBuilder` returned a `trainPreviewCF` that no code used. The train only existed inside an expedition lane after departure. | **Fixed.** A real `TrainBuilder` locomotive and consist now stands on No. 2 Siding, lit, with its doors open so you can walk through it. |
| (implied) no way to start a mission | `CrewBoard`, `NoticeBoard`, `StoresCounter` and `WorkshopBench` were tagged but never wired to anything. Walking up to them did nothing. The only way to reach the crew panel was to guess the M key. | **Fixed.** All four now have proximity prompts and open the right panel. Signage added. |
| "repeated camera correction messages" | The watchdog treated a nil `CameraSubject` as a fault. Between a respawn request and the character arriving, nil is correct, so it corrected once a second forever and logged every time. | **Fixed.** The check now requires a character to exist, `apply` only writes properties that are actually wrong, and the log is rate-limited to once a minute and names which condition tripped. |
| "zero of 83 audio cues configured" | Accurate. Every cue shipped at `id = 0`. | **Partial.** 57 of 83 now carry verified Roblox-created asset IDs. The remaining 26 do not exist in the Roblox library. See Audio below. |
| "one route contains over 32,000 parts" | Accurate, and lower than my own estimate of 60,000. | **Implemented.** Reduction levers documented; see Performance. |

### Three further defects found while fixing those

| Defect | Why it mattered | Status |
| --- | --- | --- |
| **The train could not be driven.** `TrainService` implemented the full cab server-side, but no client interface ever called `claim_driver` or sent a `TrainControl`. | The train sat parked forever. **No expedition could progress past the cinematic, so the game was uncompletable.** | **Fixed.** New `CabController`: sit in the driver's seat, the panel appears, throttle, brake, emergency, reverser, horn, lights, doors, wipers and engine start, on buttons and keys. |
| **Players spawned in the carriage, which has no walkable connection to the cab.** | Even with a cab interface, the controls were unreachable once moving. | **Fixed.** The crew now spawns in the cab. |
| **No feedback during departure.** Nothing rendered the `preparing` state. | Click Depart, the panel closes, and nothing visible happens while the lane builds. Reads as a hang. | **Fixed.** Departure overlay with the countdown, the build phase and a progress bar. |

---

## 1. Primary objectives

| Requirement | Status | Evidence |
| --- | --- | --- |
| Immediately understandable | **Fixed** | Was not: no mission access existed. Now signage, prompts on every lobby fixture, and contextual hints. Untested with a real player. |
| Enjoyable alone | **Implemented** | Solo depart, solo lever timer at Tolbridge, solo code slip at Ninety-Three, crew scaling in `Balance.CrewScaling`. |
| Frightening and atmospheric | **Partial** | Lighting, fog, threat director and creature all implemented. 26 audio cues including the chase loop and radio static could not be sourced; see Audio. |
| Varied enough to repeat | **Implemented** | Five structurally different objective types; the Ninety-Three lever code is generated per run. |
| Reliable in multiplayer | **Implemented** | Crew failure paths, reconnect grace, session locking. **Untested; needs two Studio clients.** |
| PC, mobile and tablet | **Implemented** | Platform detection, scaled spacing, touch layout, safe areas, no drag-and-drop. **No phone has rendered it.** |
| Supports Robux revenue | **Implemented** | 12 products, duplicate-safe receipts, live prices. IDs are zero until you create the products. |

## 2. Quality standard

| Requirement | Status | Evidence |
| --- | --- | --- |
| One coherent production | **Partial** | Geometry, lighting, interface and writing share a direction. Audio is thin and there are no character animations. |
| No crude blockout | **Implemented** | Every surface carries a material; rivets, louvres, grilles, rust streaking, signage. **Terrain is flat parts, not Roblox Terrain** — the one genuinely blockout-ish element. |
| Inspect and improve rather than stopping at first working version | **Fixed** | This pass is that: seven defects found and repaired. |

## 3. Research and creative direction

| Requirement | Status | Evidence |
| --- | --- | --- |
| Study the genre | **Partial** | Design decisions follow from stated reasoning in the code comments. **I did not play Runaways or 99 Nights in the Forest and do not claim to have.** No competitor was launched, watched or inspected. |
| Original identity, no copied assets | **Implemented** | Zero third-party assets. See `ASSETS.md`. |
| Explain significant changes | **Implemented** | This document, plus the topology decision in `GameConfig`. |

## 4. Core experience and story

| Requirement | Status | Evidence |
| --- | --- | --- |
| 02:17 departure, collapsed comms | **Implemented** | `RadioScript` departure beat; `Format.storyClock` runs from 02:17. |
| Dispatcher whose transmissions become inconsistent | **Implemented** | 22 beats, `source = "other"` lines, four consistent learnable tells. |
| Complete first chapter with an ending | **Implemented** | Five stations, climax at Ward Hill, success and failure endings. |
| Story through cinematic, environment, radio, records | **Implemented** | 8 recordings, 13 discoveries, environmental story per station. |
| Objectives understandable without reading records | **Implemented** | Every objective has a title and detail in the corner panel; records give credits only. |

## 5. Social lobby

| Requirement | Status | Evidence |
| --- | --- | --- |
| Outdoor maintenance yard with workshop, shelter, benches, lighting, forest | **Implemented** | `LobbyBuilder`: workshop with inspection pit and gantry crane, covered shelter, stores hut, water column, three roads, buffer stops, fence, clutter, surrounding forest. |
| **Train preview** | **Fixed** | Was missing entirely. Now a full locomotive and consist on the siding. |
| Play, create or join, choose, ready, depart | **Fixed** | The flow existed but was unreachable. Now via the crew board. |
| Public and private crews | **Implemented** | `CrewService.create(private)`, browse list excludes private. |
| Membership and readiness clarity | **Implemented** | Crew panel plus the in-world HUD crew strip. |
| Leader controls and safe transfer | **Implemented** | Transfer, kick, longest-present auto-transfer on leave. |
| Train and difficulty selection | **Implemented** | Leader-only, ownership and level checked server-side. |
| **Official friend invitations** | **Fixed** | Was missing. Now `SocialService:PromptGameInvite` from the crew panel. |
| Departure countdown and cancellation | **Fixed** | Countdown existed; it was invisible. Now shown in the departure overlay. |
| Clear error recovery | **Implemented** | Every refusal returns a reason; the crew panel renders them. |
| Handle failed teleports, reconnects, late arrivals | **Implemented** | Reconnect grace, slot holding. Teleport paths exist but are **Blocked** from testing until two places are published. |
| Voice chat optional, pings provided | **Fixed** | Ping was bound to Q and did nothing. Now implemented server and client with a world marker. Voice chat is a Roblox setting on the published place. |

## 6. Cinematic and onboarding

| Requirement | Status | Evidence |
| --- | --- | --- |
| Rain, lighting, boarding, radio warning, movement near trees | **Implemented** | 8 camera keyframes, 12 text beats. |
| Transition to first-person control | **Implemented** | `finish()` is the single exit; four paths converge on it. |
| Synchronised across the crew | **Implemented** | Server broadcasts start and stop. |
| Clear skip | **Implemented** | Crew vote, half the crew. |
| Respect reduced motion | **Partial** | Reduced motion removes sway, bob and panel animation. The cinematic still moves the camera; I described held frames and did not implement them. |
| Restore camera reliably after skip, death, disconnect, respawn | **Fixed** | All four paths existed; the watchdog that backed them up was misfiring. Now corrected. |
| Player understands task, interaction, supplies, train, return within 30s | **Fixed** | Now: cab spawn, contextual hint naming the exact next action, cab panel hint line that says why the train is not moving. |

## 7. Realistic train

| Requirement | Status | Evidence |
| --- | --- | --- |
| Wheels, axles, suspension, underframes | **Implemented** | Bogies with leaf-spring stacks, axleboxes, brake shoes, spoked wheels. |
| Couplers and carriage connections | **Implemented** | Buffer beams, buffers, drawhook, three-link chain, air pipes with cocks. |
| Panels, vents, grilles, pipes, handrails | **Implemented** | Louvred vents, radiator grilles, pipe runs with elbows, full-length handrails, rivet strips, rust streaking. |
| Steps, doors, windows, lights | **Implemented** | Boarding steps, hinged doors, glazed windows, headlamps, markers, tail lamps. |
| Passenger seating and luggage racks | **Implemented** | Facing bays with tables, racks with brackets. |
| Supply storage and repair equipment | **Implemented** | Supply racks, workbench, vice, tool board. |
| Interior and exterior align; doors lead to real spaces | **Implemented** | Built from shared dimensions. |
| Move between carriages comfortably | **Implemented** | Gangway openings, concertina shrouds, walk plates. |
| **Cab reachable from where you spawn** | **Fixed** | It was not. Crew now spawns in the cab. |
| Not a handful of plain boxes | **Implemented** | Roughly 350 to 450 parts for the locomotive alone. |

## 8. Functional cab and movement

| Requirement | Status | Evidence |
| --- | --- | --- |
| Throttle, service brake, emergency brake, reverser | **Fixed** | Server logic existed; **no interface reached it**. `CabController` added. |
| Headlights, cabin lights, horn, wipers, doors, radio | **Fixed** | Same. All now on the cab panel. |
| Speed, fuel and condition indicators | **Implemented** | Needle gauges in the cab, plus the HUD panel. |
| Every control produces a result | **Implemented** | Wipers move, horn repels the creature, gauges track real state. |
| One driver, safe handover | **Implemented** | Seat occupancy is the authority; leaving releases and applies the brake. |
| Gradual acceleration, meaningful braking, wheel animation | **Implemented** | Eight notches, distance-derived wheel rotation. |
| Passengers walking, jumping, sitting, boarding, respawning | **Implemented** | `TrainRideController` reference-frame ride. **This is the highest-risk untested system in the project.** |
| No jitter, no falling through floors | **Implemented** | Kinematic rigid assembly, hysteretic volume test, velocity preserved. **Untested.** |

## 9. Permanent night and dense forest

| Requirement | Status | Evidence |
| --- | --- | --- |
| Entirely at night, no daylight | **Implemented** | `ClockTime = 2.28`, fixed; nothing changes it. |
| Moonlight, warm windows, lamps, headlights, rain, fog | **Implemented** | Future lighting, fog 55 to 460, practical lights only. |
| Darkness readable and fair | **Implemented** | Marker lamps always on, station lamps, flare light, lamp cosmetics cannot change beam range. |
| Substantial varied forest | **Implemented** | Six archetypes, four variants each, jittered sampling, undergrowth, deadfall, rocks, stumps. |
| No obvious grids or identical trees | **Implemented** | Per-cell jitter plus per-instance colour and rotation. |
| At least four complete major stops | **Implemented** | Five, each with different layout, objectives and threat. |
| Believable interiors, alternative paths, hiding | **Implemented** | Segmented walls around real openings, multiple entrances. |
| **Terrain** | **Partial** | Ground is flat parts with materials, not Roblox Terrain. Readable but flat. |

## 10. Materials and assets

| Requirement | Status | Evidence |
| --- | --- | --- |
| Appropriate materials throughout | **Implemented** | Metal, CorrodedMetal, DiamondPlate, Wood, WoodPlanks, Brick, Concrete, Slate, Grass, Ground, Fabric, Glass, Neon, Rock, Asphalt, Cardboard, Plaster. |
| Normal and roughness maps | **Blocked** | Requires uploaded texture assets. Roblox material variants would need assets I cannot create. |
| Asset register with sources and licences | **Implemented** | `ASSETS.md`, now also listing the 57 audio IDs. |
| Properly licensed | **Implemented** | Roblox primitives plus Roblox-created audio only, each ID verified twice. |
| Inspect imported models, remove scripts | **Implemented** | Nothing is imported. |
| Recognisable by appearance, no floating name boards | **Implemented** | Prompts only, shown for the nearest object. |

## 11. Gameplay loop and variation

| Requirement | Status | Evidence |
| --- | --- | --- |
| Prepare, travel, explore, recover, repair, survive, board, continue | **Implemented** | The expedition state machine. |
| No repeated collection task | **Implemented** | Five different verbs: sequence, simultaneous, relay, timed defend, converge. |
| Restore power, missing component, separated switches, signal code, bridge repair, radio search | **Implemented** | All six present across the five stations. |
| Optional risks and alternative solutions | **Implemented** | Optional objectives, the Hallow Bridge walkway, 13 discoveries. |
| 25 to 40 minutes | **Untested** | Designed around station `expectedSeconds` totalling roughly 39 minutes including travel. Never timed. |
| Scale for crew size, solo viable | **Implemented** | `Balance.CrewScaling`. |

## 12. Roles and cooperation

| Requirement | Status | Evidence |
| --- | --- | --- |
| Driver, mechanic, medic, scout, guard | **Partial** | **Roles are a label only.** They appear on the crew panel and change nothing mechanically. The brief asked for useful specialties; I did not implement per-role abilities and should have said so sooner. |
| No mandatory composition | **Implemented** | Trivially, since roles do nothing. |
| Decisions about splitting, conserving, rescuing | **Implemented** | Weight limits, simultaneous objectives, bleedout timers. |
| Anti-grief | **Implemented** | Door cooldowns, indestructible essentials, emergency brake cooldown. |

## 13. Survival and inventory

| Requirement | Status | Evidence |
| --- | --- | --- |
| Health, stamina, lamp charge, fuel, condition | **Implemented** | `SurvivalService` and `TrainService`. |
| Icons, descriptions, quantities, capacity, five quick slots | **Implemented** | Vector glyphs, weight and slot limits. |
| Equip, use, transfer, drop | **Implemented** | Server-validated. |
| Mobile alternative to drag-and-drop | **Implemented** | Select-then-act everywhere; no drag exists at all. |
| Medical, batteries, ammunition, tools, fuel, components, consumables, story items | **Implemented** | 23 items across all categories. |
| Dropped objects use appropriate models | **Implemented** | Per-item shapes: jerry can with spout and handle, case with latch, page, vial. |
| Server validation | **Implemented** | Ownership, quantity, capacity, proximity. |

## 14. Weapons and combat

| Requirement | Status | Evidence |
| --- | --- | --- |
| Distinct melee and firearms | **Implemented** | 3 melee, 4 firearms with different range, damage, noise, mobility. |
| Convincing models and handling | **Implemented** | Per-weapon viewmodels with receivers, barrels, stocks, bolts, cylinders. |
| Visible first-person hands | **Implemented** | Forearms and hands in every viewmodel. |
| **Third-person animations** | **Missing** | Roblox animations are uploaded assets. Other players hold weapons in the default pose. |
| Mechanism-accurate reloads | **Implemented** | Cylinder, shell-at-a-time, clip, single. |
| Differentiated stats | **Implemented** | `WeaponRegistry`. |
| Combat preserves fear | **Implemented** | Creature cannot be killed; firearms raise threat and call it. |
| Server validates every shot | **Implemented** | Ownership, interval, ammunition, origin, range, hit plausibility, aim direction. |
| Sound, recoil, impacts | **Partial** | Recoil, tracers, muzzle flash and impacts implemented. **Firearm audio could not be sourced.** |

## 15. Horror direction

| Requirement | Status | Evidence |
| --- | --- | --- |
| Reusable director with triggers, cooldowns, escalation, repetition control | **Implemented** | 9 events, threat bands, per-event and global cooldowns, never-twice-running. |
| Avoid predictable schedules and cheap jumpscares | **Implemented** | Scheduled against a player-driven meter, not a timer. |
| Footsteps, silhouettes, misleading radio, door movement, electrical failures, evidence | **Implemented** | All six are director events. |
| Original creature with silhouette, behaviour, counterplay | **Implemented** | The Signal-Eater: four limbs, faceless antenna cowl, hunts by hearing, four counterplays. |
| Hearing, vision, investigation, pursuit | **Implemented** | Four-state machine. |
| No unavoidable deaths during loading, cinematics, respawns | **Implemented** | `suppressed()` checks all three before any event is considered. |
| Quiet and relief; no excessive flashing or gore | **Implemented** | Post-encounter calm, reduced-flashing setting, no gore. |

## 16. Downed state and recovery

| Requirement | Status | Evidence |
| --- | --- | --- |
| Timed rescues, death consequences, spectator | **Implemented** | Bleedout, crawl, half-inventory drop, spectator cycling. |
| Cameras, inventory, reconnects, endings handled | **Implemented** | Camera modes; `restore()` on every path. |
| Paid revive as a Developer Product, real price shown | **Implemented** | `field_revive`, suggested 20 Robux, live price displayed. |
| Optional, with free alternative | **Implemented** | Teammate revive always available and free; the paid offer is hidden while a teammate is reviving. |
| Receipts safe on disconnect | **Implemented** | Banked on vitals if the player is already up. |

## 17. Progression and retention

| Requirement | Status | Evidence |
| --- | --- | --- |
| Persist credits, XP, levels, unlocks, cosmetics, upgrades, achievements, settings, statistics, quests, events | **Implemented** | `ProfileSchema`, versioned with migrations. |
| Daily login, daily and weekly quests, playtime, streaks, collectibles, milestones, event rewards, leaderboards | **Implemented** | All eight. |
| Reward cooperation over grinding | **Implemented** | Crew bonus, co-op quests, no "play N times" quest. |
| Missing a day does not erase progress or pressure payment | **Implemented** | Streak steps back by one; no streak product exists. |

## 18. Train variants and customisation

| Requirement | Status | Evidence |
| --- | --- | --- |
| Meaningful identities and tradeoffs | **Implemented** | Four trains differing in length, nose, bogies, carriage count and handling. |
| Recognisable models, not recolours | **Implemented** | `build` block changes geometry; liveries are separate. |
| Liveries and interior customisation | **Implemented** | 10 liveries, 5 interiors. |
| Starter sufficient to complete the chapter | **Implemented** | Warden has no disqualifying limit. |

## 19. Monetization

| Requirement | Status | Evidence |
| --- | --- | --- |
| Functional shop with clear value | **Implemented** | 12 products across 7 categories. |
| Accurate descriptions, previews, ownership, eligibility, real prices | **Implemented** | Live `GetProductInfo` prices; zero ID renders Unavailable. |
| No duplicate permanent purchases | **Implemented** | Owned state hides the button. |
| No combat advantage, no artificial frustration | **Implemented** | `Monetization.NoCombatAdvantage`. |
| No prompts during cinematics or encounters | **Implemented** | `PromptBlockedStates`. |
| MarketplaceService, duplicate-safe ProcessReceipt | **Implemented** | Records before granting; defers on any failure. |
| Document every ID location | **Implemented** | `MONETIZATION.md`. |
| Zero IDs disable cleanly | **Implemented** | Verified by reading every call path. |
| Analytics for engagement, conversion, repeats, popularity, retention, exit points | **Implemented** | Six derived rates from measured counters. |
| Ownership documented | **Implemented** | `OWNERSHIP.md`. |

## 20. Events and live operations

| Requirement | Status | Evidence |
| --- | --- | --- |
| Configurable events with schedule, objectives, collectibles, eligibility, rewards, expiry, admin control | **Implemented** | `EventRegistry` plus `EventService`. |
| Lost Conductor complete | **Implemented** | Encounter, tickets, mystery, four-tier ladder, limited cosmetic. |
| Reconnects, duplicate claims, stops, expiry safe | **Implemented** | Claim flag read and written in one update; grace period. |
| Future events without rewriting | **Implemented** | Data-driven; documented in `EVENTS.md`. |

## 21. Interface, text and accessibility

| Requirement | Status | Evidence |
| --- | --- | --- |
| Clear English, consistent terms, readable fonts | **Implemented** | One type scale, one vocabulary. |
| No clipped text, overlapping panels, placeholders | **Implemented** | Every label wraps or truncates deliberately. |
| Compact HUD with health, stamina, lamp, objective, context | **Implemented** | Plus train gauges and crew strip. |
| Objective in a corner, never half the screen | **Implemented** | Top left, two lines maximum. |
| Crew, inventory, loadout, train, shop, quest, reward, achievement, leaderboard, settings panels | **Implemented** | Twelve panels. |
| PC, mobile, tablet with safe areas and large targets | **Implemented** | **Untested on hardware.** |
| Menus release and restore mouse control | **Fixed** | Single open panel; the watchdog backing it is no longer misfiring. |
| Subtitles, separate audio controls, reduced motion, reduced flashing, audio alternatives | **Implemented** | Eight volume buses, subtitles on every informational cue, directional indicators. |

## 22. Sound and animation

| Requirement | Status | Evidence |
| --- | --- | --- |
| Coherent soundscape | **Partial** | Mixer, ducking, occlusion, speed-reactive layering all implemented. **57 of 83 cues have audio; 26 do not exist in the Roblox library.** |
| Respond to speed, location, distance, enclosure | **Implemented** | All four. |
| Directional cues and meaningful silence | **Implemented** | Roll-off per cue, director calm periods. |
| Animate doors, cab controls, weapons, characters, interactions | **Partial** | Doors, levers, needles, wipers, wheels and viewmodels animate. **Characters do not.** |

## 23. Administration

| Requirement | Status | Evidence |
| --- | --- | --- |
| RIPjafar1 owner, shayanbrusan1234 admin | **Implemented** | Listed in `Admin.luau` with roles set; **user IDs are 0 until you fill them in**, which grants nothing. |
| Verify by server-side UserId, never trust client | **Implemented** | Every call re-authorises. |
| Currency, XP, items, teleport, announcements, events, info, kicks, content, resets | **Implemented** | 16 commands. |
| Destructive resets owner-only with confirmation, purchases preserved | **Implemented** | Two-step confirm; receipts carried across. |
| Filter announcements, log actions | **Implemented** | TextService filter; 250-entry audit log. |

## 24. Architecture, data and security

| Requirement | Status | Evidence |
| --- | --- | --- |
| Organised across all services | **Implemented** | See `ARCHITECTURE.md`. |
| Separated modules | **Implemented** | 20 services, 10 controllers, 8 registries. |
| Professional Luau with defensive checks | **Implemented** | Strict mode, zero analyzer errors, zero suppressions. |
| pcall, UpdateAsync, retries, session protection, autosave, leave save, BindToClose, migration, duplicate-safe rewards | **Implemented** | All nine in `DataService`. |
| Never overwrite progress with defaults | **Implemented** | Every failure produces a read-only session. |
| Separate test data, Studio limitations explained | **Implemented** | Mock store; `SETUP.md`. |
| Validate payloads, proximity, quantities, ownership, cooldowns, eligibility, transitions; rate limit | **Implemented** | `Guard` plus per-remote token buckets. |

## 25. Performance and reliability

| Requirement | Status | Evidence |
| --- | --- | --- |
| Streaming, detail levels, simplified collision, reusable assets, restrained particles, limited lights | **Implemented** | Streaming on, decorative parts non-collidable and non-queryable, cloned templates, no particles, 26-light cap. |
| Avoid excessive physics, frame loops, leaks, traffic | **Implemented** | Fixed tick rates; nothing gameplay-authoritative per frame. |
| Local effects separate from authoritative gameplay | **Implemented** | Viewmodel and tracers are local; hits are server-decided. |
| Handle connections, crew sizes, departures, reconnects, interruptions | **Implemented** | **Untested.** |
| Measure real device performance | **Blocked** | Cannot run it. Your 32,000-part figure is the only real measurement anyone has. |

## 26 to 28. Process, testing, delivery

| Requirement | Status | Evidence |
| --- | --- | --- |
| Inspect project and tools first | **Implemented** | Audited; installed Rojo and luau-lsp. |
| Do not claim Studio control or untested passes | **Implemented** | This document. |
| Track completed, unverified, blocked work | **Implemented** | This document and `STATUS.md`. |
| Back up before major changes | **Implemented** | Git, 16 commits. |
| **Test the full journey** | **Blocked** | No Studio. You are the only person who can run it. `TESTING.md` is the checklist. |
| Editable place, source, placement, dependencies, asset sources, install, monetization, ownership, admin, event docs, testing, limitations, status | **Implemented** | 14 documents. |
| No "implement this later" | **Implemented** | No stubs remain. Missing items are named here, not hidden. |

---

## Remaining known issues

| Issue | Severity | Why |
| --- | --- | --- |
| Nothing has been played | **High** | No Studio on this machine. Everything above is code-verified only. |
| 26 audio cues silent | Medium | Roblox-created library has no train horn, brakes, wind, radio static, heartbeat, firearms or horror music. Filling them needs audio you own and upload. |
| No third-person character animation | Medium | Needs uploaded animation assets. |
| Roles are cosmetic | Medium | Brief asked for useful specialties; they are labels. Honest gap. |
| Ground is flat parts, not Terrain | Low | Reads flat next to the forest detail. |
| Reduced motion does not change the cinematic | Low | Described held frames; did not implement them. |
| Two-place mode untested | Low | Needs two published places. |
| 32,000 parts per lane | Low | Streaming handles it; levers documented in `PERFORMANCE.md`. |

---

## What to do next

1. Open `LastSignal/build/LastSignal.rbxlx`, press Play, and check the F9 log.
   You should now see a lit train on No. 2 Siding and a prompt on the crew
   board.
2. Walk to the crew board, press E, depart alone.
3. Watch the departure overlay, then the cinematic.
4. You spawn in the cab. Sit in the driver's seat. The cab panel should appear
   with a hint line telling you exactly why the train is not moving yet.
5. Release the brake, open the throttle, and confirm the train moves and that
   you can walk around inside it.
6. Tell me what actually happens. That is the only way the remaining unknowns
   become known.
