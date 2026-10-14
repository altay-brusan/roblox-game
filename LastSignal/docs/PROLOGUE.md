# The prologue: the passengers vanish

V2 section 12, adapted to the existing story (agreed: keep the five stations,
the radio clues and the Ward Hill recording; put the driver's prologue in
front).

## What the player sees

| When | Where | What |
| --- | --- | --- |
| Boarding | Platform 1 | The 02:17 has passengers in every other seat, visible from the platform and on the walk aboard |
| 0 s | Platform, exterior | The train pulls out. "02:17, Up Main. The last service out of Tolbridge Yard." |
| 2 s | | Role: the crew leader is "the driver tonight"; everyone else is "a conductor tonight" (one storyline in co-op) |
| 3.5 s | Carriage 1, from the front | Passengers in the seats, warm light. The driver on the PA: "Evening, all. Next stop Marrow Halt." |
| 6.8 s | Pushing in down the aisle | A heavy bang from the rear carriage (sound at the rear car), lights stutter |
| 8.3 s | (server) | Every passenger is gone; bags, hats, newspapers, a coat and a flask stay on their seats |
| 8.4 s | Same framing as 3.5 s | "[The carriage is empty. Every seat.]" |
| 11.6 s | Tunnel mouth, exterior | The driver: "Control, this is the zero two seventeen. I've lost my passengers. Control?" |
| tunnel | | Fade; the crossing |
| +3 s | First person, on the line | Belongings still on the seats. Driver: "...My passengers are gone. All of them. Control, do you read?" |
| +10 s | | "[Static. Nothing from Control.]" |
| +14 s | | The yard's own nameboard, TOLBRIDGE YARD, stands alone in the trees ahead. "Where's the yard?" |
| +20 s | | Control answers: the dispatcher's opening lines, too calm and too quick (in Chapter One's twist, a recording) |
| +23 s | | Title card, LAST SIGNAL, over play |
| +40 s | | "That answered before I'd finished asking. And it said we're the last one out. Out of where?" |
| | | First task, already on screen: take the driver's seat |

The cutscene can be skipped after 2 s (Space, or the touch button). It ends
and restores the camera on skip, death, respawn or the run ending. Captions
follow the Subtitles setting.

## Code

`server/World/Prologue.luau` (passengers, vanishing, belongings, nameboard),
`ExpeditionService.begin` and `arriveOnLine` (timing and radio),
`CameraController` SHOTS (a `carriage` space, framed from the carriage floor
found by a ray), `CinematicController` BEATS and the title card.

## Tested (Studio, 2026-10-14)

Captured: passengers in the seats with the PA line; the same framing empty
after the bang; the title card over play after the crossing. Measured: the
train reaches the tunnel at 15 to 23 s after the cutscene starts, so the
vanishing is placed by 8.4 s. Verified: 6 passengers seated, 0 left after the
vanishing, 7 belongings on the line train, the nameboard placed, the radio
sequence and the role line.

## Not done or not tested

* No recorded voices; every line is a subtitle or radio caption.
* Passengers are simple shapes (no faces or animation).
* Replaying the prologue from the menu is not built.
* The cutscene runs before night runs too (skippable).
* A crew of more than one has not been tested (role lines are per player).
