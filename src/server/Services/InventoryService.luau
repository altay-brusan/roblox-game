--!strict
--[[
	InventoryService
	----------------
	Server-authoritative inventory: what each player is carrying, what it
	weighs, and every way an item can move.

	Inventories are per-expedition, not persistent. Nothing a player picks up
	in the forest follows them home, which is what keeps the survival pressure
	real and removes the entire class of duplication exploits that persistent
	loot inventories attract.

	Every operation validates on the server: the item exists, the player has
	it, the quantity is sane, the capacity allows it, the target is in range,
	and the player is alive. The client sends intent; it never sends outcomes.

	CAPACITY
	--------
	Two limits apply at once. Slots keep the grid readable; weight is the limit
	that actually forces choices. Cargo Rigging raises both, and is the only
	purchase in the project that touches either, which is why it is priced as
	convenience rather than power.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local GameConfig = require(Shared.Config.GameConfig)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local ItemRegistry = require(Shared.Registry.ItemRegistry)
local Monetization = require(Shared.Config.Monetization)
local TrainRegistry = require(Shared.Registry.TrainRegistry)
local DataService = require(script.Parent.DataService)

local log = Logger.new("InventoryService")

local InventoryService = {}

export type Stack = { id: string, quantity: number }

export type Inventory = {
	userId: number,
	stacks: { Stack },
	quickSlots: { string? }, -- item ids assigned to the five quick slots
	slotLimit: number,
	weightLimit: number,
}

local inventories: { [number]: Inventory } = {}

InventoryService.Changed = Signal.new() :: Signal.Signal<Player, Inventory>
InventoryService.ItemUsed = Signal.new() :: Signal.Signal<Player, string, ItemRegistry.ItemDef>
InventoryService.ItemCollected = Signal.new() :: Signal.Signal<Player, string, number>

--------------------------------------------------------------------------
-- Capacity
--------------------------------------------------------------------------

--- Resolves a player's limits from their base values, their train, and any
--- owned capacity product. Crew-shared bonuses are applied by the expedition,
--- which passes the crew's best bonus in.
function InventoryService.limitsFor(player: Player, trainId: string?, crewBonusSlots: number?, crewBonusWeight: number?): (number, number)
	local slots = Balance.Player.baseInventorySlots
	local weight = Balance.Player.baseCarryWeight

	local profile = DataService.getProfile(player)
	if profile then
		for productKey, count in profile.purchases.products do
			if count > 0 then
				local def = Monetization.get(productKey)
				if def and def.id > 0 then
					if type(def.grants.inventorySlots) == "number" then
						slots += def.grants.inventorySlots
					end
					if type(def.grants.carryWeight) == "number" then
						weight += def.grants.carryWeight
					end
				end
			end
		end
	end

	if trainId then
		local trainDef = TrainRegistry.get(trainId)
		if trainDef then
			slots += trainDef.handling.inventoryBonusSlots
		end
	end

	slots += crewBonusSlots or 0
	weight += crewBonusWeight or 0

	return math.max(4, slots), math.max(10, weight)
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function InventoryService.create(player: Player, trainId: string?, crewBonusSlots: number?, crewBonusWeight: number?): Inventory
	local slots, weight = InventoryService.limitsFor(player, trainId, crewBonusSlots, crewBonusWeight)
	local inventory: Inventory = {
		userId = player.UserId,
		stacks = {},
		quickSlots = table.create(Balance.Player.quickSlots),
		slotLimit = slots,
		weightLimit = weight,
	}
	inventories[player.UserId] = inventory
	InventoryService.push(player)
	return inventory
end

function InventoryService.destroy(player: Player)
	inventories[player.UserId] = nil
	Net.fireClient("Inventory", player, { stacks = {}, quickSlots = {}, slotLimit = 0, weightLimit = 0, weight = 0, active = false })
end

function InventoryService.get(player: Player): Inventory?
	return inventories[player.UserId]
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

function InventoryService.weightOf(inventory: Inventory): number
	local total = 0
	for _, stack in inventory.stacks do
		local def = ItemRegistry.get(stack.id)
		if def then
			total += def.weight * stack.quantity
		end
	end
	return total
end

function InventoryService.countOf(player: Player, itemId: string): number
	local inventory = inventories[player.UserId]
	if not inventory then
		return 0
	end
	local total = 0
	for _, stack in inventory.stacks do
		if stack.id == itemId then
			total += stack.quantity
		end
	end
	return total
end

function InventoryService.has(player: Player, itemId: string, quantity: number?): boolean
	return InventoryService.countOf(player, itemId) >= (quantity or 1)
end

--- How many of `itemId` would fit right now, given slots and weight.
function InventoryService.spaceFor(player: Player, itemId: string): number
	local inventory = inventories[player.UserId]
	local def = ItemRegistry.get(itemId)
	if not inventory or not def then
		return 0
	end

	-- Room in existing partial stacks costs no slot.
	local roomInStacks = 0
	for _, stack in inventory.stacks do
		if stack.id == itemId then
			roomInStacks += math.max(0, def.stackSize - stack.quantity)
		end
	end

	local freeSlots = math.max(0, inventory.slotLimit - #inventory.stacks)
	local bySlots = roomInStacks + freeSlots * def.stackSize

	local byWeight = if def.weight > 0 then math.floor((inventory.weightLimit - InventoryService.weightOf(inventory)) / def.weight) else math.huge

	return math.max(0, math.min(bySlots, byWeight))
end

--------------------------------------------------------------------------
-- Mutation
--------------------------------------------------------------------------

--- Adds items. Returns how many were actually added, which may be fewer than
--- requested. Callers must handle a partial add rather than assuming success:
--- the leftover is what gets dropped on the ground.
function InventoryService.add(player: Player, itemId: string, quantity: number): number
	local inventory = inventories[player.UserId]
	local def = ItemRegistry.get(itemId)
	if not inventory or not def or quantity <= 0 then
		return 0
	end

	local canTake = math.min(quantity, InventoryService.spaceFor(player, itemId))
	if canTake <= 0 then
		return 0
	end

	local remaining = canTake
	-- Top up existing stacks first so the grid stays tidy.
	for _, stack in inventory.stacks do
		if remaining <= 0 then
			break
		end
		if stack.id == itemId and stack.quantity < def.stackSize then
			local room = def.stackSize - stack.quantity
			local moved = math.min(room, remaining)
			stack.quantity += moved
			remaining -= moved
		end
	end
	while remaining > 0 and #inventory.stacks < inventory.slotLimit do
		local moved = math.min(def.stackSize, remaining)
		table.insert(inventory.stacks, { id = itemId, quantity = moved })
		remaining -= moved
	end

	local added = canTake - remaining
	if added > 0 then
		InventoryService.push(player)
		InventoryService.Changed:Fire(player, inventory)
		InventoryService.ItemCollected:Fire(player, itemId, added)
	end
	return added
end

--- Removes items. Returns how many were removed.
function InventoryService.remove(player: Player, itemId: string, quantity: number): number
	local inventory = inventories[player.UserId]
	if not inventory or quantity <= 0 then
		return 0
	end

	local remaining = quantity
	for index = #inventory.stacks, 1, -1 do
		if remaining <= 0 then
			break
		end
		local stack = inventory.stacks[index]
		if stack.id == itemId then
			local taken = math.min(stack.quantity, remaining)
			stack.quantity -= taken
			remaining -= taken
			if stack.quantity <= 0 then
				table.remove(inventory.stacks, index)
			end
		end
	end

	local removed = quantity - remaining
	if removed > 0 then
		-- Clear any quick slot that now points at nothing.
		for slot, assigned in inventory.quickSlots do
			if assigned == itemId and InventoryService.countOf(player, itemId) <= 0 then
				inventory.quickSlots[slot] = nil
			end
		end
		InventoryService.push(player)
		InventoryService.Changed:Fire(player, inventory)
	end
	return removed
end

--- Moves items between two players. Used by the hand-over interaction, which
--- is how a crew redistributes weight before a long walk back.
function InventoryService.transfer(from: Player, to: Player, itemId: string, quantity: number): (number, string?)
	if from == to then
		return 0, "SAME_PLAYER"
	end
	local fromRoot = Guard.aliveRoot(from)
	local toRoot = Guard.aliveRoot(to)
	if not fromRoot or not toRoot then
		return 0, "NOT_ALIVE"
	end
	if not Guard.withinDistance(fromRoot.Position, toRoot.Position, 14) then
		return 0, "TOO_FAR"
	end
	if not InventoryService.has(from, itemId, quantity) then
		return 0, "NOT_HELD"
	end

	local space = InventoryService.spaceFor(to, itemId)
	if space <= 0 then
		return 0, "NO_SPACE"
	end

	local moving = math.min(quantity, space)
	local removed = InventoryService.remove(from, itemId, moving)
	local added = InventoryService.add(to, itemId, removed)
	-- If the receiver could not take everything after all, give the remainder
	-- back rather than destroying it.
	if added < removed then
		InventoryService.add(from, itemId, removed - added)
	end
	return added, nil
end

--------------------------------------------------------------------------
-- Dropping
--------------------------------------------------------------------------

-- Set by ExpeditionService so drops land in the right world container.
local dropContainer: Instance? = nil
local dropBuilder: ((string, number, CFrame, Instance) -> Instance?)? = nil

function InventoryService.configureDrops(container: Instance, builder: (string, number, CFrame, Instance) -> Instance?)
	dropContainer = container
	dropBuilder = builder
end

function InventoryService.drop(player: Player, itemId: string, quantity: number): (number, string?)
	local def = ItemRegistry.get(itemId)
	if not def then
		return 0, "UNKNOWN_ITEM"
	end
	local root = Guard.aliveRoot(player)
	if not root then
		return 0, "NOT_ALIVE"
	end
	if not InventoryService.has(player, itemId, quantity) then
		return 0, "NOT_HELD"
	end

	local removed = InventoryService.remove(player, itemId, quantity)
	if removed <= 0 then
		return 0, "NOT_HELD"
	end

	if dropBuilder and dropContainer then
		local cf = root.CFrame * CFrame.new(0, -1.5, -4)
		local instance = dropBuilder(itemId, removed, cf, dropContainer)
		if instance then
			-- Dropped items do not live forever; the world would fill up over
			-- a long expedition.
			task.delay(GameConfig.DroppedItemLifetimeSeconds, function()
				if instance.Parent then
					instance:Destroy()
				end
			end)
		end
	end

	return removed, nil
end

--------------------------------------------------------------------------
-- Using
--------------------------------------------------------------------------

--- Consumes one of an item and reports its effect block to the caller.
--- The systems that act on effects (vitals, flashlight, train) subscribe to
--- ItemUsed rather than being called from here, so this service does not need
--- to know about any of them.
function InventoryService.use(player: Player, itemId: string): (boolean, string?)
	local def = ItemRegistry.get(itemId)
	if not def then
		return false, "UNKNOWN_ITEM"
	end
	if not def.quickUsable then
		return false, "NOT_USABLE"
	end
	if not Guard.aliveRoot(player) then
		return false, "NOT_ALIVE"
	end
	if not InventoryService.has(player, itemId, 1) then
		return false, "NOT_HELD"
	end

	-- Consume first. If a listener errors, the item is still gone, which is
	-- the correct failure: a consumable that survives its own use is an
	-- infinite-item exploit.
	if InventoryService.remove(player, itemId, 1) <= 0 then
		return false, "NOT_HELD"
	end
	InventoryService.ItemUsed:Fire(player, itemId, def)
	return true, nil
end

--------------------------------------------------------------------------
-- Quick slots
--------------------------------------------------------------------------

function InventoryService.setQuickSlot(player: Player, slot: number, itemId: string?): boolean
	local inventory = inventories[player.UserId]
	if not inventory then
		return false
	end
	if slot < 1 or slot > Balance.Player.quickSlots then
		return false
	end
	if itemId then
		local def = ItemRegistry.get(itemId)
		if not def or not def.quickUsable then
			return false
		end
		-- Clear the item from any other slot, so one item is never in two.
		for index, assigned in inventory.quickSlots do
			if assigned == itemId then
				inventory.quickSlots[index] = nil
			end
		end
	end
	inventory.quickSlots[slot] = itemId
	InventoryService.push(player)
	return true
end

--------------------------------------------------------------------------
-- Client sync
--------------------------------------------------------------------------

function InventoryService.push(player: Player)
	local inventory = inventories[player.UserId]
	if not inventory then
		return
	end
	Net.fireClient("Inventory", player, {
		active = true,
		stacks = inventory.stacks,
		quickSlots = inventory.quickSlots,
		slotLimit = inventory.slotLimit,
		weightLimit = inventory.weightLimit,
		weight = InventoryService.weightOf(inventory),
		overweight = InventoryService.weightOf(inventory) > inventory.weightLimit * 0.85,
	})
end

--------------------------------------------------------------------------

function InventoryService.start()
	Net.onServerInvoke("InventoryCommand", function(player, rawCommand, rawA, rawB)
		local command = Guard.enum(rawCommand, { "use", "drop", "transfer", "quickslot", "refresh" })
		if not command then
			return { ok = false, error = "BAD_COMMAND" }
		end

		if command == "refresh" then
			InventoryService.push(player)
			return { ok = true }
		end

		if command == "use" then
			local itemId = Guard.id(rawA)
			if not itemId then
				return { ok = false, error = "BAD_ITEM" }
			end
			local ok, err = InventoryService.use(player, itemId)
			return { ok = ok, error = err }
		end

		if command == "drop" then
			local itemId = Guard.id(rawA)
			local quantity = Guard.integer(rawB, 1, 999) or 1
			if not itemId then
				return { ok = false, error = "BAD_ITEM" }
			end
			local def = ItemRegistry.get(itemId)
			if def and def.essential and Balance.AntiGrief.essentialItemsIndestructible then
				-- Essential items are never destroyed. They can still be handed
				-- over or stored, which is the co-operative alternative to
				-- letting one player bin the crew's only valve.
				local stored = InventoryService.storeInTrain(player, itemId, quantity)
				if stored > 0 then
					return { ok = true, storedInTrain = stored }
				end
			end
			local dropped, err = InventoryService.drop(player, itemId, quantity)
			return { ok = dropped > 0, error = err, quantity = dropped }
		end

		if command == "transfer" then
			local itemId = Guard.id(rawA)
			local targetUserId = Guard.integer(rawB, 1)
			if not itemId or not targetUserId then
				return { ok = false, error = "BAD_ARGS" }
			end
			local target = Players:GetPlayerByUserId(targetUserId)
			if not target then
				return { ok = false, error = "NO_TARGET" }
			end
			local moved, err = InventoryService.transfer(player, target, itemId, 1)
			return { ok = moved > 0, error = err, quantity = moved }
		end

		-- quickslot
		local slot = Guard.integer(rawA, 1, Balance.Player.quickSlots)
		if not slot then
			return { ok = false, error = "BAD_SLOT" }
		end
		local itemId = if rawB == nil then nil else Guard.id(rawB)
		local ok = InventoryService.setQuickSlot(player, slot, itemId)
		return { ok = ok }
	end)

	Players.PlayerRemoving:Connect(function(player)
		inventories[player.UserId] = nil
	end)

	log.info("started")
end

--------------------------------------------------------------------------
-- Train storage
--------------------------------------------------------------------------

-- Set by ExpeditionService: the shared supply rack for the current crew.
local trainStores: { [string]: { [string]: number } } = {}
local playerCrew: { [number]: string } = {}

function InventoryService.bindCrewStore(crewId: string, player: Player)
	playerCrew[player.UserId] = crewId
	trainStores[crewId] = trainStores[crewId] or {}
end

function InventoryService.releaseCrewStore(crewId: string)
	trainStores[crewId] = nil
end

--- Moves items into the crew's shared supply rack. Returns how many moved.
function InventoryService.storeInTrain(player: Player, itemId: string, quantity: number): number
	local crewId = playerCrew[player.UserId]
	if not crewId then
		return 0
	end
	local store = trainStores[crewId]
	if not store then
		return 0
	end
	local removed = InventoryService.remove(player, itemId, quantity)
	if removed > 0 then
		store[itemId] = (store[itemId] or 0) + removed
	end
	return removed
end

function InventoryService.takeFromTrain(player: Player, itemId: string, quantity: number): number
	local crewId = playerCrew[player.UserId]
	if not crewId then
		return 0
	end
	local store = trainStores[crewId]
	if not store or (store[itemId] or 0) <= 0 then
		return 0
	end
	local available = math.min(quantity, store[itemId])
	local taken = InventoryService.add(player, itemId, available)
	store[itemId] -= taken
	if store[itemId] <= 0 then
		store[itemId] = nil
	end
	return taken
end

function InventoryService.trainStore(crewId: string): { [string]: number }
	return trainStores[crewId] or {}
end

return InventoryService
