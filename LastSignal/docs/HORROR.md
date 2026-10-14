# Horror: events, signature moments and threat rules

What frightens the player, when, and why it is fair. Everything listed here
exists in the game; nothing is a plan.

## Pacing

Threat is a 0 to 100 value per expedition, raised by noise, being away from the
train, being alone and time; lowered by completing objectives and by quiet. It
is read through ambience, music and how often something moves at the treeline,
never shown as a number. Events need a minimum threat band, and every event
has its own cooldown on top of a global gap, so loud beats cannot stack and a
calm stretch stays calm.

Hard rails: nothing is scheduled during boarding, the departure cinematic, the
results, the failure screen, or the immunity window after a respawn or retry.
Arriving at a station halves threat and buys 25 s of quiet; a retry resets it
to the station's baseline and buys 60 s.

## Director events

Location: inside = a player is in the train, outside = a player is away from it.
Reset: every event is per run; creatures and threat are cleared by a retry and
by the run ending.

| Event | Where | Band | Cooldown | Trigger | What the player sees or hears | Consequence |
| --- | --- | --- | --- | --- | --- | --- |
| Footsteps on the ballast | inside | 1 | 150 s | director | Footsteps beside the train, positional | None; a warning that something is near |
| Something at the treeline | outside | 1 | 130 s | director | A tall dark figure 70 studs behind one player, for 2 s, seen only by them | None; teaches "look behind you" |
| Localised electrical failure | any | 1 | 160 s | director | Nearby lights flicker; train interior lights cut for 3.5 s | Darkness; the creature will not enter a lit carriage |
| A door that was closed | inside | 2 | 200 s | director | One train door swings open, then shuts after 9 s | Train no longer sealed while it is open |
| A familiar sound, not quite right | outside, mimicry stations | 2 | 190 s | director | A creature mimic call 40 to 90 studs from one player | Lures a player away from the crew |
| Not the dispatcher | mimicry stations | 2 | 240 s | director | A radio line from "Unknown" | Following it raises threat; ignoring it is always safe |
| Evidence of a visitor | outside | 1 | 210 s | director | Footprints from the trees to the player, or claw gouges on the nearest wall | None; something was here |
| It comes to look | any | 3 | 180 s | director | The creature approaches to investigate | Investigate state; quiet and line of sight lose it |
| It has your scent | outside | 3 | 260 s | director | The creature hunts one player | Hunt state; see counterplay below |

The silhouette, evidence and flicker cues had no visible effect until
2026-10-14: the client controller that should draw them did not exist. It does
now (HorrorEffectsController). The door event used to move the whole train by
writing the door model's CFrame; it now swings the door on its joint.

## Signature moments

One per act, each fired once per run on a fixed trigger (SignatureMoments).

| Moment | Trigger | Setup | Payoff | Consequence | Reset |
| --- | --- | --- | --- | --- | --- |
| The second dispatcher | Train passes distance 2,700 on the way to Tolbridge | Control: "Signal at Tolbridge is showing clear. Proceed at line speed." | 11 s later, under failing lights and a distortion sting, the same words from "Unknown"; Control: "That second one was not me. Listen for the callsign." | Teaches the false-transmission tell before the first station where a false instruction costs the crew | Once per run |
| The passenger | Train passes distance 7,700 after Ninety-Three | A dark figure sits very still in the first carriage | When anyone comes within 13 studs, or after a minute, the lights fail and it is gone; on the seat is a ticket for the 02:17, punched, dated eleven days ago | A discovery for the record; the train has made this journey before | A retry clears a half-played passenger and re-arms it |
| The recording | Arriving at Ward Hill | The dispatcher's first line in the yard | The same line plays from a set in the relay room, the tape rewinds, it plays again; the crew realise the guiding voice was a loop | Recontextualises every instruction since the yard; points the crew at the transmitter | Once per run |

Verified in a full Studio run on 2026-10-14: all three fired at their triggers,
in order, with their lines, flickers and the ticket.

## Threat rules: the Signal-Eater

It cannot be killed; damage fills a drive-off meter. It hunts by hearing
first and sight second (patrol, investigate, hunt, retreat). Every counter is
available on the first run with free equipment:

* It will not enter a lit carriage.
* The train horn drives it back at close range.
* A burning flare denies an area.
* Breaking line of sight and staying quiet makes it lose you.

Not yet verified in play: creature navigation around obstacles, attack range,
and recovery from a stuck state. These are part of the final acceptance pass.
