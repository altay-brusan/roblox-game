## The products to create

Every ID below is `0` in `src/shared/Config/Monetization.luau`. **None of
these exists on Roblox yet**: an `.rbxlx` cannot create a pass. Until an ID is
filled in, the shop and the armory show the item as "Not available yet", with
no buy button, and nothing can be bought or granted.

**The missing external action:** in the Creator Dashboard, under *Creations,
your experience, Associated Items*, create each pass and product below, set its
price, and paste its numeric ID into the matching `id` field.

Prices are proposals (`suggestedPrice`). Players always see the live price
from `MarketplaceService:GetProductInfo`, and the sale state (`IsForSale`).

### Game Passes (13): permanent unlocks

| Item | Key | Permanent benefit | Limitations | Proposed price | Pass ID | Live sale state | Ownership and equip rules | Verification |
| --- | --- | --- | --- | ---: | --- | --- | --- | --- |
| Nightwatch Carbine | `pass_nightwatch_carbine` | The carbine: 10-round magazine, light recoil, 20 damage, fastest drive-off | Loud (threat per shot), uses scarce rifle rounds, 20 to start each run, cannot kill the Signal-Eater | 449 | 0 | not created | Primary slot; one primary per run | Simulated ownership in Studio: equip, fire rate, ammo, reload |
| Arc Rail Projector | `pass_arc_projector` | The projector: 0.9 s charge, 26-stud cone, stuns the Signal-Eater, no ammunition | Heat 40 per burst, overheats after three quick bursts (7 s lockout); stuns halve within 30 s and cannot be chained | 449 | 0 | not created | Primary slot | Simulated: charge enforcement, heat, overheat; stun maths unit-tested; stun on a live creature untested |
| Signal Flare Launcher | `pass_flare_launcher` | Airburst flares that hang 20 s, light the ground about 85 studs around, reveal the Signal-Eater to the crew, draw it to the flare, deny the ground beneath | No damage; 6 flares a run plus found flare shells; light gives away your position | 299 | 0 | not created | Primary slot | Simulated: fire, landing, burst, light, ammo; reveal and distract on a live creature untested |
| Conductor Collection | `pass_conductor` | Conductor finish (black enamel and brass on every weapon), Conductor's Lamp (hip lantern, warm beam), Conductor's Badge (plate above head, crew board mark) | Appearance only | 199 | 0 | not created | Finish, lamp and patch slots; "Wear the collection" sets all three | Simulated: all three render |
| Signalman's Pass | `vip_crew` | +25% credits and XP, Signalman lamp and patch, second daily quest slot | | 399 | 0 | not created | | Not re-tested this pass |
| Cargo Rigging | `cargo_rig` | +6 slots, +18 kg, shared with the crew | | 249 | 0 | not created | | Not re-tested this pass |
| Workshop Access | `workshop_access` | Three interior kits | | 199 | 0 | not created | Interior slot | Not re-tested this pass |
| Livery: Ember Line / Permafrost / Night Post | `livery_*` | One livery each | | 149 / 149 / 199 | 0 | not created | Livery slot | Not re-tested this pass |
| Lamp Collection | `lantern_kit` | Four lamps (lantern and beam colour) | | 129 | 0 | not created | Lamp slot | Lamp rendering verified with the Conductor lamp |
| Equipment Finishes | `tool_finishes` | Three weapon finishes | | 99 | 0 | not created | Finish slot | Finish rendering verified with the Conductor finish |
| Crew Wardrobe | `crew_outfits` | Six outfits | **Off sale** (`offered = false`): outfits are not drawn on characters yet | 179 | 0 | hidden | | Hidden in shop: verified |

Changed on 2026-10-14: the liveries, lamp kit, finishes and wardrobe were
Developer Products and are now Game Passes, because they are permanent unlocks.
Workshop Access no longer promises "livery mixing" and the Signalman's Pass no
longer promises a "reserved cab seat cosmetic" or a chat tag: none of those
exists.

### Developer Products (4): consumables

| Suggested name | Suggested price | Key | What it grants |
| --- | ---: | --- | --- |
| Emergency Stimulant | 20 | `field_revive` | One self-revive at 40% health |
| Supply Voucher | 99 | `credits_small` | 1,000 credits |
| Depot Requisition | 449 | `credits_medium` | 5,500 credits |
| Regional Stockpile | 999 | `credits_large` | 14,000 credits |

### Free kit beside the premium weapons

Wrench, crowbar, revolver and flare pistol are owned by everyone. The flare
pistol denies ground to the Signal-Eater; the train horn and a lit carriage
repel it. The whole story can be finished with these (task 3 full run used the
free kit). Premium weapons do not change creature difficulty, and none kills it.

### Ownership and purchase flow

* Ownership is asked of Roblox with `UserOwnsGamePassAsync` on join and after
  every `PromptGamePassPurchaseFinished`, then mirrored into the profile.
  Failed checks retry after 2, 5 and 12 s; after that the armory says it could
  not confirm and offers "Check again" (rate limited to once per 15 s).
* A weapon is equipped only if the server's profile owns it (LoadoutService and
  CombatService.equip). A client asking for a locked weapon is refused
  (verified: `LOADOUT_NOT_OWNED`).
* One prompt at a time per player; a second press while a prompt is open is
  refused. Cancelling tells the armory, which returns to its normal state.
* The weapon survives death, retry and rejoin: ownership is permanent, the
  round's loadout is re-applied to each new character.
* Studio test hook: a server-set `SimulatePass_<key>` attribute makes a pass
  count as owned, in Studio only, and is logged as SIMULATED. Every
  verification above used it. **No live purchase has been made or tested.**

---

