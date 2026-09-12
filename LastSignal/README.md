# LAST SIGNAL

A first-person cooperative horror-survival game for Roblox.
A RIPGAMES production. Chapter One: The Long Grade.

At 02:17 the last evacuation train leaves an isolated maintenance yard. The
line runs ninety kilometres north through forest, past five stops that all need
something before the train can continue. A damaged radio offers guidance from a
dispatcher. Some of the transmissions are not the dispatcher.

**Keep the train moving. Stay together. Do not trust every voice on the radio.**

---

## What is in this repository

| Path | What it is |
| --- | --- |
| `src/shared` | Code replicated to both server and client: configuration, registries, core utilities |
| `src/server` | The authoritative game: services and world builders |
| `src/client` | Interface, camera, input, audio, viewmodels |
| `src/replicatedfirst` | The loading screen |
| `docs/` | Setup, configuration, testing, and an honest status report |
| `scripts/` | Build and verification scripts |
| `build/` | The built place file (created by `scripts/build.sh`) |
| `tools/` | Rojo and the Luau analyzer (downloaded, not committed) |

65 Luau modules, roughly 33,400 lines. Every file type-checks in strict mode
against the real Roblox API.

---

## Getting it running

Full instructions with the exact commands are in **[docs/SETUP.md](docs/SETUP.md)**.
The short version:

1. **Install Roblox Studio.** It is not currently installed on this machine.
   Download it from <https://create.roblox.com/> and sign in.
2. **Open the built place.** The file is already built at
   `build/LastSignal.rbxlx`. Double-click it, or use File, Open in Studio.
3. **Press Play.** The world builds itself at runtime: the yard first, then an
   expedition lane in the background. The first lane takes a few seconds.

You do not need Rojo to play it. You need Rojo only if you want to edit the
source files and rebuild, which is covered in the setup guide.

---

## Read this before you publish

Two things ship deliberately switched off, because this project cannot set them
correctly on your behalf. Each fails safely rather than guessing. A third,
audio, is partially filled.

**Monetization IDs are empty.** Every Game Pass and Developer Product in
`src/shared/Config/Monetization.luau` has `id = 0`. Zero means "not
configured": the shop renders the item as Unavailable, the buy button is
disabled, and no purchase can be attempted or simulated. Create the products on
your published experience and paste the numeric IDs in.
See **[docs/MONETIZATION.md](docs/MONETIZATION.md)**.

**Administrator user IDs are empty.** `src/shared/Config/Admin.luau` lists
RIPjafar1 as owner and shayanbrusan1234 as administrator, with their numeric
user IDs set to `0`. A role with ID 0 grants nothing. Look up the real numeric
IDs and paste them in. This project has no way to verify which account a
username currently belongs to, and a wrong guess would hand administrative
access to the wrong person. See **[docs/ADMIN.md](docs/ADMIN.md)**.

**Audio is 57 of 83 cues.** Every filled ID is Roblox-created audio, verified
twice against the Roblox asset API, and free to use in any experience. The
other 26 have no suitable source in that library, which contains no diesel
engine, no train horn, no wind and no horror music. Those cues stay silent
rather than playing something wrong; subtitles still carry every informational
cue. See **[docs/AUDIO.md](docs/AUDIO.md)**.

**Revenue goes to whoever owns the experience the products belong to.** The
RIPGAMES name in this code does not direct payment. See
**[docs/OWNERSHIP.md](docs/OWNERSHIP.md)**.

---

## What is verified and what is not

**[docs/CHECKLIST.md](docs/CHECKLIST.md) is the most important document here.**
It lists every requirement from the brief with an honest status, and records the
seven defects the first real run exposed.

The honest summary: every line type-checks against the real Roblox API and the
place file builds. It has been run once, by the operator, which found four
reported defects and three more behind them, including a missing cab interface
that made the game uncompletable. All seven are fixed. **It has still never
been played end to end.** Static verification catches a great deal. It does not
catch everything.

---

## The design in one page

**Structure.** A lobby yard, then five stops along a straight 14,000 stud
railway, then an ending. Twenty-five to forty minutes for a normal run.

**No two stops ask for the same verb.** Restore power, cooperate on separated
levers, relay a code by voice, repair under time pressure, then converge. The
failure mode the brief warns about is "collect four things, five times"; this
is the structural answer to it.

**The train is kinematic, not physics-driven.** It is one welded rigid assembly
on an anchored root, moved by CFrame on a fixed tick. Passengers ride by having
the train's per-frame delta applied to their own character, on their own
client, which owns their physics. That is why nobody jitters, stretches or
falls through the floor. See the comment block in `TrainRideController`.

**Threat is a meter the players drive.** Noise, distance from the train, and
time raise it; objectives and quiet lower it. The horror director schedules
against bands of that meter with cooldowns and repetition control, rather than
against a timer or a dice roll. Nothing at all schedules during the cinematic,
during loading, or inside the immunity window after a respawn.

**The creature cannot be killed.** Damage fills a drive-off meter. It will not
enter a lit carriage, the horn drives it back at close range, and a flare
denies ground. All of that counterplay is available on the first run with no
unlocks and no purchases.

**Nothing paid grants combat power.** No product in this project sells damage,
health, ammunition, or threat suppression. The one capacity product raises how
much loot a crew can carry, not how hard they hit.

---

## Building from source

```bash
bash scripts/check.sh    # sourcemap, syntax, full strict type check
bash scripts/build.sh    # writes build/LastSignal.rbxlx
```

Both scripts use the tools in `tools/bin`, which `docs/SETUP.md` explains how
to reinstall if the folder is missing.

---

## Documentation

| Document | What it covers |
| --- | --- |
| [SETUP.md](docs/SETUP.md) | Installing Studio and Rojo, opening and editing the place |
| [CHECKLIST.md](docs/CHECKLIST.md) | **Requirement-by-requirement status, and the defects found and fixed** |
| [STATUS.md](docs/STATUS.md) | Verified, unverified and incomplete work |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Explorer layout, module map, how the systems connect |
| [MONETIZATION.md](docs/MONETIZATION.md) | Creating the products, where every ID goes |
| [OWNERSHIP.md](docs/OWNERSHIP.md) | Publishing, and who actually gets paid |
| [ADMIN.md](docs/ADMIN.md) | Roles, commands, and the safety rails on them |
| [EVENTS.md](docs/EVENTS.md) | Running The Lost Conductor, and authoring the next event |
| [AUDIO.md](docs/AUDIO.md) | Every cue, and how to fill in the asset IDs |
| [ASSETS.md](docs/ASSETS.md) | The asset register, and why it contains no third-party assets |
| [TESTING.md](docs/TESTING.md) | The full acceptance checklist, with current results |
| [PERFORMANCE.md](docs/PERFORMANCE.md) | Budgets, measured part counts, and the streaming setup |
