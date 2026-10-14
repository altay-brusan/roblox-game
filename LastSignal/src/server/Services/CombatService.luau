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
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
local WeaponModels = require(Shared.Registry.WeaponModels)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)

local CreatureService = require(script.Parent.CreatureService)
local DataService = require(script.Parent.DataService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)
local SurvivalService = require(script.Parent.SurvivalService)

local log = Logger.new("CombatService")

local CombatService = {}

local handleArc: (Player, any, WeaponRegistry.WeaponDef, any, any) -> ()

export type WeaponState = {
	userId: number,
	equipped: string?,
	magazine: number,
	reloading: boolean,
	reloadStartedAt: number,
	reloadDuration: number,
	lastFiredAt: number,
	lastSwingAt: number,
	-- Arc Rail Projector. Heat decays continuously, so it is stored with the
	-- time it was last written and resolved on read.
	heat: number,
	heatAt: number,
	overheatUntil: number,
	chargeStartedAt: number?,
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
		heat = 0,
		heatAt = 0,
		overheatUntil = 0,
		chargeStartedAt = nil,
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

local function finishFor(player: Player): WeaponModels.Finish?
	local profile = DataService.getProfile(player)
	local def = if profile then CosmeticRegistry.get(profile.loadout.finish) else nil
	if not def or def.slot ~= "finish" then
		return nil
	end
	return { body = def.body, accent = def.accent, material = def.material }
end

--- The weapon in the character's hand, built by the same code as the
--- first-person viewmodel and the armory preview, so other players see what
--- you are carrying. Massless and non-colliding: it changes nothing but looks.
local function attachHeld(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local existing = character:FindFirstChild("HeldWeapon")
	if existing then
		existing:Destroy()
	end
	local state = states[player.UserId]
	local def = if state and state.equipped then WeaponRegistry.get(state.equipped) else nil
	if not def then
		return
	end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		return
	end
	local built = WeaponModels.build(def, finishFor(player))
	built.model.Name = "HeldWeapon"
	local grip = if hand.Name == "RightHand" then CFrame.new(0, -0.15, -0.1) else CFrame.new(0, -0.9, -0.1)
	built.root.CFrame = hand.CFrame * grip
	local weld = Instance.new("Weld")
	weld.Part0 = hand
	weld.Part1 = built.root
	weld.C0 = grip
	weld.Parent = built.root
	built.model.Parent = character
end

local function heatOf(state: WeaponState, def: WeaponRegistry.WeaponDef): number
	local arc = def.arc
	if not arc then
		return 0
	end
	return math.max(0, state.heat - (os.clock() - state.heatAt) * arc.heatDecayPerSecond)
end

function CombatService.equip(player: Player, weaponId: string?): (boolean, string?)
	local state = stateFor(player)
	if not weaponId then
		state.equipped = nil
		state.reloading = false
		attachHeld(player)
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
		local loading = math.min(def.magazineSize or 1, math.max(0, math.min(wanted, available)))
		if ammoItem and loading > 0 then
			InventoryService.remove(player, ammoItem, loading)
		end
		state.magazine = loading
	else
		state.magazine = 0
	end
	state.heat = 0
	state.heatAt = os.clock()
	state.overheatUntil = 0
	state.chargeStartedAt = nil
	attachHeld(player)
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
		heat = if def and def.arc then heatOf(state, def) else nil,
		overheatRemaining = if def and def.arc then math.max(0, state.overheatUntil - os.clock()) else nil,
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

--------------------------------------------------------------------------
-- Arc Rail Projector
--------------------------------------------------------------------------

--- A burst from the arc. The server times the charge from WeaponCharge,
--- tracks heat itself, and finds what is in the cone with its own geometry:
--- the client says only where it was pointing.
function handleArc(player: Player, state: WeaponState, def: WeaponRegistry.WeaponDef, rawOrigin: any, rawDirection: any)
	local arc = def.arc :: any
	local now = os.clock()
	if now < state.overheatUntil then
		return
	end
	local chargedAt = state.chargeStartedAt
	state.chargeStartedAt = nil
	if not chargedAt or now - chargedAt < arc.chargeSeconds - Balance.Combat.fireIntervalGrace then
		return
	end
	local origin = Guard.vector3(rawOrigin, 1e5)
	local direction = Guard.direction(rawDirection)
	local root = Guard.aliveRoot(player)
	if not origin or not direction or not root or not Guard.withinDistance(origin, root.Position, 12) then
		return
	end

	local heat = heatOf(state, def) + arc.heatPerBurst
	state.heat = heat
	state.heatAt = now
	state.lastFiredAt = now
	local overheated = heat >= 100
	if overheated then
		state.overheatUntil = now + arc.overheatLockSeconds
		state.heat = 100
	end

	local expedition = ExpeditionService.forPlayer(player)
	local struck: { { position: Vector3, stunned: number } } = {}
	if expedition then
		ExpeditionService.noteWeaponFired(expedition, true)
		CreatureService.hearNoise(expedition.id, origin, def.noiseRadius / 40)
		ExpeditionService.ThreatEvent:Fire(expedition, "gunshot", Balance.Threat.noisePerGunshot * 0.5)
		local cosCone = math.cos(math.rad(arc.coneDegrees))
		for _, creature in CreatureService.forExpedition(expedition.id) do
			local offset = creature.root.Position - origin
			local distance = offset.Magnitude
			if distance <= def.range + 4 and (distance < 3 or offset.Unit:Dot(direction) >= cosCone) then
				CreatureService.applyDamage(creature, def.damage, player)
				CombatService.Hit:Fire(player, creature.model, def.damage)
				local stunned = CreatureService.stun(creature, arc.stunSeconds, arc.resistWindow, arc.stunImmunitySeconds)
				table.insert(struck, { position = creature.root.Position, stunned = stunned })
			end
		end
		Net.fireClients("WeaponEffect", ExpeditionService.playersOf(expedition), {
			kind = "arc",
			userId = player.UserId,
			origin = origin,
			direction = direction,
			range = def.range,
			struck = struck,
		})
	end
	ProgressionService.addStat(player, "shots_fired", 1)
	CombatService.Fired:Fire(player, def.id, origin)
	CombatService.push(player)
end

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
	if def.arc then
		handleArc(player, state, def, rawOrigin, rawDirection)
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

	-- The launcher's flare bursts high over where it lands and hangs there.
	-- The server finds the landing point with its own ray, so a client cannot
	-- put a flare somewhere the shot could not reach.
	local launcher = def.launcher
	if launcher and expedition then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = if player.Character then { player.Character } else {}
		local ray = Workspace:Raycast(origin, direction * def.range, params)
		local landing = if ray then ray.Position else origin + direction * def.range
		local burst = landing + Vector3.new(0, launcher.burstHeight, 0)
		CreatureService.denyArea(expedition.id, landing, launcher.denyRadius, launcher.hangSeconds)
		-- Something new and bright to investigate, away from the crew.
		CreatureService.hearNoise(expedition.id, landing, launcher.distractLoudness)
		Net.fireClients("WeaponEffect", ExpeditionService.playersOf(expedition), {
			kind = "skyflare",
			position = burst,
			landing = landing,
			seconds = launcher.hangSeconds,
			range = launcher.lightRange,
			revealRadius = launcher.revealRadius,
		})
	end

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

	Net.onServerEvent("WeaponCharge", function(player)
		local state = states[player.UserId]
		local def = if state and state.equipped then WeaponRegistry.get(state.equipped) else nil
		if state and def and def.arc and os.clock() >= state.overheatUntil then
			state.chargeStartedAt = os.clock()
		end
	end)

	-- A new character after a death or a retry carries the same weapon:
	-- ownership and the round's loadout survive, only the body is new.
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			task.wait(0.5)
			attachHeld(player)
		end)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function()
			task.wait(0.5)
			attachHeld(player)
		end)
	end

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
				-- A premium firearm starts the run with its own rounds, so it is
				-- never an empty gun. Found ammunition tops it up as normal.
				local primary = WeaponRegistry.get(profile.loadout.primaryWeapon)
				if primary and primary.startingRounds and primary.ammoType then
					local ammoItem = ammoItemFor(primary.ammoType)
					if ammoItem then
						InventoryService.add(player, ammoItem, primary.startingRounds, true)
					end
				end
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
			attachHeld(player)
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
