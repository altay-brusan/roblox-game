# Entities and the train intrusion

V2 section 16. No zombies; each entity has its own look, sound, rule and
answer, is announced or readable before it hurts anyone, and kills no one
outright. Entity damage does not cause bleeding (the hit is the whole
consequence).

Code: `server/Services/EntityService.luau`, the Window Passenger's client half
in `client/Controllers/HorrorEffectsController.luau`, the Caller in
`CreatureService.luau`.

| Entity | Where and when | Tell | Rule | Answer | Consequence if ignored |
| --- | --- | --- | --- | --- | --- |
| The Caller (the Signal-Eater) | Stations and the line (existing) | Distant calls, false radio voices | Hunts by sound first, sight second; steals phrases | Light, the horn, flares, quiet; the analyzer for its voices | Attacks; follows false calls into traps |
| The Window Passenger | On the line, 2,600 and 9,300 | A pale face at a carriage window, only where nobody is looking | Looking straight at it makes it go | Watch the windows | After 25 s unwatched, that carriage goes dark for 30 s, threat +12 |
| The Hollow Conductor | On the line, 5,400 and 12,600 | Blue light in every carriage, a ticket punch clicking, "Tickets, please" (first time, an explicit hint), 6 s before it appears | Walks rear to front through every carriage | Sit down, or be out of its carriage | Standing in its way: 30 damage once per pass |
| The Switchkeeper | On the line, 8,400 | A figure at a lineside signal showing a red with a flickering lamp, no telephone, no Control on the radio | Its signal is false; train protection ignores it | Drive past, or sound the horn within 300 studs | Stopping within 260 studs for 7 s: it works the couplings, condition -12, threat +15 |
| The Dispatcher | Ward Hill, 30 s after arrival | The loop playing as Control, a figure walking down from the mast | Walks slowly towards the nearest of the crew while the tape plays | Stop the tape in the relay hall (3 s hold) | Within 5 studs: 15 damage every 2 s |
| The intrusion | On the line, 11,300 | A broken dispatch ("several of them... converging... shut everything"), footsteps on the roof, 20 s warning | Comes in through any open or unlatched door | Shut every door before the 20 s run out | It gets into that carriage: lights out, 12 damage every 2 s to anyone inside, for 18 s; leave the carriage |

Only one entity runs at a time; each re-arms after a retry's checkpoint and
everything is cleaned up when the run ends.

## Tests (Studio, 2026-10-14; entities summoned by a Studio-only test
## attribute, then played)

| Test | Result |
| --- | --- |
| Conductor, standing in its path | 100 to 70 at the 7 s mark, once |
| Conductor, seated in Carriage1 | 100 throughout a full pass |
| Conductor, in the cab | not touched |
| Intrusion, all doors shut | "It tried every door. Nothing open." |
| Intrusion, a door open | "It is inside"; carriage dark; staying cost 58 health in about 10 s; "It has gone" at the end |
| Switchkeeper, horn | "It went at the horn" |
| Switchkeeper, drive past | "You drove past it" |
| Window Passenger, looked at | vanished, server told |
| Window Passenger, unwatched | "A carriage has gone dark" after 25 s |
| Dispatcher | walked 16 studs in 5 s towards the crew; stopping the tape ended it |

Found and fixed during testing: the conductor's hit started bleeding, which
then downed the player (entity damage no longer bleeds); finished entities
were never removed, blocking every later one; the Window Passenger was placed
on the wall, not at a window.

## Not tested or open

* Switchkeeper, stopping for it (the train would not move in that test
  session; not investigated).
* Entities at their scheduled distances in a full run, and with more than one
  player (the conductor checks every player; the intrusion every carriage).
* The Window Passenger reads as a pale glow through the glass more than a
  face; readability needs work.
* The Caller's name: in game it is still called the Signal-Eater.
