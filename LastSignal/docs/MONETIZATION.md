# Monetization

Everything you need to turn Robux on, and the reasoning behind what is sold.

---

## The state it ships in

Every product in `src/shared/Config/Monetization.luau` has `id = 0`.

Zero means **not configured**. The shop renders the item as Unavailable with a
disabled button, `PurchaseService.prompt` refuses to open a prompt, and
`Monetization.byId` will not match a receipt to it. No code path anywhere in
this project simulates a purchase, grants something for free, or displays a
made-up price.

The boot log tells you the count at every startup:

```
[LAST SIGNAL][Boot] Monetization: 0 of 12 products configured. The shop will show
[LAST SIGNAL][Boot]   every item as Unavailable and no purchase can be made.
```

---

## Before anything else: where the money goes

Robux from a Game Pass or a Developer Product is paid to **the owner of the
experience those products belong to**. If you publish under your own account,
you are paid. If you publish to a group, the group's funds are credited and
payouts follow the group's configuration.

The string `RIPGAMES` in this code directs nothing. Neither does the list of
usernames in `Admin.luau`. Ownership is decided entirely by which account or
group you publish the place under.

Read [OWNERSHIP.md](OWNERSHIP.md) before you publish, not after.

---

## What is sold, and the rules it follows

Three constraints are enforced by the design, not just intended:

**Nothing paid grants combat power.** No product sells damage, health,
ammunition capacity, threat suppression, or creature resistance. The one
capacity product raises how much loot a crew can carry, which changes the
logistics of a run and not the outcome of a fight. `Monetization.NoCombatAdvantage`
is set to `true` as a standing note to whoever edits this file next.

**The free game is complete.** The starter train finishes the chapter. Every
cosmetic category has credit-purchasable entries. Every piece of counterplay
against the creature is free and available on the first run.

**Nothing is sold into a bad moment.** `ShopService` refuses to open a Robux
prompt while the player is in any state listed in
`Monetization.PromptBlockedStates`: a cinematic, an encounter, a critical
rescue, the expedition climax, or loading. The one exception is the emergency
stimulant, which is only ever offered while you are actually down, and never
while a teammate is already reviving you.

---

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
| Nightwatch Carbine | `pass_nightwatch_carbine` | The carbine: 10-round magazine, light recoil, 20 damage, fastest drive-off | Loud (threat per shot), uses scarce rifle rounds, 20 to start each run, cannot kill the Signal-Eater | 149 | 0 | not created | Primary slot; one primary per run | Simulated ownership in Studio: equip, fire rate, ammo, reload |
| Arc Rail Projector | `pass_arc_projector` | The projector: 0.9 s charge, 26-stud cone, stuns the Signal-Eater, no ammunition | Heat 40 per burst, overheats after three quick bursts (7 s lockout); stuns halve within 30 s and cannot be chained | 249 | 0 | not created | Primary slot | Simulated: charge enforcement, heat, overheat; stun maths unit-tested; stun on a live creature untested |
| Signal Flare Launcher | `pass_flare_launcher` | Airburst flares that hang 20 s, light the ground about 85 studs around, reveal the Signal-Eater to the crew, draw it to the flare, deny the ground beneath | No damage; 6 flares a run plus found flare shells; light gives away your position | 99 | 0 | not created | Primary slot | Simulated: fire, landing, burst, light, ammo; reveal and distract on a live creature untested |
| Conductor Collection | `pass_conductor` | Conductor finish (black enamel and brass on every weapon), Conductor's Lamp (hip lantern, warm beam), Conductor's Badge (plate above head, crew board mark) | Appearance only | 129 | 0 | not created | Finish, lamp and patch slots; "Wear the collection" sets all three | Simulated: all three render |
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
repel it. No story step needs a weapon, and the full five-station run was
completed with no purchase. Premium weapons do not change creature difficulty, and none kills it.

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

The prices above are the `suggestedPrice` field in the config. **That field is
never shown to a player.** The shop always displays the live price fetched from
`MarketplaceService:GetProductInfo`, so what a player sees is always what
Roblox will actually charge. You can price these however you like without
touching the code.

---

## RIP Coin: the earned currency

RIP Coin is the free currency, earned only by playing and spent at the
Phantom Exchange. Internally the field is still called `credits`; every word
a player reads says RIP Coin. Robux never becomes RIP Coin except through the
three clearly labelled Robux packs, and no RIP Coin price is shown as Robux.

Rates (2026-10-14, after scaling every amount by 0.4 to V2 §17's targets;
initial proposals to tune by playtest, not final):

| Source | RIP Coin | V2 target |
| --- | ---: | --- |
| Station cleared | 50 | major station goal 35 to 75 |
| Optional objective | 25 | |
| Journey completed | 160 (40% of it on a failed run) | 100 to 200 |
| Night run bonus | 120 / 240 / 400 by tier | |
| Discovery (first time) | 25 | 20 to 60 |
| Inspection signed (night run) | 60, once per station per run | |
| Daily login | 40 to 280 over seven days | |
| Playtime reward | 35 every 15 minutes, 6 a day | |
| Verified signal call | not yet (needs the SIA, task 14) | 10 to 25 |

Ledger rules: every award and spend goes through ProgressionService on the
server; purchases are validated server-side (ownership, level, balance) and
refunded if the grant fails; journey rewards are recorded by run GUID so a run
is paid once; a retry cannot pay an inspection twice. Starting balance 140.

Not sold for RIP Coin: starting-kit weapons (everyone has them) and outfits
(not drawn on characters yet).

## The Phantom Exchange

The shop is the Phantom Exchange: a ticket machine at the hatch of the yard's
old stores hut, with a green screen and an intercom. Nobody stands behind the
counter. A voice, the Broker, answers in the radio subtitles when the Exchange
opens, after a RIP Coin purchase, when a player is short, when a Robux prompt
opens, and when purchases are paused. Text only; no recorded voice exists yet.
Purchases are paused during dangerous moments (Monetization.PromptBlockedStates)
and a prompt only ever follows the player pressing Buy. The armory, beside it,
is where weapons are inspected and equipped.

## Where each ID goes

One file, one field each: `src/shared/Config/Monetization.luau`.

```lua
{
    key = "vip_crew",
    kind = "gamepass",
    id = 0,                    -- <-- paste the Game Pass ID here
    name = "Signalman's Pass",
    ...
}
```

To find a Game Pass ID: open the pass on the Roblox website. The URL is
`roblox.com/game-pass/`**`123456789`**`/name`. The number is the ID.

To find a Developer Product ID: in Creator Hub, open your experience, go to
**Associated Items, Developer Products**, and the ID is listed beside each
product. It is not the same as a Game Pass ID and the two are not
interchangeable; `PurchaseService` matches on both kind and ID.

After pasting them in, rebuild (`bash scripts/build.sh`) or let the Rojo plugin
sync, then restart the server. The boot log will confirm the new count.

---

## Purchase handling, and why it is safe

`src/server/Services/PurchaseService.luau` is the only file in the project that
touches MarketplaceService. Four failure modes are handled explicitly.

**Double-granting.** `ProcessReceipt` can fire more than once for the same
`PurchaseId`, across servers and across rejoins. Every receipt ID is written
into the profile before the grant is acknowledged. A receipt already present is
acknowledged without granting again.

**Losing a purchase.** Returning `PurchaseGranted` tells Roblox the player got
their goods. This service only ever returns that after the receipt has been
persisted. If the write fails, if the profile is not loaded, if the session is
read-only, or if the player has already left, it returns `NotProcessedYet` and
Roblox re-delivers later, including on the player's next join.

**An unrecognised product.** If a receipt arrives for a product ID that is not
in this config, the service refuses to acknowledge it and logs loudly. That is
deliberate: acknowledging would take the player's Robux and give nothing. Add
the product to the config and the purchase is delivered automatically on the
next retry.

**A receipt arriving at the wrong moment.** The self-revive is the only
consumable with timing sensitivity. If it completes after the player has
already been revived or the run has ended, the entitlement is banked on their
vitals and used the next time they go down. It is never silently dropped.

Purchase records are also protected from everything else in the system. The
owner-only data reset preserves them. The save path unions receipts rather than
replacing them, so a receipt processed on another server between load and save
cannot be lost.

---

## Credits, the free currency

Credits are earned from objectives, stations, rescues, discoveries, daily
login, playtime and quests. Everything in the `exchange` shop category is
bought with them: two liveries, one interior kit, two lamps, one outfit, the
axe, the shotgun and the rifle, and the three non-starter trains.

Three Robux products sell credits directly. They are priced so the largest is
the best value per credit, which is conventional and which players read as
fair.

Credit rewards from quests, achievements, daily login and purchased packs are
granted with `exact = true`, which bypasses the paid multipliers. A pass that
multiplied a fixed daily reward would make the pass feel mandatory for routine
play, which is the opposite of the intent.

---

## Analytics for monetization

`AnalyticsService` records the funnel and computes six rates. The two worth
acting on:

- `prompt_rate` = prompts shown ÷ shop opens. Low means the shop is not
  convincing anybody to try.
- `conversion_rate` = purchases ÷ prompts shown. Low means the price or the
  value is wrong.

A rate whose denominator is zero is reported as `nil`, not as zero, because
"no data" and "nobody bought anything" are different answers.

Read them with the `world` admin command, or from the `LastSignal_Analytics_v1`
DataStore, keyed by UTC date.

The counters are real measurements from events this project actually fires.
Nothing is modelled or estimated. There are no invented figures anywhere in
this project, and no projections of revenue: how a game performs commercially
depends on discovery, competition, timing and audience, none of which can be
predicted from the code.

---

## A short list of things not to do

- Do not sell damage, health, ammunition, or anything that makes the creature
  easier to survive. It breaks the free experience and it is the fastest way to
  lose the trust the rest of this design is built on.
- Do not add a purchase prompt to the death screen or the results screen.
- Do not sell streak protection. The streak system is deliberately forgiving so
  that there is nothing to protect.
- Do not put a purchasable metric on a leaderboard.
