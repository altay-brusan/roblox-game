# Testing

The acceptance checklist from the brief, with current results.

---

## Current results

| Test type | Status |
| --- | --- |
| Syntax, all 64 files | **Pass.** `luau-compile` 0.738 |
| Strict type check against the real Roblox API, all 64 files | **Pass.** `luau-lsp analyze` 1.69.0, 0 errors, 0 suppressions |
| Cross-module require resolution | **Pass.** Via Rojo sourcemap |
| Place assembly | **Pass.** `rojo build` produces a 1,015 KB `.rbxlx` |
| Everything below this line | **Not run.** Roblox Studio is not installed on the build machine |

Compilation is not sufficient and this document does not pretend otherwise.
The list below is what still has to be done, not what has been done.

Reproduce the passing checks with:

```bash
bash scripts/check.sh
bash scripts/build.sh
```

---

## How to run the rest

Open `build/LastSignal.rbxlx` in Studio.

For anything involving more than one player, use **Test, Clients and Servers**,
set the player count, and click **Start**. Crews, revives, the simultaneous
objective at Tolbridge and the relay objective at Ninety-Three cannot be tested
any other way.

Purchases and leaderboards require a published place; they cannot complete in
Studio.

Keep the **Output** window open. Every service logs with a `[LAST SIGNAL]`
prefix and its own name.

---

## 1. Boot and configuration

- [ ] Server starts with no errors in Output
- [ ] Boot log lists all 20 services under their stage headings
- [ ] Configuration report prints, and correctly reports monetization, admin
      and audio as unconfigured when they are
- [ ] `Data: Studio mock store` appears when testing in Studio
- [ ] Client boot log reports all 10 controllers started
- [ ] Loading screen appears and dismisses itself
- [ ] Loading screen dismisses even if the world never finishes building
      (test by breaking `WorldService.start` deliberately)

## 2. Lobby

- [ ] The yard builds: workshop, shelter, stores hut, water column, three
      roads, buffer stops, lighting, fence, clutter
- [ ] Forest surrounds the yard with no visible grid or repeated trees
- [ ] Player spawns under the shelter, not inside geometry
- [ ] It reads as night: lamps are the light source, wet ground reflects
- [ ] Workshop interior is enterable and lit
- [ ] Stores hut counter is reachable
- [ ] Frame rate is acceptable standing in the middle of the yard

## 3. Crews

- [ ] Create a public crew; it appears in another player's browse list
- [ ] Create a private crew; it does not appear
- [ ] Join a crew from the browse list
- [ ] Ready and unready; the other player's panel updates
- [ ] Leader departs; countdown runs and shows the remaining time
- [ ] A member unreadies mid-countdown: countdown cancels and names them
- [ ] A member joins mid-countdown: countdown cancels
- [ ] A member leaves mid-countdown: countdown cancels if the crew is invalid
- [ ] Leader leaves: leadership transfers to the longest-present member and
      everybody is told
- [ ] Leader kicks a member: they are removed and told why
- [ ] Leader transfers leadership: both panels update
- [ ] Crew of six can form; a seventh is refused
- [ ] Solo depart works from the crew panel
- [ ] Third crew on a server with two lanes is told the line is occupied,
      clearly, rather than left waiting

## 4. Cinematic and onboarding

- [ ] Cinematic plays for every crew member at the same time
- [ ] Camera follows the keyframe path; letterbox and titles appear
- [ ] Skip prompt appears after the skippable-after delay, not before
- [ ] One player skipping shows the vote count to everybody
- [ ] Half the crew skipping ends it for everybody
- [ ] Control, camera and mouse capture return correctly after a skip
- [ ] Control returns correctly when the cinematic runs to completion
- [ ] Dying during the cinematic ends it and returns control
- [ ] Reduced motion setting removes the camera movement
- [ ] Within 30 seconds of gaining control a new player has been told the
      immediate task, how to interact, and where the train is

## 5. Train

- [ ] The locomotive reads as a locomotive: bogies, buffers, grilles, handrails
- [ ] Interior and exterior geometry align; windows are where windows are
- [ ] Every carriage is walkable end to end through the gangways
- [ ] Throttle moves the train, with gradual acceleration
- [ ] Service brake slows it with a meaningful stopping distance
- [ ] Emergency brake stops it hard, costs condition, and is rate limited
- [ ] Reverser cannot be moved while rolling
- [ ] Headlights, cabin lights and interior lights each toggle and are visible
- [ ] Horn sounds and, at close range, drives the creature off
- [ ] Wipers visibly sweep
- [ ] Doors open and close, and will not open above walking pace
- [ ] Speed, fuel and condition needles track their real values
- [ ] Only one player can drive; a second is refused
- [ ] Leaving the seat releases control and applies the brake
- [ ] **Walking around inside a moving train works without jitter**
- [ ] **Jumping inside a moving train lands correctly**
- [ ] **Nobody falls through the floor at any speed**
- [ ] Jumping out of a door while moving leaves you behind
- [ ] Respawning while the train is moving places you correctly
- [ ] Sitting in a passenger seat while moving works

## 6. Stations

For each of Marrow Halt, Tolbridge Camp, Ninety-Three, Hallow Bridge and Ward
Hill:

- [ ] The station builds and reads as its described place
- [ ] Every building marked interior is enterable and has more than one way in
- [ ] The objective panel names the current objective in the corner, two lines
      at most
- [ ] Loot nodes are searchable once, and give their guaranteed contents
- [ ] Overflow loot is dropped at the container rather than destroyed
- [ ] The station's objective completes and awards credits and XP
- [ ] The train releases to the next station on completion
- [ ] Lights come on when the station is powered, where applicable

Station-specific:

- [ ] **Marrow Halt.** Fuse, generator, breaker sequence works in order; fuel
      point only works once powered
- [ ] **Tolbridge.** Two levers held at once by two players releases the
      interlock; a solo player can do it via the timed lever
- [ ] **Ninety-Three.** The frame shows a code; the four ground levers accept
      it; a wrong combination is recoverable and makes noise; the code differs
      between runs
- [ ] **Hallow Bridge.** Valve from the stores fits at the pump house; the
      timed defend step progresses while somebody is near and pauses when not
- [ ] **Ward Hill.** Power sequence, then transmitter, then the mast timer;
      the ending fires

## 7. Combat

- [ ] Each weapon's viewmodel appears with visible hands
- [ ] Firing produces a muzzle flash, a tracer and an impact mark
- [ ] Recoil kicks the view and settles
- [ ] Ammunition decrements and comes from inventory items
- [ ] Reload takes the weapon's stated time, and the shotgun loads shell by
      shell
- [ ] Reloading with no ammunition is refused
- [ ] Firing with an empty magazine dry-fires rather than shooting
- [ ] Melee costs stamina and will not swing without it
- [ ] Melee hits within its arc and misses outside it
- [ ] Shooting another player does nothing
- [ ] Sustained damage drives the creature off rather than killing it
- [ ] A gunshot raises threat and brings the creature to investigate

## 8. Survival, downed and recovery

- [ ] Health, stamina and lamp charge all drain and recover as described
- [ ] Sprint drains stamina and locks out when exhausted
- [ ] Lamp flickers at low charge before dying
- [ ] Batteries restore lamp charge
- [ ] Bandages heal and stop bleeding
- [ ] Being downed starts a bleedout timer and allows crawling
- [ ] A teammate can revive by holding position; the bar fills
- [ ] Moving away cancels the revive
- [ ] Two players cannot revive the same person at once
- [ ] Bleeding out kills and drops half the inventory at the body
- [ ] Spectator mode follows a living crew member and can cycle targets
- [ ] The self-revive button is only offered while down, and never while a
      teammate is reviving
- [ ] The self-revive button is absent entirely when the product is
      unconfigured
- [ ] Each subsequent down has a shorter bleedout

## 9. Horror direction

- [ ] Nothing fires during the cinematic
- [ ] Nothing fires during loading
- [ ] Nothing fires inside the respawn immunity window
- [ ] The same event never fires twice in a row
- [ ] There is genuine quiet between events
- [ ] After the creature is driven off there is a long calm
- [ ] Threat rises with noise and with time away from the train
- [ ] The creature will not enter a lit carriage
- [ ] A flare denies its area
- [ ] Breaking line of sight and staying quiet loses it
- [ ] The music bed changes with the threat band
- [ ] A false radio transmission appears and is distinguishable
- [ ] Ignoring a false transmission is always safe

## 10. Progression and persistence

- [ ] Credits and XP are awarded and persist across a rejoin
- [ ] Levelling up fires and the new level persists
- [ ] Achievements unlock from statistics
- [ ] Daily quests appear and are the same for two players on the same day
- [ ] A completed quest can be claimed once; a second claim is refused
- [ ] Daily login can be claimed once per day
- [ ] Missing a day steps the streak back by one rather than resetting it
- [ ] Playtime rewards appear and are capped per day
- [ ] A profile that fails to load produces a read-only session with a visible
      warning, and does not save
- [ ] Progress survives a server shutdown (test BindToClose by stopping the
      server while a change is unsaved)

## 11. Monetization

Requires a published place with products configured.

- [ ] Shop lists every product with its live price from MarketplaceService
- [ ] An unconfigured product shows as Unavailable with a disabled button
- [ ] An owned permanent product shows as Owned with no buy button
- [ ] Buying a Game Pass grants its contents
- [ ] Buying the same Game Pass twice is impossible
- [ ] Buying a Developer Product grants its contents once
- [ ] The same receipt cannot grant twice (test by rejoining immediately)
- [ ] Leaving during a purchase delivers it on the next join
- [ ] A purchase on a read-only session is deferred, not lost
- [ ] Credit purchases deduct correctly and refuse when short
- [ ] No Robux prompt can be opened during the cinematic or the climax
- [ ] Emergency stimulant bought while already revived is banked, not lost

## 12. Events

- [ ] `event start lost_conductor 24` starts it and announces it
- [ ] Tokens spawn at stations and can be collected
- [ ] Reward thresholds unlock at the right token counts
- [ ] A reward can be claimed once; a second claim is refused
- [ ] The Conductor appears during travel, walks the train, and does no damage
- [ ] Holding a ticket makes the encounter safe and consumes the ticket
- [ ] Holding no ticket puts the lamp out until the next station
- [ ] `event stop lost_conductor` stops new progress
- [ ] Rewards already earned can still be claimed after it stops
- [ ] Tokens already collected are not removed

## 13. Administration

- [ ] With user IDs unset, no command works for anybody
- [ ] With user IDs set, the owner can run every command
- [ ] The admin can run everything except resets
- [ ] A normal player running a command is denied and the denial is logged
- [ ] `resetplayer` requires a second identical call to confirm
- [ ] A reset preserves purchase records and re-applies their entitlements
- [ ] `announce` is filtered before broadcast
- [ ] A moderator cannot kick an admin

## 14. Interface, mobile and accessibility

- [ ] No text is clipped in any panel at any size
- [ ] No panel covers more than it should; the objective stays in its corner
- [ ] Opening a panel releases the mouse; closing it recaptures
- [ ] Closing works via the button, the key that opened it, and the backdrop
- [ ] Every touch target is large enough to hit reliably on a phone
- [ ] Nothing sits under a notch or a home indicator
- [ ] The inventory works with no drag-and-drop
- [ ] Lists scroll, and their canvases reach the bottom of their content
- [ ] Subtitles appear for every informational cue
- [ ] Directional indicators point correctly when enabled
- [ ] Reduced motion removes sway, bob and panel animation
- [ ] High contrast visibly changes the interface
- [ ] Each of the eight volume sliders affects only its own bus

## 15. Failure recovery

- [ ] Disconnecting mid-expedition holds the slot; rejoining returns you to
      your crew
- [ ] Everybody disconnecting tears the expedition down and frees the lane
- [ ] Abandoning an expedition returns you to the yard without ending it for
      the others
- [ ] The camera watchdog corrects a deliberately broken camera within a second
- [ ] A service failing at boot is logged and the rest still start
- [ ] Nothing leaves a player on a loading screen with no way out

## 16. Performance

- [ ] Frame rate in the lobby on a mid-range device
- [ ] Frame rate at a station with a crew of six
- [ ] Frame rate during a chase
- [ ] Server CPU with two expeditions running
- [ ] Memory after several expeditions have started and ended, confirming the
      lane reset frees what it should
- [ ] Time to build the first lane

Record the numbers you measure in [PERFORMANCE.md](PERFORMANCE.md), which
currently contains estimates and says so.
