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

### Game Passes (3)

Create these under **Creations, your experience, Associated Items, Passes**.

| Suggested name | Suggested price | Key in `Monetization.luau` | What it grants |
| --- | ---: | --- | --- |
| Signalman's Pass | 399 | `vip_crew` | +25% credits and XP, a lamp and patch, a second daily quest slot, a chat tag |
| Cargo Rigging | 249 | `cargo_rig` | +6 inventory slots and +18 kg carry weight, shared with the whole crew |
| Workshop Access | 199 | `workshop_access` | The lobby workshop bench plus three interior kits |

### Developer Products (9)

Create these under **Creations, your experience, Associated Items, Developer
Products**.

| Suggested name | Suggested price | Key | What it grants |
| --- | ---: | --- | --- |
| Emergency Stimulant | 20 | `field_revive` | One self-revive at 40% health |
| Supply Voucher | 99 | `credits_small` | 1,000 credits |
| Depot Requisition | 449 | `credits_medium` | 5,500 credits |
| Regional Stockpile | 999 | `credits_large` | 14,000 credits |
| Livery: Ember Line | 149 | `livery_ember` | Permanent livery |
| Livery: Permafrost | 149 | `livery_permafrost` | Permanent livery |
| Livery: Night Post | 199 | `livery_nightpost` | Permanent livery |
| Lamp Collection | 129 | `lantern_kit` | Four lamp cosmetics |
| Crew Wardrobe | 179 | `crew_outfits` | Six outfits |
| Equipment Finishes | 99 | `tool_finishes` | Three tool finishes |

The prices above are the `suggestedPrice` field in the config. **That field is
never shown to a player.** The shop always displays the live price fetched from
`MarketplaceService:GetProductInfo`, so what a player sees is always what
Roblox will actually charge. You can price these however you like without
touching the code.

---

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
