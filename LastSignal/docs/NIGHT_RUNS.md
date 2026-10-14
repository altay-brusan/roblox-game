# Night runs: the repeat-journey mode

A night run is the same line, stations and objectives as the story, with a
seeded set of emergencies on the way and a route decision at Tolbridge.
Chosen on the crew panel (Journey: Story or Night run). It is the base for
the post-campaign Endless Railway in brief V2 §19 (not yet gated behind the
ending; see "Open").

Code: `shared/Registry/JourneyRegistry.luau` (data), `server/Services/JourneyService.luau`
(planner, runtime, report, progression), `server/Journey/JourneyEvents.luau`
(the eight events), `client/UI/JourneyUI.luau`, `client/Controllers/JourneyController.luau`.

## Event templates

| Event | Kind | Onset and evidence | Player action | Escalation | Failure | Cleanup and reset |
| --- | --- | --- | --- | --- | --- | --- |
| Carriage blackout | technical | Carriage lights die; red-lit breaker box on the first carriage wall; Control radio line | Reset the breaker (3 s hold) | 45 s: threat +20 | 120 s: threat +25 | Lights restored |
| Signal at danger | route | Train held short of a red signal post; Control radio line | Ring Control from the post telephone (3 s), cleared 6 s later | 60 s: threat +10 | 150 s: timetable clears it (delay was the cost) | Aspect turns green, post removed, train released with "Line clear" |
| Dragging brakes | technical | Sparks at the bogie, speed capped, fuel burn x1.8 | Stop, step out, release the valve on the locomotive (5 s) | 60 s: cap drops to a crawl | none: the cost is time and fuel | Cap and fuel multiplier removed |
| Tree across the line | route | Train held short of a fallen pine | Two 6 s cuts; each is noise the creature hears | 50 s: threat +15 | none: it must be cleared | Tree removed, train released |
| Electrical fire | technical | Fire, smoke and glow from a heater in a carriage | Beat it out (6 s) or spend a coolant canister (2 s) | 25 s: fire grows, condition -6 | 75 s: condition -10 and a carriage blackout starts | Fire removed |
| A door that will not latch | technical | A carriage door swings open; speed capped to a crawl | Force it shut (6 s, 2 s with a crowbar) | 40 s: threat +10 | none | Door closed, cap removed |
| Something on the roof | horror | Footsteps walking the roof, creature sounds | Sound the horn, or keep the train sealed and lit | 20 s: attack sounds | 40 s: if a door was open or the train dark, condition -8 and a door is forced open | none needed |
| Unscheduled inspection | station | Control asks for the inspector's log at this station to be signed; log placed by a station fixture, chosen by the seed | Sign it (2 s) | none | Leaving without signing: no reward | Log removed |

### Cause and effect between events

* The signal post telephone runs off the train's power: during a blackout it
  refuses ("The line is dead...") until the breaker is reset.
* An electrical fire left to burn starts a carriage blackout.
* The roof visitor, finding the train open or dark, forces a door (door jam).
* Dragging brakes burn fuel, which matters most on the cut-off, where there is
  no refuelling stop.

## Routes and the choice

| Route | Stations | Trade-off |
| --- | --- | --- |
| Main line | Marrow Halt, Tolbridge, Ninety-Three, Hallow Bridge, Ward Hill | Ninety-Three has fuel and supplies, and a station of work |
| Ninety-Three cut-off | Marrow Halt, Tolbridge, Hallow Bridge, Ward Hill | One station shorter; no refuelling between Tolbridge and Hallow Bridge |

Offered at Tolbridge as a card; any crew member chooses; leaving without
choosing takes the main line. Shown on the report with who chose it.

## Planning rules

Seeded (`Random.new(seed)`), weighted, one of each template per run,
per-template segments, tension budget per tier, incompatible pairs never in
one segment (holds together; roof plus blackout; roof plus door jam; fire plus
blackout), at most one train-holding event at once, a simultaneous cap of
`tier.maxSimultaneous` (+1 for crews of three or more), 450 studs of quiet
after each stop and 700 between events, 25 s of recovery after each event,
and the last run's headline event is not the headline again. If no valid plan
comes out of 25 attempts, a fixed fallback plan is used and the report says
so. At run time, an event that cannot start is recorded as skipped and the run
continues.

Tiers: Night Run (3 events, briefed, full tank), Hard Night (5, two can
overlap, unbriefed, three-quarter tank; after 1 completed night run), Last
Train (7, overlapping, unbriefed, half tank; after 3).

Earned, never sold: Night Run patch (1 run), Lineman's toolkit, night-run jobs
20% faster (3 runs), Soot weapon finish (5 runs). Rewards are recorded by run
GUID, so a run is paid once.

## Test record (Studio, 2026-10-14)

Planner (direct calls):

| Seed | Tier | Crew | Plan |
| --- | --- | --- | --- |
| 101 | night | 1 | inspection@2, signal_fault@4, carriage_blackout@5 |
| 202 | night | 1 | signal_fault@2, door_jam@3, carriage_blackout@4 |
| 303 | hard | 1 | carriage_blackout@3, signal_fault@3, brake_drag@4, door_jam@4, fallen_tree@5 |
| 404 | hard | 4 | signal_fault@2, door_jam@3, inspection@4, roof_visitor@4, brake_drag@4 |
| 505 | last | 1 | door_jam@1, brake_drag@2, signal_fault@3, carriage_blackout@3, roof_visitor@4, electrical_fire@5, fallen_tree@5 |
| 606 | last | 4 | inspection@2, carriage_blackout@2, electrical_fire@3, signal_fault@3, brake_drag@4, fallen_tree@5, roof_visitor@5 |

Same seed gave the same plan; with seed 101's headline as the last run's, the
headline changed (blackout to brakes); roof visitor plus blackout in one
segment was rejected by the validator.

Live runs (forced plans via the Studio-only `JourneyForce` attribute,
developer-assisted: harness teleports to each job, real held interactions):

1. door jam, inspection, blackout, signal, fire, tree; route set to the
   cut-off. Door forced shut; signal cleared by telephone; Ninety-Three skipped
   and the train ran on to Hallow Bridge; the fire, left alone, escalated and
   then started a blackout. Found and fixed: `run_task` missing from the
   interaction allow-list (every job was ignored); events silently dropped
   after a station's quiet period.
2. inspection, brakes, roof, tree. Brakes capped the train, escalated to a
   crawl, released from the valve; the roof visitor was held back by the
   one-at-a-time cap and correctly recorded as passed; tree held the train,
   two cuts, "Line clear".
3. roof, inspection, tree, with a death and retry after the tree, played to
   the ending. Roof visitor thrown off by the horn; log signed; retry at
   Tolbridge re-armed the inspection (signed again) and the tree (appeared and
   was cut again); success at Ward Hill. Report: seed 43811, route, three
   events with outcomes, 300 bonus, Night Run patch unlocked, saved.
   Found and fixed: the held weapon froze the player after any retry (see
   task 10 fix in WeaponModels); a retried station counted twice ("6 of 5");
   the inspection reward paid again after a retry.

## Open (untested or not done)

* The two retry fixes above (station count, single inspection reward) were
  made after run 3 and are type-checked, not re-played.
* Not exercised live: Hard Night and Last Train tiers, overlapping events,
  the Lineman's toolkit and Soot unlocks, fallback plan at run time, a crew of
  more than one, disconnect during an event, data-load failure (handled in
  code: the run plays and the report says progress was not saved), duplicate
  completion (guarded by run GUID and the finish state; not exercised).
* A run using each premium weapon, and performance with events active.
* Endless Railway (V2 §19): unlock after the story ending, naming, and
  increasing risk are not done.
* `StationRegistry.TravelEvents` (deer crossing, tunnel, long grade, intruder)
  is data that nothing uses; it predates this work.
