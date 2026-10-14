# Progress record (master brief, October 2026)

The continuation record the brief asks for: the current build, what changed,
what is verified and how, what is pending, and the next concrete action. It is
updated as work lands. If a session ends, start from **Next action**.

## Session capabilities (verified 2026-10-13)

| Capability | Status | How |
| --- | --- | --- |
| Inspect and edit the place | Available | Official Roblox Studio MCP server (`mcp.bat`), registered in Claude Code as `Roblox_Studio` |
| Enter and leave Play mode | Available | `start_stop_play` |
| Read runtime output | Available | `get_console_output` |
| See the viewport | Available | `screen_capture` (play viewport, 812x675) |
| Send keyboard and mouse input | Available | `user_keyboard_input`, `user_mouse_input`, `character_navigation` |
| Run Luau on server or client during play | Available | `execute_luau` |
| Hear audio | **Not available** | Audible verification stays untested |
| Live Robux purchases | **Not available / not authorised** | Purchase tests are simulated or untested |
| Independent playtesters | **Not available** | Not performed |

Source of truth is `src/`. Edits reach the open Studio session through
`tools/devsync` (a local server plus a command-bar snippet); the shipped place
is always produced by `scripts/build.sh`.

## Baseline (before this brief's changes)

* Backup: `backups/LastSignal_baseline_6a2fe24_2026-10-13.rbxlx` (commit 6a2fe24).
* Boot log: 20 services start, 57 of 83 audio cues configured, lane 1 built
  in 0.7 s with 32,960 parts, lobby 3,460 parts.
* First view: spawn faces a dark wall; only a text hint explains what to do.

## Verified defects and root causes

| # | Defect | Root cause (verified) | Status |
| --- | --- | --- | --- |
| 1 | Train "missing" / misplaced | Doors were opened by writing the CFrame of welded door parts. Writing the CFrame of any part in a welded assembly moves the whole assembly, anchored root included (reproduced with a 3-part test assembly). The lobby train ended up across the yard, through the fence; the lane train was swung off its track the moment `applyDoors` ran at spawn. | Fixed: door hinges, gauge needles and wiper arms are articulated with their own `Weld`, animated through `C0` |
| 2 | Gauge needles fall off | `setNeedle` destroyed the needle's weld and left it unanchored | Fixed by the same articulation |
| 3 | Expedition train drives away from every station | Spawned turned 180 degrees 60 studs before the start of the track; "forward" was +Z, stations are at -Z | Fixed: faces up the line, consist centred on the station at its stop distance, 400-stud approach track behind the origin |
| 4 | Passengers not carried / stutter | Ride volume was placed in front of the train (sign assumed the old rotation); `GetBoundingBox` on 1,300 parts every frame; replicated 20 Hz poses applied raw | Fixed: client renders trains from published motion samples, carries the rider by the rendered delta, volume from builder attributes |
| 5 | Crew board prompt rarely appears | Roblox only shows a prompt whose anchor is on screen; the prompt sat at the centre of a 9-stud-tall board, above the eye line at reach | Fixed: tall lobby fixtures host prompts on an eye-level attachment |
| 6 | Station stop is instantaneous | Stop distance was a hard clamp | Fixed: train protection holds a braking curve and cuts traction; measured a smooth 92 to 0 studs/s over the last ~700 studs |
| 7 | Driver cannot see out | Blunt nose was a full-height slab in front of the windscreen; panes built edge-on; camera kept its heading when seated | Fixed: noses stay below the sill, panes face forward at the seated eye line, view turns forward on sitting, headlamps remounted on the nose |
| 8 | Wipers never move | Nothing animates them | Open (arms are now articulated; animation not written) |
| 9 | Sleepers in saturated colours | Per-channel colour jitter | Fixed: weathering varies brightness, not hue |
| 10 | HUD labels over their bars; speed unit wrong | UI layout | Open |
| 11 | Departure was a teleport | No boarding existed | Fixed: Platform 1 with the 02:17 waiting; walk aboard; doors close; yard pilot drives out; cinematic films the real train; tunnel; crew crosses to the expedition train in the dark |
| 12 | Nobody could enter a carriage or the cab | Carriage and locomotive sides were single solid parts with doors and windows drawn on | Fixed: walls built around real door and window openings; locomotive gets an engine-room side corridor and rear gangway |
| 13 | Menu buttons cannot be clicked with a mouse | First-person camera locks the cursor to the screen centre; every click hit the backdrop and closed the panel | Fixed: modal backdrop frees the cursor; cab panel gets hold-Alt cursor and keys for every control (R reverser, T start) |
| 14 | Yard nearly black from the spawn | Low exposure, no atmosphere, weak lamps | Improved: exposure, moonlit ambient, Atmosphere, bloom, grade, brighter platform lamps |
| 15 | Crew left behind or in the wrong carriage at the tunnel crossing | Server-only move lost after leaving a seat; then the client held a fixed world point while the train rolled on | Fix written (client tracks the moving train until it streams in; server re-checks "inside the train"); **not yet re-tested** |

## Verified by play (Studio)

* Spawn faces Platform 1; walk up the ramp onto the platform.
* E at the DEPART post opens the crew panel; a mouse click on "Depart alone" starts the countdown.
* Boarding panel and BOARD HERE marker; walk through the carriage doorway with W into a seat bay.
* Departure cinematic films the train leaving; tunnel fade; arrival on the line aboard the expedition train.
* Driving to Marrow Halt with protection braking.
* Developer-assisted, not player input: placing the character at the DEPART post and in front of the door, and seating it in the driver's seat.

## Next action

1. Re-test the tunnel crossing (defect 15).
2. Walk from the carriages through the engine-room corridor to the cab.
3. Play every station to the ending, including failure and retry.
4. Then audio, the visual pass, horror events, premium weapons and armory, repeat-journey mode, performance, and the final report.
