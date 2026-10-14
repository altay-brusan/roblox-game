# Trains and the workshop

Seven trains. None makes the line safe, and the story can be finished with
the free Warden. Handling numbers multiply `Balance.Train`.

| Train | How you get it | Body | Speed | Fuel use | Damage taken | Storage | Weakness |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Warden | starter | front cab, 2 carriages | 1.0 | 1.0 | 1.0 | +0 | none in particular |
| Packhorse | 2,600 RIP Coin, level 10 | centre cab, 3 vehicles | 0.82 | 1.18 | /1.25 | +8 | slow, thirsty |
| Kestrel | 4,400 RIP Coin, level 18 | raked nose, 1 carriage | 1.34 | 0.88 | /0.7 | -4 | fragile, small |
| Bulwark | 6,600 RIP Coin, level 26 | armoured, 3 vehicles | 0.9 | 1.4 | /1.7 | +2 | very thirsty |
| Phantom Express | Game Pass, 299 R$ (suggested) | raked, observation car | 1.22 | 0.85 | /0.8 | -2 | fragile, small |
| Eclipse Engine | Game Pass, 399 R$ (suggested) | centre cab, workshop car | 1.08 | 0.9 | /1.15 | +3 | slow to accelerate (0.8) |
| Warden's Convoy | Game Pass, 499 R$ (suggested) | armoured, 4 vehicles | 0.84 | 1.3 | /1.5 | +6 | slow, thirsty, long |

Each premium train comes with its own livery (Phantom Grey, Eclipse Black,
Convoy Olive). Pass ids are 0 in `Config/Monetization.luau` until the passes
are created on the Roblox site. Earned trains are bought at the Phantom
Exchange. The loadout panel says where each locked train comes from.

## Workshop upgrades

Salvage still carried when a run ends (fuses, relays, batteries, hydraulic
valves, radio parts) becomes workshop parts, up to six a run, shown on the
results screen. Parts plus RIP Coin buy permanent upgrades in the loadout
panel's Workshop section. None is sold for Robux.

| Upgrade | Cost | Effect |
| --- | --- | --- |
| Reinforced bodywork | 4 parts + 120 | the run's train takes 20% less damage |
| Fuel economiser | 4 parts + 120 | the run's train burns 12% less fuel |
| Extra racks | 3 parts + 80 | +2 inventory slots on any train |
| Signal antenna | 5 parts + 150 | analyzer bearings 4 degrees sharper |

Train upgrades are the crew leader's, fitted to the train for that run.

## Fix found while testing

After a run the lobby spawn sits inside a long yard train's footprint, so
the yard believed someone was aboard and never rebuilt it as the chosen
train: everyone rode the Warden after their first run. A crew's own members
no longer count; they are stepped onto the platform and the train rebuilt.

## Tested in Studio

* All seven trains: chosen in the loadout, spawned with the right body and
  carriage count, crossed into the line, boarded, driven 400 studs.
* Bench: buy succeeds with parts and coin; refused without parts, without
  coin, when owned, and for an unknown id. Extra racks gives 20 slots on the
  Warden (18 + 2).

Not tested: parts awarded at the end of a real run; the damage and fuel
upgrades in a run (code only); real pass purchase (needs ids). Studio
hooks: `TestAllTrains` (any train selectable), `TestParts` (adds parts once).
