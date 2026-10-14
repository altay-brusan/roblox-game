# Signals and the Signal Integrity Analyzer

The analyzer (V, or the right stick press) is how a crew judges a radio call:
a real person, a recording, a mimic, or an anomaly. It is free, from the
first station, for everyone. Fidelity 2 (bearing noise 12° down to 5°) is
earned after five correct verdicts.

Code: `server/Journey/SignalRegistry.luau` (the calls; server-only so the
truth never reaches a client), `server/Services/SignalService.luau`,
`client/Controllers/SignalController.luau`.

## The six channels

| Channel | How it works | Authored or computed |
| --- | --- | --- |
| Bearing | Sweep from two places at least 15 studs apart; the server triangulates the two noisy bearings against the call's real source and reports where the estimate lands, with its uncertainty, against where the caller claims to be | Computed (geometry, fidelity and interference noise) |
| Waveform | The signal's shape: natural breath, copied breaths, phase reversal, machine tones, noise | Authored per call; drawn live on the screen |
| Time and route | Timestamp, handset or dispatch ID, kilometre post | Authored |
| Challenge | Ask a question from a short list; hear the reply | Authored |
| Cross-evidence | Examine the place the caller names (a physical clue there) | Authored, placed in the world |
| Compare | Two calls side by side: shared phrasing, and whether it is used or quoted | Authored links, computed match |

The label (Unverified, Unknown, Inconsistent, Likely human, Likely a
recording, Likely a mimic, Likely an anomaly) is computed only from the
evidence the crew has gathered. Fewer than two pieces is Unverified; a close
call is Inconsistent. Nothing is random and nothing reads the truth.

Verdicts: Answer it (a meeting point at the named place; reaching it resolves
the call), Mark it as a mimic, or Leave it. A correct verdict pays 15 RIP Coin
once per call per run. Leaving the station ends its calls unanswered; a retry
replays the station's calls; the notebook is shared with the whole crew.

## The twelve calls

| Station | Call | Truth | Key evidence | If answered | If marked a mimic |
| --- | --- | --- | --- | --- | --- |
| Marrow Halt | Woman, station house | human | triangulates to the station house; natural speech; timestamp now; knows the door's number; fresh footprints | Edith Marr rescued, rides the train | she is lost |
| Marrow Halt | Announcement | anomaly | stitched words, no clock, no reply, a chewed tannoy | the old tannoy | nothing |
| Tolbridge | Man, saw shed | mimic | bearing in the trees; copied breaths; timestamp in the future; nonsense reply; dusty handset | trap: threat, the creature is drawn there | 15 RIP Coin; the fuel bait is safe to take |
| Tolbridge | Men, the loader | echo | a nine-second loop; eleven days old; a dictaphone on the seat | the last shift, on tape | nothing |
| Tolbridge | Child, very faint | human (hard: heavy interference) | noisy bearing; natural breathing under noise; knows her father's name; quotes "come alone" as a warning; small boots | Lily Adey rescued | she is lost |
| Ninety-Three | Control? | mimic (hard: clean waveform) | wrong dispatch ID; repeats Control's words; rusted ladder; "the last one out" | trap | 15 RIP Coin; relay spares |
| Ninety-Three | Your own crew? | echo (the twist) | recorded at Hallow Bridge forty minutes from now; reel labelled in your handwriting | a reel you will record later tonight | nothing |
| Hallow Bridge | Man, pump house | human (bridge steel bends the bearing) | knows the depot code; chalk 411 on the door | Ray Okafor rescued | he is lost |
| Hallow Bridge | Someone in the water | mimic | phase reversal; wrong kilometre post; handprints going down only | trap | 15 RIP Coin; flood locker |
| Hallow Bridge | Tones | anomaly | machine tones on a schedule; telemetry box | the span's telemetry | nothing |
| Ward Hill | Woman, accommodation | human | natural speech; extension 4; whose voice the loop is; a slept-in bed | Ann Hale rescued; she made the recording | she is lost |
| Ward Hill | Your crew, outside | mimic | your cab radio is not transmitting; syllables off the breath; unbroken mud | trap | 15 RIP Coin; mast store |

Three calls carry the "come alone" phrase: two mimics use it, the child
quotes it as a warning. Comparing calls tells the difference.

## Tests (Studio, 2026-10-14, developer-assisted: harness moves the player,
## real remote calls and held interactions)

* Marrow Halt, Woman: two sweeps 80 studs apart triangulated to the station
  house (within about 12 studs); waveform, timing, question and clue gathered;
  label Likely human; answered in person; Edith Marr appeared seated in the
  first carriage; 15 RIP Coin. Analyzer screen captured with dial, spectrum,
  buttons and evidence.
* Marrow Halt, Announcement: after waveform and a question, Inconsistent
  (the clue is needed to call it); left.
* Tolbridge, Saw shed: waveform, timing, question, clue: Likely a mimic;
  marked; correct; two supply drops at the saw shed.
* Tolbridge, Child: compare with the saw shed ("quoted, as a warning"),
  question, waveform: Likely human despite heavy interference.

Not yet tested live: the Ninety-Three, Hallow Bridge and Ward Hill calls; a
mimic answered in person (the trap); fidelity 2; a retry replaying calls; the
shared notebook with more than one player; the results screen's signal
section. Voice performances do not exist yet; every line is subtitle text.
