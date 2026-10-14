--!strict
--[[
	UpgradeRegistry
	---------------
	Workshop upgrades: what salvage from the line is for.

	Salvage items still carried when a run ends (fuses, relays, batteries,
	valves, radio parts) become workshop parts, one each, up to six a run.
	Parts plus RIP Coin buy upgrades at the workshop bench. Upgrades and parts
	are permanent; everything else in the inventory is for one run only.

	Train upgrades belong to the crew member who leads the run and apply to
	whichever train they take. None is sold for Robux.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

export type Upgrade = {
	id: string,
	name: string,
	description: string,
	parts: number,
	coin: number,
	-- Multipliers on the train's handling (TrainRegistry), when applicable.
	damageResistance: number?,
	fuelUseMultiplier: number?,
	-- Personal effects.
	inventorySlots: number?,
	analyzerNoise: number?,
}

local UPGRADES: { Upgrade } = {
	{
		id = "reinforced_body",
		name = "Reinforced bodywork",
		description = "Plated panels on the locomotive and carriages: the train takes 20% less damage.",
		parts = 4,
		coin = 120,
		damageResistance = 1.2,
	},
	{
		id = "fuel_economiser",
		name = "Fuel economiser",
		description = "A rebuilt injector pump: the train burns 12% less fuel.",
		parts = 4,
		coin = 120,
		fuelUseMultiplier = 0.88,
	},
	{
		id = "extra_racks",
		name = "Extra racks",
		description = "A rack you fit to whatever train you ride: two more inventory slots, every run.",
		parts = 3,
		coin = 80,
		inventorySlots = 2,
	},
	{
		id = "signal_antenna",
		name = "Signal antenna",
		description = "A roof antenna for the analyzer: bearings are four degrees sharper.",
		parts = 5,
		coin = 150,
		analyzerNoise = 4,
	},
}

-- Items that become parts when carried home.
local SALVAGE = { "fusebox_fuse", "relay", "battery", "hydraulic_valve", "radio_part" }

local UpgradeRegistry = {}

UpgradeRegistry.All = TableUtil.deepFreeze(UPGRADES) :: { Upgrade }
UpgradeRegistry.Salvage = TableUtil.deepFreeze(SALVAGE) :: { string }
UpgradeRegistry.maxPartsPerRun = 6

function UpgradeRegistry.get(id: string): Upgrade?
	for _, u in UPGRADES do
		if u.id == id then
			return u
		end
	end
	return nil
end

return UpgradeRegistry
