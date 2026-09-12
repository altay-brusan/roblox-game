# Asset register

What this project uses, where it came from, and what licence applies.

---

## The short version

**This project ships no third-party assets of any kind.**

No meshes, no textures, no images, no animations, no fonts, no models from the
Toolbox, nothing from a search result. The only referenced assets are 57 audio
IDs, every one of them created by Roblox itself and verified as such; see the
Audio section below. Every object in the game
is constructed at runtime from Roblox's own primitives using materials from the
standard `Enum.Material` set.

That means the asset register below is short, and the licensing answer is
simple: everything referenced is Roblox's own, so nothing is owed in
attribution and nothing can be taken down.

---

## Why it was built this way

The brief asks for properly licensed models and an asset register with sources,
creators, licences and IDs. It also says, correctly, that appearing in a Google
search does not establish permission to reuse an asset.

This project had no way to satisfy the first requirement honestly. It cannot
buy a licence, cannot verify that a Toolbox model's uploader had the right to
upload it, and cannot attribute a creator it has no way to identify. The Roblox
Toolbox in particular is full of re-uploaded commercial assets, and a large
fraction of models there also carry scripts that should not be in your game.

So the constraint was inverted: use only what Roblox already licenses to you
as part of the platform, and build everything else.

**The trade-off is real and worth stating plainly.** Constructed geometry does
not look like sculpted meshes. The locomotive is a detailed, correctly
proportioned object built from several hundred parts with bogies, leaf springs,
axleboxes, brake shoes, louvres, grilles, buffers, drawhooks, chains and air
pipes, and it will read clearly as a diesel locomotive. It will not read as a
photoscanned one. The same applies everywhere.

What you get in exchange: no licensing risk, no attribution obligations, no
download weight, no dependency that can break, no imported scripts to audit,
and geometry that can be edited by changing a number in a builder.

---

## The register

| Asset | Source | Creator | Licence | Used in |
| --- | --- | --- | --- | --- |
| Part, WedgePart, Cylinder, Ball primitives | Roblox Studio | Roblox | Roblox Terms of Use, included with the platform | All geometry |
| `Enum.Material` surfaces (Metal, CorrodedMetal, DiamondPlate, Wood, WoodPlanks, Brick, Concrete, Slate, Grass, Ground, Fabric, Glass, Neon, Rock, Asphalt, Cardboard, Plaster, SmoothPlastic) | Roblox Studio | Roblox | Included with the platform | All surfaces |
| `Enum.Font` Gotham, GothamMedium, GothamBold, RobotoMono | Roblox Studio | Roblox | Included with the platform | All interface text |
| PointLight, SpotLight, SurfaceLight | Roblox Studio | Roblox | Included with the platform | All lighting |
| Future lighting technology, atmosphere and fog settings | Roblox Studio | Roblox | Included with the platform | Night look |

That is the complete list for geometry, type and lighting. Audio is the one
category with explicit asset IDs, covered next.

---

## Audio

**57 of 83 cues carry Roblox-created audio.** Those assets are listed in the
register above in spirit: they are all created by Roblox itself, which licenses
them for use in any experience, so no attribution is owed and none can be taken
down.

Every ID was verified twice before use: the search was filtered to
`creatorTargetId=1`, and each asset was then confirmed through the Roblox asset
details endpoint to have creator `Roblox` and asset type Audio. No ID was
guessed.

The remaining 26 cues are empty because the Roblox-created library, which is
129 assets in total, does not contain anything suitable. It has no diesel
engine, no train horn, no brake squeal, no wind, no radio static, no firearms
and no horror music. Substituting an unrelated sound would be worse than
silence.

[AUDIO.md](AUDIO.md) lists every cue with search terms and explains the
licensing rules that apply when you fill them in. The short version: audio
uploaded by Roblox itself is free for you to use in your own experiences; audio
uploaded by other users generally is not, unless its description explicitly
grants permission.

---

## Animations

None, for the same reason: a Roblox animation is an uploaded asset with an ID.

What exists instead:

- **First-person viewmodels** are built per weapon and animated with springs,
  so equipping, recoil, sway and aiming all move correctly with no asset.
- **Doors** swing on real hinges with eased tweens.
- **Cab levers, gauge needles and wiper arms** are real parts moved by the
  train service in response to real state.
- **Wheels** rotate from distance travelled, so the rotation can never drift
  out of sync with actual movement.
- **The creature** moves as a rigid body along a raycast-grounded path.

What is missing: third-person character animation. Another player holding a
rifle will hold it in Roblox's default pose rather than a shouldered one. This
is the most visible consequence of the no-assets constraint and the first thing
worth adding once you have an animator.

---

## Adding real assets later

The code is structured so that replacing constructed geometry with meshes does
not touch gameplay.

**Items.** `ItemRegistry` gives each item a `model` block describing a shape,
size, colour and material. `WorldService.buildDroppedItem` reads it. To use a
mesh instead, add a `meshId` field and one branch in that function. Nothing
else changes; the inventory, the loot tables and the interaction system all
work on item IDs.

**Weapons.** `WeaponRegistry` has the same arrangement with a `model` block,
read by `WeaponController.buildViewmodel`. The weapon's behaviour, validation
and balance are entirely separate from its appearance.

**The train.** `TrainBuilder` builds from the `build` block in
`TrainRegistry`. It is the largest builder and the most work to replace, but
`TrainService` only ever touches the named references the builder returns
(`cab.throttleLever`, `headlights`, `doors`, `wheels`, and so on). A mesh train
that returns the same reference table drops straight in.

**Stations.** `StationBuilder` dispatches on a `kind` string per building. Add
a branch, keep the fixture and loot node positions from `StationRegistry`, and
the objectives keep working.

If you do import assets, the rules that made this register short still apply:
know who made it, know what licence it carries, write it down in this file, and
delete every script inside an imported model before you use it.
