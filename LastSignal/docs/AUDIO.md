# Audio

Every cue, what has audio, and how to fill in the rest.

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

## Current state: 57 of 83 cues have audio

Every ID that is filled in was obtained the same way, twice verified:

1. Searched the Roblox toolbox audio endpoint filtered to `creatorTargetId=1`,
   which returns only assets created by Roblox itself.
2. Confirmed through `economy.roblox.com/v2/assets/<id>/details` that the
   creator really is `Roblox` and the asset type really is Audio.

Roblox-created audio is free to use in any experience, so these carry no
licensing risk and need no permission.

**26 cues are still silent, and cannot be filled from that library.** The
entire Roblox-created audio collection is 129 assets, most of them pinball
sounds and interface clicks. It contains no diesel engine, no train horn, no
brake squeal, no wind, no radio static, no heartbeat, no firearms and no horror
music. Substituting what is there would be actively wrong: "Cannon_Explode" is
not a door opening, and shipping that is worse than silence.

A cue with `id = 0` plays nothing, logs once at debug level, and returns.
**The subtitle still fires**, so a player with subtitles enabled gets the
complete informational content of the game regardless.

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

Of the 26 that are still silent, these four matter most, in this order:

1. **A diesel engine idle and load loop.** The train is the centrepiece and it
   currently runs on a machinery loop.
2. **A train horn.** It is also the creature repel tool, so it is gameplay, not
   just atmosphere. Currently a low whistle.
3. **Brake squeal.** Emergency braking is a major beat with no sound.
4. **`radio_distort`.** One of the four tells that separates the dispatcher
   from what imitates him.

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
[LAST SIGNAL][Boot] Audio: 57 of 83 cues configured.
```

`Audio.audit()` returns the same numbers if you want them in code.
`Audio.informationalCues()` returns the list of cues that carry information,
which is the set worth prioritising.

---

## The 26 cues that are still silent

These have no suitable Roblox-created source. Filling them needs audio you own,
uploaded to your own account.

**Train (7).** `train_brake_apply`, `train_brake_emergency`, `train_wiper`,
`train_stall`, `train_engine_idle` and `train_engine_load` currently use
machinery loops rather than a diesel engine, and `train_horn` uses a low
whistle. Replacing those four with real locomotive audio is the single largest
improvement available to this game.

**Ambience (4).** `wind_forest`, `forest_night`, `station_hum`, `rain_on_roof`
(currently the outdoor rain bed).

**Player (3).** `heartbeat`, `revive`, `item_bandage`.

**Radio (3).** `radio_static`, `radio_distort`, `radio_tune`. The distortion
sting is one of the tells that separates the dispatcher from what imitates him,
so this one matters more than its size suggests.

**Weapons (7).** `gun_revolver`, `gun_shotgun`, `gun_rifle`, `reload_revolver`,
`reload_shotgun_shell`, `reload_bolt`, `repair_wrench`.

**Creature and music (2).** `creature_mimic`, and the `music_departure`,
`music_tension`, `music_climax`, `music_resolution` beds currently fall back to
two generic loops.

Where a cue is reused rather than empty, the mixer differentiates it by pitch
and volume, which is a legitimate technique but no substitute for the real
sound.
