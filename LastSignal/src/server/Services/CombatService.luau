--!strict
--[[
	CombatService
	-------------
	Server-authoritative weapons.

	WHAT THE CLIENT SENDS
	---------------------
	An origin, a direction, and for firearms the hit it believes it made. That
	is all. The server decides whether the shot was possible, whether the hit
	was plausible, and what damage results.

	WHAT THE SERVER CHECKS ON EVERY SHOT
	------------------------------------
	  the weapon is equipped and owned
	  the reload state allows firing
	  enough time has passed since the last shot, with a small grace
	  ammunition is present, and it is decremented here
	  the origin is near the player's actual character
	  the hit is within the weapon's range, with a small grace
	  the hit position is near the claimed target, with a tolerance that suits
	    a 250 ms connection and nothing more

	A shot that fails any of these is discarded silently. The client is not told
	why, because that information only helps somebody tuning an exploit.

	COMBAT AND FEAR
	---------------
	Firearms are loud, and loud is the primary input to the threat director.
	Every shot raises threat and calls the creature. Nothing here can kill the
	creature; damage fills its drive-off meter. That is what keeps a horror game
	a horror game while still letting a cornered crew fight back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local WeaponRegistry = require(Shared.Registry.WeaponRegistry)

local CreatureService = require(script.Parent.CreatureService)
local DataService = require(script.Parent.DataService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)
local SurvivalService = require(script.Parent.SurvivalService)

local log = Logger.new("CombatService")

local CombatService = {}

export type WeaponState = {
	userId: number,
	equipped: string?,
	magazine: number,
	reloading: boolean,
	reloadStartedAt: number,
	reloadDuration: number,
	lastFiredAt: number,
	lastSwingAt: number,
}

local states: { [number]: WeaponState } = {}

CombatService.Fired = Signal.new() :: Signal.Signal<Player, string, Vector3>
CombatService.Hit = Signal.new() :: Signal.Signal<Player, Instance, number>

--------------------------------------------------------------------------

local function stateFor(player: Player): WeaponState
	local existing = states[player.UserId]
	if existing then
		return existing
	end
	local created: WeaponState = {
		userId = player.UserId,
		equipped = nil,
		magazine = 0,
		reloading = false,
		reloadStartedAt = 0,
		reloadDuration = 0,
		lastFiredAt = 0,
		lastSwingAt = 0,
	}
	states[player.UserId] = created
	return created
end

--- Ammunition lives in the inventory as items, not as a separate counter, so
--- there is exactly one place where it can be gained or lost.
local function ammoItemFor(ammoType: string): string?
	if ammoType == "pistol" then
		return "ammo_pistol"
	elseif ammoType == "shell" then
		return "ammo_shell"
	elseif ammoType == "rifle" then
		return "ammo_rifle"
	elseif ammoType == "flare" then
		return "flare_shell"
	end
	return nil
end

function CombatService.equip(player: Player, weaponId: string?): (boolean, string?)
	local state = stateFor(player)
	if not weaponId then
		state.equipped = nil
		state.reloading = false
		return true, nil
	end

	local def = WeaponRegistry.get(weaponId)
	if not def then
		return false, "UNKNOWN_WEAPON"
	end
	local profile = DataService.getProfile(player)
	if not profile then
		return false, "NOT_LOADED"
	end
	-- Ownership is checked here and nowhere else, so a client cannot equip a
	-- weapon it has not unlocked by any route.
	if not (def.startingLoadout or profile.weapons[weaponId]) then
		return false, "NOT_OWNED"
	end
	if profile.level < def.unlockLevel then
		return false, "LEVEL_LOCKED"
	end

	state.equipped = weaponId
	state.reloading = false
	if def.kind == "firearm" then
		-- A freshly equipped firearm starts with whatever it can load from the
		-- player's ammunition, up to a fraction of a magazine.
		local ammoItem = ammoItemFor(def.ammoType or "")
		local available = if ammoItem then InventoryService.countOf(player, ammoItem) else 0
		local wanted = math.floor((def.magazineSize or 1) * Balance.Combat.startingAmmoFraction + 0.5)
		state.magazine = math.min(def.magazineSize or 1, math.max(0, math.min(wanted, available)))
	else
		state.magazine = 0
	end
	CombatService.push(player)
	return true, nil
end

function CombatService.get(player: Player): WeaponState?
	return states[player.UserId]
end

function CombatService.push(player: Player)
	local state = states[player.UserId]
	if not state then
		return
	end
	local def = if state.equipped then WeaponRegistry.get(state.equipped) else nil
	local reserve = 0
	if def and def.kind == "firearm" then
		local ammoItem = ammoItemFor(def.ammoType or "")
		reserve = if ammoItem then InventoryService.countOf(player, ammoItem) else 0
	end
	Net.fireClient("WeaponEffect", player, {
		kind = "state",
		equipped = state.equipped,
		magazine = state.magazine,
		magazineSize = if def then def.magazineSize else nil,
		reserve = reserve,
		reloading = state.reloading,
		reloadRemaining = if state.reloading then math.max(0, state.reloadDuration - (os.clock() - state.reloadStartedAt)) else 0,
	})
end

--------------------------------------------------------------------------
-- Reloading
--------------------------------------------------------------------------

function CombatService.reload(player: Player): (boolean, string?)
	local state = stateFor(player)
	local def = if state.equipped then WeaponRegistry.get(state.equipped) else nil
	if not def or def.kind ~= "firearm" then
		return false, "NO_FIREARM"
	end
	if state.reloading then
		return false, "ALREADY_RELOADING"
	end
	local capacity = def.magazineSize or 1
	if state.magazine >= capacity then
		return false, "FULL"
	end

	local ammoItem = ammoItemFor(def.ammoType or "")
	if not ammoItem then
		return false, "NO_AMMO_TYPE"
	end
	local available = InventoryService.countOf(player, ammoItem)
	if available <= 0 then
		return false, "NO_AMMO"
	end

	local missing = capacity - state.magazine
	local loading = math.min(missing, available)
	local duration = WeaponRegistry.reloadDuration(def, loading)

	state.reloading = true
	state.reloadStartedAt = os.clock()
	state.reloadDuration = duration
	CombatService.push(player)

	task.delay(duration, function()
		-- Re-validate on completion: the player may have died, swapped weapon
		-- or spent the ammunition in the meantime.
		local current = states[player.UserId]
		if not current or not current.reloading or current.equipped ~= (def :: any).id then
			return
		end
		current.reloading = false
		local stillAvailable = InventoryService.countOf(player, ammoItem)
		local actual = math.min(loading, stillAvailable)
		if actual > 0 then
			InventoryService.remove(player, ammoItem, actual)
			current.magazine = math.min(capacity, current.magazine + actual)
		end
		CombatService.push(player)
	end)

	return true, nil
end

--------------------------------------------------------------------------
-- Damage application
--------------------------------------------------------------------------

--- Resolves what was hit and applies damage. Returns the damage dealt.
local function applyHit(player: Player, hitInstance: Instance, damage: number): number
	local expedition = ExpeditionService.forPlayer(player)
	if not expedition then
		return 0
	end

	-- The creature.
	local creatureModel = if hitInstance:IsA("Model") then hitInstance else hitInstance:FindFirstAncestorOfClass("Model")
	if creatureModel and creatureModel:HasTag("Creature") then
		for _, creature in CreatureService.forExpedition(expedition.id) do
			if creature.model == creatureModel then
				local applied = damage
				-- A hit to the head cowl counts for more, which rewards aiming
				-- at the thing that is hardest to see.
				if hitInstance.Name == "Head" or hitInstance.Name == "Cowl" then
					applied *= Balance.Combat.headshotMultiplier
				end
				CreatureService.applyDamage(creature, applied, player)
				CombatService.Hit:Fire(player, creatureModel, applied)
				return applied
			end
		end
		return 0
	end

	-- Friendly fire is off. A co-operative horror game where one player can
	-- shoot another is a griefing tool, and there is no upside.
	local character = if hitInstance:IsA("Model") then hitInstance else hitInstance:FindFirstAncestorOfClass("Model")
	if character then
		local hitPlayer = Players:GetPlayerFromCharacter(character)
		if hitPlayer then
			return 0
		end
	end

	-- Nothing else in the world takes damage. Scenery, the train and other
	-- players are all deliberately immune, so a stray shot costs ammunition and
	-- noise and nothing more.
	return 0
end

--------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------

local function handleFire(player: Player, rawOrigin: any, rawDirection: any, rawHitInstance: any, rawHitPosition: any)
	local state = states[player.UserId]
	if not state or not state.equipped then
		return
	end
	local def = WeaponRegistry.get(state.equipped)
	if not def or def.kind ~= "firearm" then
		return
	end

	local vitals = SurvivalService.get(player)
	if not vitals or vitals.state ~= "alive" then
		return
	end
	if state.reloading then
		return
	end
	if state.magazine <= 0 then
		return
	end

	local now = os.clock()
	if (now - state.lastFiredAt) < (def.fireInterval - Balance.Combat.fireIntervalGrace) then
		return
	end

	local origin = Guard.vector3(rawOrigin, 1e5)
	local direction = Guard.direction(rawDirection)
	if not origin or not direction then
		return
	end

	local root = Guard.aliveRoot(player)
	if not root then
		return
	end
	-- The shot must come from roughly where the player is.
	if not Guard.withinDistance(origin, root.Position, 12) then
		return
	end

	state.lastFiredAt = now
	state.magazine -= 1

	local expedition = ExpeditionService.forPlayer(player)
	if expedition then
		ExpeditionService.noteWeaponFired(expedition, def.noiseRadius > Balance.Combat.noiseRadiusSuppressed)
		-- Loud, and the forest is listening. This is the real cost of firing.
		CreatureService.hearNoise(expedition.id, origin, def.noiseRadius / 40)
		ExpeditionService.ThreatEvent:Fire(expedition, "gunshot", Balance.Threat.noisePerGunshot)
		CreatureService.learnCue(expedition.id, def.fireCue)
	end
	ProgressionService.addStat(player, "shots_fired", 1)

	-- Hit resolution. The client reports what it hit; the server checks the
	-- claim is geometrically possible before acting on it.
	local totalDamage = 0
	local hitInstance = Guard.instance(rawHitInstance, "BasePart")
	local hitPosition = Guard.vector3(rawHitPosition, 1e5)

	if hitInstance and hitPosition then
		local maxRange = def.range * Balance.Combat.maxHitDistanceGrace
		local withinRange = (hitPosition - origin).Magnitude <= maxRange
		local nearTarget = ((hitInstance :: BasePart).Position - hitPosition).Magnitude
			<= Balance.Combat.hitPositionTolerance + (hitInstance :: BasePart).Size.Magnitude
		-- The hit must also be roughly along the reported aim direction.
		local toHit = (hitPosition - origin)
		local alongAim = toHit.Magnitude < 1 or toHit.Unit:Dot(direction) > 0.72

		if withinRange and nearTarget and alongAim then
			local pellets = def.pellets or 1
			for _ = 1, pellets do
				totalDamage += applyHit(player, hitInstance :: Instance, def.damage)
			end
		end
	end

	-- Effects are broadcast to the crew so everyone sees and hears the shot.
	if expedition then
		Net.fireClients("WeaponEffect", ExpeditionService.playersOf(expedition), {
			kind = "fire",
			userId = player.UserId,
			weaponId = def.id,
			origin = origin,
			direction = direction,
			hitPosition = hitPosition,
			damage = totalDamage,
		})
	end
	CombatService.Fired:Fire(player, def.id, origin)
	CombatService.push(player)

	-- Flare rounds deny ground where they land, which is the whole point of
	-- carrying a flare pistol.
	if def.id == "flare_gun" and hitPosition and expedition then
		CreatureService.denyArea(expedition.id, hitPosition, Balance.Creature.flareDenialRadius, Balance.Creature.flareDenialSeconds)
		Net.fireClients("WeaponEffect", ExpeditionService.playersOf(expedition), {
			kind = "flare",
			position = hitPosition,
			seconds = Balance.Creature.flareDenialSeconds,
		})
	end
end

--------------------------------------------------------------------------
-- Melee
--------------------------------------------------------------------------

local function handleMelee(player: Player, rawDirection: any)
	local state = states[player.UserId]
	if not state or not state.equipped then
		return
	end
	local def = WeaponRegistry.get(state.equipped)
	if not def or def.kind ~= "melee" then
		return
	end

	local vitals = SurvivalService.get(player)
	if not vitals or vitals.state ~= "alive" then
		return
	end

	local now = os.clock()
	if (now - state.lastSwingAt) < (def.fireInterval - Balance.Combat.fireIntervalGrace) then
		return
	end

	local cost = def.staminaCost or Balance.Combat.meleeStaminaCost
	if vitals.stamina < cost then
		return
	end

	local direction = Guard.direction(rawDirection)
	local root = Guard.aliveRoot(player)
	if not direction or not root then
		return
	end

	state.lastSwingAt = now
	vitals.stamina = math.max(0, vitals.stamina - cost)

	local expedition = ExpeditionService.forPlayer(player)
	if not expedition then
		return
	end

	-- Melee is resolved entirely on the server: an arc test against every
	-- creature in range. Nothing the client reports is used.
	local hits = 0
	local maxTargets = def.maxTargets or 1
	for _, creature in CreatureService.forExpedition(expedition.id) do
		if hits >= maxTargets then
			break
		end
		local delta = creature.position - root.Position
		if delta.Magnitude <= def.range then
			local angle = math.deg(math.acos(math.clamp(direction:Dot(delta.Unit), -1, 1)))
			if angle <= (def.swingArcDegrees or 70) * 0.5 then
				CreatureService.applyDamage(creature, def.damage, player)
				hits += 1
				CombatService.Hit:Fire(player, creature.model, def.damage)
			end
		end
	end

	if hits > 0 then
		ProgressionService.addStat(player, "melee_hits", hits)
	end
	CreatureService.hearNoise(expedition.id, root.Position, Balance.Combat.noiseRadiusMelee / 20)

	Net.fireClients("WeaponEffect", ExpeditionService.playersOf(expedition), {
		kind = "melee",
		userId = player.UserId,
		weaponId = def.id,
		origin = root.Position,
		direction = direction,
		hits = hits,
	})
	SurvivalService.push(player)
end

--------------------------------------------------------------------------

function CombatService.start()
	Net.onServerEvent("WeaponFire", handleFire)
	Net.onServerEvent("MeleeSwing", handleMelee)

	Net.onServerEvent("WeaponReload", function(player)
		CombatService.reload(player)
	end)

	-- Equipping is a command on the inventory channel, since it is an
	-- inventory action from the player's point of view.
	InventoryService.Changed:Connect(function(player)
		CombatService.push(player)
	end)

	ExpeditionService.StateChanged:Connect(function(expedition, phase)
		if phase ~= "cinematic" then
			return
		end
		-- Equip each player's chosen loadout at the start of the run.
		for _, player in ExpeditionService.playersOf(expedition) do
			local profile = DataService.getProfile(player)
			if profile then
				CombatService.equip(player, profile.loadout.primaryWeapon)
				-- Starting ammunition for the sidearm, so a player is never
				-- completely without an answer.
				local sidearm = WeaponRegistry.get(profile.loadout.sidearm)
				if sidearm and sidearm.ammoType then
					local ammoItem = ammoItemFor(sidearm.ammoType)
					if ammoItem then
						InventoryService.add(player, ammoItem, 2)
					end
				end
			end
		end
	end)

	ExpeditionService.Ended:Connect(function(expedition)
		for _, player in ExpeditionService.playersOf(expedition) do
			states[player.UserId] = nil
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		states[player.UserId] = nil
	end)

	log.info("started")
end

--- Exposed so the inventory command handler can equip without a second remote.
function CombatService.handleEquip(player: Player, weaponId: string?): (boolean, string?)
	return CombatService.equip(player, weaponId)
end

return CombatService
