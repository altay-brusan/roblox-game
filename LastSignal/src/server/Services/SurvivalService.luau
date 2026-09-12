--!strict
--[[
	SurvivalService
	---------------
	Player condition: health, stamina, flashlight charge, the downed state,
	revival and spectating.

	WHY THESE ARE ONE SERVICE
	-------------------------
	They are one state machine. A player is alive, downed, or dead-and-
	spectating, and stamina, light and health all behave differently in each.
	Splitting them across files produced exactly the bug this design avoids:
	stamina draining while downed, or a flashlight running on a corpse.

	THE DOWNED STATE
	----------------
	Going down is not death. A downed player crawls, keeps their inventory,
	keeps talking, and bleeds out over a window long enough to cross a station.
	Any teammate can revive them by holding position beside them. That is always
	available and always free.

	There is also a paid self-revive. It is a Developer Product, it is only ever
	offered while you are actually down, it is never offered while a teammate is
	already reviving you, and it is not offered at all when the product has no
	configured ID. If the purchase completes after the player has already been
	revived or the run has ended, the entitlement is banked rather than lost.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local GameConfig = require(Shared.Config.GameConfig)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local Signal = require(Shared.Core.Signal)
local DataService = require(script.Parent.DataService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)
local PurchaseService = require(script.Parent.PurchaseService)
local WorldService = require(script.Parent.WorldService)

local log = Logger.new("SurvivalService")

local SurvivalService = {}

export type Vitals = {
	userId: number,
	health: number,
	maxHealth: number,
	stamina: number,
	maxStamina: number,
	flashlight: number,
	flashlightOn: boolean,
	sprinting: boolean,
	bleeding: boolean,
	exhausted: boolean,

	state: string, -- "alive" | "downed" | "dead"
	downedAt: number?,
	bleedoutSeconds: number,
	downCount: number,
	-- Who is currently reviving, and since when.
	reviverUserId: number?,
	reviveStartedAt: number?,
	-- Banked self-revive entitlements bought but not yet spent.
	bankedSelfRevives: number,

	lastDamageAt: number,
	lastStaminaUseAt: number,
	immuneUntil: number,
	spectatingUserId: number?,
	lastSpectateSwitch: number,
}

local vitals: { [number]: Vitals } = {}

SurvivalService.Downed = Signal.new() :: Signal.Signal<Player>
SurvivalService.Revived = Signal.new() :: Signal.Signal<Player, Player?>
SurvivalService.Died = Signal.new() :: Signal.Signal<Player>
SurvivalService.Damaged = Signal.new() :: Signal.Signal<Player, number, string>

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local function fresh(player: Player): Vitals
	return {
		userId = player.UserId,
		health = Balance.Player.maxHealth,
		maxHealth = Balance.Player.maxHealth,
		stamina = Balance.Player.maxStamina,
		maxStamina = Balance.Player.maxStamina,
		flashlight = Balance.Flashlight.maxCharge,
		flashlightOn = true,
		sprinting = false,
		bleeding = false,
		exhausted = false,
		state = "alive",
		downedAt = nil,
		bleedoutSeconds = Balance.Downed.bleedoutSeconds,
		downCount = 0,
		reviverUserId = nil,
		reviveStartedAt = nil,
		bankedSelfRevives = 0,
		lastDamageAt = 0,
		lastStaminaUseAt = 0,
		immuneUntil = os.clock() + Balance.Threat.respawnImmunitySeconds,
		spectatingUserId = nil,
		lastSpectateSwitch = 0,
	}
end

function SurvivalService.begin(player: Player)
	local existing = vitals[player.UserId]
	local banked = if existing then existing.bankedSelfRevives else 0
	local state = fresh(player)
	state.bankedSelfRevives = banked
	vitals[player.UserId] = state
	SurvivalService.push(player)
end

function SurvivalService.get(player: Player): Vitals?
	return vitals[player.UserId]
end

function SurvivalService.clear(player: Player)
	vitals[player.UserId] = nil
end

--- Grants temporary damage immunity. Used after respawn, after boarding and
--- during any scripted sequence, which is how "no unavoidable deaths" holds.
function SurvivalService.grantImmunity(player: Player, seconds: number)
	local state = vitals[player.UserId]
	if state then
		state.immuneUntil = math.max(state.immuneUntil, os.clock() + seconds)
	end
end

--------------------------------------------------------------------------
-- Damage
--------------------------------------------------------------------------

function SurvivalService.damage(player: Player, amount: number, source: string): boolean
	local state = vitals[player.UserId]
	if not state or state.state ~= "alive" then
		return false
	end
	if os.clock() < state.immuneUntil then
		return false
	end
	if amount <= 0 then
		return false
	end

	local expedition = ExpeditionService.forPlayer(player)
	local difficulty = GameConfig.getDifficulty(if expedition then expedition.difficulty else nil)
	local applied = amount * difficulty.damageTaken

	state.health = math.max(0, state.health - applied)
	state.lastDamageAt = os.clock()
	if applied >= 12 then
		state.bleeding = true
	end

	-- The Humanoid mirrors our health so death, ragdoll and the default health
	-- bar all behave, but this service remains the authority.
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid then
		humanoid.Health = math.max(1, state.health)
	end

	SurvivalService.Damaged:Fire(player, applied, source)

	if state.health <= 0 then
		SurvivalService.down(player, source)
	end
	SurvivalService.push(player)
	return true
end

function SurvivalService.heal(player: Player, amount: number, stopBleed: boolean?)
	local state = vitals[player.UserId]
	if not state or state.state == "dead" then
		return
	end
	state.health = math.clamp(state.health + amount, 0, state.maxHealth)
	if stopBleed then
		state.bleeding = false
	end
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid then
		humanoid.Health = math.max(1, state.health)
	end
	SurvivalService.push(player)
end

--------------------------------------------------------------------------
-- Downed
--------------------------------------------------------------------------

function SurvivalService.down(player: Player, source: string)
	local state = vitals[player.UserId]
	if not state or state.state ~= "alive" then
		return
	end

	state.state = "downed"
	state.downedAt = os.clock()
	state.downCount += 1
	state.health = 0
	state.sprinting = false
	state.reviverUserId = nil
	state.reviveStartedAt = nil

	-- Each subsequent down shortens the next bleedout, so a crew that keeps
	-- going down is under real pressure without any single down being fatal.
	state.bleedoutSeconds = math.max(
		Balance.Downed.minBleedoutSeconds,
		Balance.Downed.bleedoutSeconds * (Balance.Downed.bleedoutDecayPerDown ^ (state.downCount - 1))
	)

	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid then
		humanoid.WalkSpeed = Balance.Downed.crawlSpeed
		humanoid.JumpPower = 0
		humanoid.Health = 1
	end

	local expedition = ExpeditionService.forPlayer(player)
	if expedition then
		expedition.downs += 1
		ExpeditionService.fireRadio(expedition, "crew_downed")
		Net.fireClients("Notify", ExpeditionService.playersOf(expedition), {
			kind = "warning",
			title = player.DisplayName .. " is down",
			body = "Get to them before they bleed out.",
			duration = 8,
		})
	end

	ProgressionService.addStat(player, "times_downed", 1)
	SurvivalService.Downed:Fire(player)
	SurvivalService.push(player)
	log.info(string.format("%s downed by %s", player.Name, source))
end

function SurvivalService.revive(player: Player, by: Player?, healthFraction: number?)
	local state = vitals[player.UserId]
	if not state or state.state ~= "downed" then
		return
	end

	state.state = "alive"
	state.downedAt = nil
	state.reviverUserId = nil
	state.reviveStartedAt = nil
	state.health = state.maxHealth * (healthFraction or Balance.Downed.reviveHealthFraction)
	state.bleeding = false
	state.stamina = state.maxStamina * 0.4
	-- A brief immunity so a revive inside a fight is not instantly undone.
	state.immuneUntil = os.clock() + 3

	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid then
		humanoid.WalkSpeed = Balance.Player.walkSpeed
		humanoid.JumpPower = Balance.Player.jumpPower
		humanoid.Health = state.health
	end

	local expedition = ExpeditionService.forPlayer(player)
	if expedition and by then
		expedition.revives += 1
		ProgressionService.award(by, {
			credits = Balance.Economy.creditsPerRescue,
			xp = Balance.Economy.xpPerRescue,
			stats = { revives_given = 1 },
			source = "revive",
		}, expedition.crewSize)
		ProgressionService.addStat(player, "revives_received", 1)
	end

	SurvivalService.Revived:Fire(player, by)
	SurvivalService.push(player)
end

function SurvivalService.die(player: Player)
	local state = vitals[player.UserId]
	if not state or state.state == "dead" then
		return
	end
	state.state = "dead"
	state.health = 0

	-- Half the inventory is dropped at the body, recoverable by the crew.
	local expedition = ExpeditionService.forPlayer(player)
	if expedition then
		local inventory = InventoryService.get(player)
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if inventory and root and root:IsA("BasePart") then
			local dropPoint = root.CFrame
			for _, stack in table.clone(inventory.stacks) do
				local dropQuantity = math.floor(stack.quantity * Balance.Downed.dropFractionOnDeath + 0.5)
				if dropQuantity > 0 then
					InventoryService.remove(player, stack.id, dropQuantity)
					WorldService.buildDroppedItem(
						stack.id,
						dropQuantity,
						dropPoint * CFrame.new(math.random(-3, 3), 1, math.random(-3, 3)),
						expedition.lane.dropContainer
					)
				end
			end
		end
	end

	ProgressionService.addStat(player, "deaths", 1)
	SurvivalService.Died:Fire(player)
	SurvivalService.push(player)

	-- Straight into spectator rather than a black screen.
	SurvivalService.startSpectating(player)

	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = 0
		end
		task.delay(GameConfig.CorpseCleanupSeconds, function()
			if character.Parent then
				character:Destroy()
			end
		end)
	end
end

--------------------------------------------------------------------------
-- Reviving
--------------------------------------------------------------------------

local function reviveDuration(expedition: ExpeditionService.Expedition?): number
	local difficulty = GameConfig.getDifficulty(if expedition then expedition.difficulty else nil)
	return difficulty.reviveSeconds
end

local function beginRevive(reviver: Player, target: Player): (boolean, string?)
	local targetState = vitals[target.UserId]
	if not targetState or targetState.state ~= "downed" then
		return false, "NOT_DOWNED"
	end
	local reviverState = vitals[reviver.UserId]
	if not reviverState or reviverState.state ~= "alive" then
		return false, "NOT_ALIVE"
	end
	local reviverRoot = Guard.aliveRoot(reviver)
	local targetCharacter = target.Character
	local targetRoot = if targetCharacter then targetCharacter:FindFirstChild("HumanoidRootPart") else nil
	if not reviverRoot or not targetRoot or not targetRoot:IsA("BasePart") then
		return false, "NO_TARGET"
	end
	if not Guard.withinDistance(reviverRoot.Position, targetRoot.Position, 10) then
		return false, "TOO_FAR"
	end
	if targetState.reviverUserId and targetState.reviverUserId ~= reviver.UserId then
		return false, "ALREADY_BEING_REVIVED"
	end

	targetState.reviverUserId = reviver.UserId
	targetState.reviveStartedAt = os.clock()
	SurvivalService.push(target)
	SurvivalService.push(reviver)
	return true, nil
end

local function cancelRevive(target: Player)
	local state = vitals[target.UserId]
	if state then
		state.reviverUserId = nil
		state.reviveStartedAt = nil
		SurvivalService.push(target)
	end
end

--------------------------------------------------------------------------
-- Self revive
--------------------------------------------------------------------------

--- Whether the paid self-revive may be offered right now. Every one of these
--- conditions has to hold; the offer is deliberately narrow.
function SurvivalService.selfReviveOffered(player: Player): (boolean, string?)
	local state = vitals[player.UserId]
	if not state or state.state ~= "downed" then
		return false, "NOT_DOWNED"
	end
	if state.reviverUserId then
		-- A teammate is already on the way. Selling into that moment would be
		-- selling relief from a problem that is already being solved.
		return false, "BEING_REVIVED"
	end
	if state.bankedSelfRevives > 0 then
		return true, "BANKED"
	end
	if not Monetization.isConfigured("field_revive") then
		return false, "NOT_CONFIGURED"
	end
	return true, nil
end

function SurvivalService.useSelfRevive(player: Player): (boolean, string?)
	local state = vitals[player.UserId]
	if not state or state.state ~= "downed" then
		return false, "NOT_DOWNED"
	end
	if state.bankedSelfRevives <= 0 then
		return false, "NONE_BANKED"
	end
	state.bankedSelfRevives -= 1
	SurvivalService.revive(player, nil, Balance.Downed.selfReviveHealthFraction)
	return true, nil
end

--------------------------------------------------------------------------
-- Spectating
--------------------------------------------------------------------------

function SurvivalService.startSpectating(player: Player)
	local expedition = ExpeditionService.forPlayer(player)
	if not expedition then
		Net.fireClient("DownedState", player, { state = "dead", spectating = nil })
		return
	end
	local candidates = {}
	for _, other in ExpeditionService.playersOf(expedition) do
		local otherState = vitals[other.UserId]
		if other ~= player and otherState and otherState.state ~= "dead" then
			table.insert(candidates, other.UserId)
		end
	end
	local state = vitals[player.UserId]
	if state then
		state.spectatingUserId = candidates[1]
	end
	Net.fireClient("DownedState", player, {
		state = "dead",
		spectating = candidates[1],
		candidates = candidates,
	})
end

local function cycleSpectate(player: Player, direction: number)
	local state = vitals[player.UserId]
	if not state or state.state ~= "dead" then
		return
	end
	if os.clock() - state.lastSpectateSwitch < Balance.Downed.spectatorSwitchCooldown then
		return
	end
	state.lastSpectateSwitch = os.clock()

	local expedition = ExpeditionService.forPlayer(player)
	if not expedition then
		return
	end
	local candidates = {}
	for _, other in ExpeditionService.playersOf(expedition) do
		local otherState = vitals[other.UserId]
		if other ~= player and otherState and otherState.state ~= "dead" then
			table.insert(candidates, other.UserId)
		end
	end
	if #candidates == 0 then
		state.spectatingUserId = nil
		Net.fireClient("DownedState", player, { state = "dead", spectating = nil, candidates = {} })
		return
	end
	local currentIndex = table.find(candidates, state.spectatingUserId or 0) or 0
	local nextIndex = ((currentIndex - 1 + direction) % #candidates) + 1
	state.spectatingUserId = candidates[nextIndex]
	Net.fireClient("DownedState", player, {
		state = "dead",
		spectating = state.spectatingUserId,
		candidates = candidates,
	})
end

--------------------------------------------------------------------------
-- Client sync
--------------------------------------------------------------------------

function SurvivalService.push(player: Player)
	local state = vitals[player.UserId]
	if not state then
		return
	end
	local offered, offerReason = SurvivalService.selfReviveOffered(player)
	Net.fireClient("VitalsState", player, {
		health = state.health,
		maxHealth = state.maxHealth,
		stamina = state.stamina,
		maxStamina = state.maxStamina,
		flashlight = state.flashlight,
		maxFlashlight = Balance.Flashlight.maxCharge,
		flashlightOn = state.flashlightOn,
		bleeding = state.bleeding,
		exhausted = state.exhausted,
		state = state.state,
		bleedoutRemaining = if state.downedAt then math.max(0, state.bleedoutSeconds - (os.clock() - state.downedAt)) else nil,
		bleedoutTotal = state.bleedoutSeconds,
		reviverUserId = state.reviverUserId,
		reviveProgress = if state.reviveStartedAt
			then math.clamp((os.clock() - state.reviveStartedAt) / reviveDuration(ExpeditionService.forPlayer(player)), 0, 1)
			else 0,
		selfReviveOffered = offered,
		selfReviveReason = offerReason,
		bankedSelfRevives = state.bankedSelfRevives,
	})
end

--------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------

local function tick(dt: number)
	for userId, state in vitals do
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			continue
		end

		if state.state == "alive" then
			-- Stamina.
			if state.sprinting and state.stamina > 0 then
				state.stamina = math.max(0, state.stamina - Balance.Player.sprintDrainPerSecond * dt)
				state.lastStaminaUseAt = os.clock()
				if state.stamina <= Balance.Player.staminaExhaustedAt then
					state.exhausted = true
					state.sprinting = false
				end
			elseif os.clock() - state.lastStaminaUseAt > Balance.Player.staminaRegenDelay then
				state.stamina = math.min(state.maxStamina, state.stamina + Balance.Player.staminaRegenPerSecond * dt)
				if state.exhausted and state.stamina >= Balance.Player.staminaRecoverGate then
					state.exhausted = false
				end
			end

			-- Flashlight.
			if state.flashlightOn and state.flashlight > 0 then
				state.flashlight = math.max(0, state.flashlight - Balance.Flashlight.drainPerSecond * dt)
				if state.flashlight <= 0 then
					state.flashlightOn = false
				end
			end

			-- Bleeding and regeneration.
			if state.bleeding then
				state.health = math.max(1, state.health - 0.8 * dt)
				if state.health <= 1 then
					SurvivalService.down(player, "bleeding")
				end
			elseif os.clock() - state.lastDamageAt > Balance.Player.healthRegenDelay then
				state.health = math.min(state.maxHealth, state.health + Balance.Player.healthRegenPerSecond * dt)
			end

			-- Walk speed follows stamina and carried weight.
			local character = player.Character
			local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
			if humanoid then
				local speed = if state.sprinting and not state.exhausted then Balance.Player.sprintSpeed else Balance.Player.walkSpeed
				local inventory = InventoryService.get(player)
				if inventory then
					local weight = InventoryService.weightOf(inventory)
					if weight > inventory.weightLimit * 0.85 then
						speed *= Balance.Player.carryHeavySpeedMultiplier
					end
				end
				if humanoid.WalkSpeed ~= speed then
					humanoid.WalkSpeed = speed
				end
			end
		elseif state.state == "downed" then
			-- Revive progress.
			if state.reviverUserId and state.reviveStartedAt then
				local reviver = Players:GetPlayerByUserId(state.reviverUserId)
				local reviverRoot = if reviver then Guard.aliveRoot(reviver) else nil
				local character = player.Character
				local targetRoot = if character then character:FindFirstChild("HumanoidRootPart") else nil
				local stillValid = reviver ~= nil
					and reviverRoot ~= nil
					and targetRoot ~= nil
					and targetRoot:IsA("BasePart")
					and Guard.withinDistance(reviverRoot.Position, (targetRoot :: BasePart).Position, 12)
				if not stillValid then
					cancelRevive(player)
				elseif (os.clock() - state.reviveStartedAt) >= reviveDuration(ExpeditionService.forPlayer(player)) then
					SurvivalService.revive(player, reviver)
				end
			end

			-- Bleedout.
			if state.downedAt and (os.clock() - state.downedAt) >= state.bleedoutSeconds then
				SurvivalService.die(player)
			end
		end
	end
end

--------------------------------------------------------------------------

function SurvivalService.start()
	-- Item effects are consumed here rather than in InventoryService, so the
	-- inventory does not need to know what a bandage does.
	InventoryService.ItemUsed:Connect(function(player, _itemId, def)
		local effect = def.effect
		if not effect then
			return
		end
		local state = vitals[player.UserId]
		if not state then
			return
		end
		if type(effect.heal) == "number" then
			SurvivalService.heal(player, effect.heal, effect.stopBleed == true)
		end
		if type(effect.stamina) == "number" then
			state.stamina = math.min(state.maxStamina, state.stamina + effect.stamina)
			state.exhausted = false
		end
		if type(effect.flashlightCharge) == "number" then
			state.flashlight = math.clamp(state.flashlight + effect.flashlightCharge, 0, Balance.Flashlight.maxCharge)
			if state.flashlight > 0 then
				state.flashlightOn = true
			end
		end
		SurvivalService.push(player)
	end)

	Net.onServerInvoke("ReviveCommand", function(player, rawCommand, rawTarget)
		local command = Guard.enum(rawCommand, { "start", "stop", "self", "buy_self" })
		if not command then
			return { ok = false, error = "BAD_COMMAND" }
		end

		if command == "self" then
			local ok, err = SurvivalService.useSelfRevive(player)
			return { ok = ok, error = err }
		end

		if command == "buy_self" then
			local offered, reason = SurvivalService.selfReviveOffered(player)
			if not offered then
				return { ok = false, error = reason }
			end
			if reason == "BANKED" then
				local ok, err = SurvivalService.useSelfRevive(player)
				return { ok = ok, error = err }
			end
			-- Prompt gating does not apply here: this is a purchase the player
			-- explicitly asked for, at the only moment it is useful.
			local ok, err = PurchaseService.prompt(player, "field_revive", nil)
			return { ok = ok, error = err }
		end

		local targetUserId = Guard.integer(rawTarget, 1)
		if not targetUserId then
			return { ok = false, error = "BAD_TARGET" }
		end
		local target = Players:GetPlayerByUserId(targetUserId)
		if not target then
			return { ok = false, error = "NO_TARGET" }
		end

		if command == "stop" then
			local targetState = vitals[target.UserId]
			if targetState and targetState.reviverUserId == player.UserId then
				cancelRevive(target)
			end
			return { ok = true }
		end

		local ok, err = beginRevive(player, target)
		return { ok = ok, error = err }
	end)

	Net.onServerEvent("SpectateCommand", function(player, rawDirection)
		local direction = Guard.integer(rawDirection, -1, 1)
		if not direction or direction == 0 then
			return
		end
		cycleSpectate(player, direction)
	end)

	-- Sprint and flashlight toggles come in on the vitals channel rather than
	-- as their own remotes, because they are frequent and trivially validated.
	Net.onServerEvent("SetSetting", function(player, rawKey, rawValue)
		local key = Guard.enum(rawKey, { "sprinting", "flashlight" })
		if not key then
			-- Fall through to the profile setting handler, which owns the rest
			-- of this remote.
			return
		end
		local state = vitals[player.UserId]
		if not state or state.state ~= "alive" then
			return
		end
		if key == "sprinting" then
			local wants = Guard.boolean(rawValue)
			if wants == nil then
				return
			end
			state.sprinting = wants and not state.exhausted and state.stamina > 0
		else
			local wants = Guard.boolean(rawValue)
			if wants == nil then
				return
			end
			state.flashlightOn = wants and state.flashlight > 0
		end
		SurvivalService.push(player)
	end)

	-- A completed self-revive purchase banks an entitlement. Banking rather
	-- than applying immediately is what makes the purchase safe if the player
	-- was revived, died or the run ended between prompt and receipt.
	PurchaseService.Purchased:Connect(function(player, productKey)
		if productKey ~= "field_revive" then
			return
		end
		local state = vitals[player.UserId]
		if not state then
			-- No session at all: bank it on the profile so it survives.
			DataService.update(player, function(p)
				p.purchases.products.field_revive = (p.purchases.products.field_revive or 0)
			end)
			return
		end
		state.bankedSelfRevives += 1
		if state.state == "downed" and not state.reviverUserId then
			SurvivalService.useSelfRevive(player)
		else
			Net.fireClient("Notify", player, {
				kind = "info",
				title = "Stimulant banked",
				body = "You were already up. It is saved for the next time you go down.",
				duration = 7,
			})
			SurvivalService.push(player)
		end
	end)

	ExpeditionService.StateChanged:Connect(function(expedition, state)
		if state == "cinematic" or state == "preparing" then
			for _, player in ExpeditionService.playersOf(expedition) do
				SurvivalService.begin(player)
				SurvivalService.grantImmunity(player, GameConfig.CinematicSeconds + 6)
			end
		end
	end)

	ExpeditionService.Ended:Connect(function(expedition)
		for _, player in ExpeditionService.playersOf(expedition) do
			SurvivalService.clear(player)
			local character = player.Character
			local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
			if humanoid then
				humanoid.WalkSpeed = Balance.Player.walkSpeed
				humanoid.JumpPower = Balance.Player.jumpPower
				humanoid.Health = humanoid.MaxHealth
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		vitals[player.UserId] = nil
	end)

	local accumulator = 0
	-- Simulation runs at 8 Hz: fast enough for stamina and bleed to feel
	-- continuous, slow enough that a full server costs almost nothing.
	local interval = 1 / 8
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < interval then
			return
		end
		local step = accumulator
		accumulator = 0
		local ok, err = Protect.call(tick, step)
		if not ok then
			log.error("tick failed:", tostring(err))
		end
	end)

	-- Vitals are pushed at a slower rate than they are simulated; the HUD
	-- interpolates between updates rather than needing every tick.
	task.spawn(function()
		while true do
			task.wait(1 / GameConfig.VitalsTickRate)
			for userId in vitals do
				local player = Players:GetPlayerByUserId(userId)
				if player then
					SurvivalService.push(player)
				end
			end
		end
	end)

	log.info("started")
end

return SurvivalService
