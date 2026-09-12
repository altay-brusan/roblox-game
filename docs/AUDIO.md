# Audio

Every cue, why they ship empty, and how to fill them in.

---

## What is already working

The entire audio system is implemented and running. What it lacks is sound
files.

- **Eight mixer buses** with independent player-facing volume sliders: master,
  music, ambience, effects, train, radio and voice, interface, threat.
- **Ducking.** Radio lines drop music, ambience and train audio so dialogue is
  always intelligible. Creature audio ducks music harder and recovers slower.
- **Distance attenuation** with per-cue minimum and maximum roll-off, so a horn
  carries 1,400 studs and a footstep carries 60.
- **Enclosure filtering.** Being inside the train or a building applies a
  low-pass to the outside world, springing in and out rather than switching.
- **Speed-reactive layering.** The engine crossfades between idle and load
  layers on throttle, and both pitch with engine speed. Wheel roll pitches and
  swells with train speed. Brake squeal appears above walking pace.
- **Per-play pitch variance** so a repeated footstep or impact does not
  machine-gun.
- **The full subtitle system**, including attribution.
- **Directional indicators**, an accessibility option that draws an on-screen
  arrow towards an important sound.

Every one of those runs whether or not any asset ID is filled in.

---

## Why the IDs are empty

A Roblox sound is an asset ID on Roblox's servers. This project cannot create,
upload or verify one.

Shipping guessed numeric IDs would be worse than shipping none. A wrong ID is
either silence, an error in the output, or somebody else's audio playing in
your game without their permission. So every cue has `id = 0`, which
`AudioController` treats as "not configured": it plays nothing, logs once at
debug level, and returns.

Critically, **the subtitle still fires**. A player with subtitles enabled gets
the complete informational content of the game with no audio configured at all.
That is what makes filling these in an improvement rather than a prerequisite.

---

## Licensing, before you start

**Audio uploaded by Roblox** is free to use in your own experiences. In the
Studio Toolbox audio browser, filter the creator to Roblox. This is the safe
default and it covers most of what this game needs.

**Audio uploaded by other users** generally is not yours to use, even though
Studio will happily let you paste the ID. Some creators explicitly grant
permission in the asset description; most do not. If the description does not
say you may use it, assume you may not.

**Audio you upload yourself** is fine, provided you have the rights to it.
Recording a diesel engine yourself, or buying a commercial sound library with a
game-use licence, both work. Pulling a sound off a video site does not.

When you add IDs, record what you used and where it came from in
[ASSETS.md](ASSETS.md). That file currently says this project has no
third-party assets; once you add audio, that stops being true and the register
should say so.

---

## How to fill one in

1. In Studio, open **View, Toolbox**, then the **Audio** tab.
2. Set the creator filter to **Roblox**.
3. Search for the cue's terms from the table below.
4. Click a result to preview it.
5. Right-click, **Copy Asset ID**.
6. Paste it into the `id` field for that cue in
   `src/shared/Config/Audio.luau`.

```lua
train_horn = cue({
    id = 0,                    -- <-- paste here
    bus = "train",
    volume = 1.0,
    ...
}),
```

7. Rebuild, or let the Rojo plugin sync. The boot log reports the new count.

---

## Priority order

There are 78 cues. You do not need all of them, and some matter far more than
others. Fill them in this order.

### Tier 1: without these the game is not frightening (12 cues)

| Cue | Search for |
| --- | --- |
| `creature_distant` | distant animal call, monster roar far, eerie howl |
| `creature_near` | creature growl, monster breathing |
| `creature_chase` | monster chase loop, pursuit horror loop |
| `creature_attack` | monster attack, creature strike |
| `footsteps_outside` | gravel footsteps, walking on gravel |
| `train_engine_idle` | diesel engine idle loop |
| `train_engine_load` | diesel engine load, engine revving loop |
| `train_wheels_roll` | train wheels loop, rail rolling |
| `train_horn` | train horn, air horn |
| `radio_static` | radio static loop |
| `rain_light` | light rain loop |
| `wind_forest` | wind trees loop |

### Tier 2: the game feels unfinished without these (14 cues)

`train_brake_apply`, `train_brake_emergency`, `train_door`, `train_stall`,
`footstep_metal`, `footstep_gravel`, `footstep_wood`, `hurt`, `downed`,
`item_pickup`, `generator_start`, `breaker_throw`, `ui_click`, `ui_open`

### Tier 3: weapons (10 cues)

`gun_revolver`, `gun_shotgun`, `gun_rifle`, `gun_dry`, `reload_revolver`,
`reload_shotgun_shell`, `reload_bolt`, `melee_swing`, `melee_hit_flesh`,
`bullet_impact`

### Tier 4: everything else

Music beds, remaining ambience, remaining interface cues, the remaining item
and machinery sounds. All listed in `Audio.Cues` with a `description` field
explaining what each one is for and when it plays.

---

## Cues that must not be left empty if you use subtitles off

These carry information a player needs, and they are the ones with a
`subtitle` field:

`train_brake_emergency`, `train_horn`, `train_stall`, `thunder_distant`,
`downed`, `gun_revolver`, `gun_shotgun`, `gun_rifle`, `radio_distort`,
`creature_distant`, `creature_near`, `creature_chase`, `creature_attack`,
`creature_repelled`, `creature_mimic`, `footsteps_outside`, `generator_start`,
`ui_objective`

A player with subtitles on is fine either way. A player with subtitles off and
these cues empty is missing information, which is why subtitles default to on.

---

## The mimicry tell

`creature_mimic` is routed on the `creature` bus rather than the `voice` bus,
deliberately. That routing is one of the four consistent tells that separate
the dispatcher from what is imitating him, because the creature bus ducks music
differently and carries a faint doubled quality once both are populated.

If you fill in `creature_mimic`, pick something that is recognisably a version
of a sound the player already knows, not a distinct new noise. The horror is in
the resemblance.

The other three tells are in the writing rather than the audio: the dispatcher
always opens with a callsign and the other voice never does, the other voice
uses the player's username, and the other voice always asks the crew to split
up or open the train. Those work with no audio at all.

---

## Checking your work

The boot log reports the count every startup:

```
[LAST SIGNAL][Boot] Audio: 26 of 78 cues configured.
```

`Audio.audit()` returns the same numbers if you want them in code.
`Audio.informationalCues()` returns the list of cues that carry information,
which is the set worth prioritising.
