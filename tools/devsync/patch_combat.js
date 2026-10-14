const fs = require("fs");
const f = "server/Services/CombatService.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 70)); s = s.replace(a, b); }

// ---------------------------------------------------------------- state
rep(`	lastFiredAt: number,
	lastSwingAt: number,
}`, `	lastFiredAt: number,
	lastSwingAt: number,
	-- Arc Rail Projector. Heat decays continuously, so it is stored with the
	-- time it was last written and resolved on read.
	heat: number,
	heatAt: number,
	overheatUntil: number,
	chargeStartedAt: number?,
}`);
rep(`		lastFiredAt = 0,
		lastSwingAt = 0,
	}
	states[player.UserId] = created`, `		lastFiredAt = 0,
		lastSwingAt = 0,
		heat = 0,
		heatAt = 0,
		overheatUntil = 0,
		chargeStartedAt = nil,
	}
	states[player.UserId] = created`);

// ---------------------------------------------------------------- held model + heat helpers, before equip
rep(`function CombatService.equip(player: Player, weaponId: string?): (boolean, string?)`, `local function finishFor(player: Player): WeaponModels.Finish?
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

function CombatService.equip(player: Player, weaponId: string?): (boolean, string?)`);

rep(`	if not weaponId then
		state.equipped = nil
		state.reloading = false
		return true, nil
	end`, `	if not weaponId then
		state.equipped = nil
		state.reloading = false
		attachHeld(player)
		return true, nil
	end`);

// Loading the first magazine takes the rounds out of the inventory. It used
// to set the magazine without removing them, which copied ammunition.
rep(`		local available = if ammoItem then InventoryService.countOf(player, ammoItem) else 0
		local wanted = math.floor((def.magazineSize or 1) * Balance.Combat.startingAmmoFraction + 0.5)
		state.magazine = math.min(def.magazineSize or 1, math.max(0, math.min(wanted, available)))
	else
		state.magazine = 0
	end
	CombatService.push(player)`, `		local available = if ammoItem then InventoryService.countOf(player, ammoItem) else 0
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
	CombatService.push(player)`);

// ---------------------------------------------------------------- push
rep(`		reloading = state.reloading,
		reloadRemaining = if state.reloading then math.max(0, state.reloadDuration - (os.clock() - state.reloadStartedAt)) else 0,
	})`, `		reloading = state.reloading,
		reloadRemaining = if state.reloading then math.max(0, state.reloadDuration - (os.clock() - state.reloadStartedAt)) else 0,
		heat = if def and def.arc then heatOf(state, def) else nil,
		overheatRemaining = if def and def.arc then math.max(0, state.overheatUntil - os.clock()) else nil,
	})`);

// ---------------------------------------------------------------- arc + launcher in handleFire
rep(`	if state.reloading then
		return
	end
	if state.magazine <= 0 then
		return
	end

	local now = os.clock()`, `	if def.arc then
		handleArc(player, state, def, rawOrigin, rawDirection)
		return
	end
	if state.reloading then
		return
	end
	if state.magazine <= 0 then
		return
	end

	local now = os.clock()`);

rep(`local function handleFire(player: Player, rawOrigin: any, rawDirection: any, rawHitInstance: any, rawHitPosition: any)`, `--------------------------------------------------------------------------
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

local function handleFire(player: Player, rawOrigin: any, rawDirection: any, rawHitInstance: any, rawHitPosition: any)`);

rep(`	-- Flare rounds deny ground where they land, which is the whole point of
	-- carrying a flare pistol.`, `	-- The launcher's flare bursts high over where it lands and hangs there.
	-- The server finds the landing point with its own ray, so a client cannot
	-- put a flare somewhere the shot could not reach.
	local launcher = def.launcher
	if launcher and expedition then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { player.Character :: Instance }
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
	-- carrying a flare pistol.`);

// ---------------------------------------------------------------- start(): charge remote, starting rounds, re-attach on respawn
rep(`	Net.onServerEvent("WeaponReload", function(player)
		CombatService.reload(player)
	end)`, `	Net.onServerEvent("WeaponReload", function(player)
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
	end`);

rep(`			if profile then
				CombatService.equip(player, profile.loadout.primaryWeapon)`, `			if profile then
				-- A premium firearm starts the run with its own rounds, so it is
				-- never an empty gun. Found ammunition tops it up as normal.
				local primary = WeaponRegistry.get(profile.loadout.primaryWeapon)
				if primary and primary.startingRounds and primary.ammoType then
					local ammoItem = ammoItemFor(primary.ammoType)
					if ammoItem then
						InventoryService.add(player, ammoItem, primary.startingRounds, true)
					end
				end
				CombatService.equip(player, profile.loadout.primaryWeapon)`);

rep(`	ExpeditionService.Ended:Connect(function(expedition)
		for _, player in ExpeditionService.playersOf(expedition) do
			states[player.UserId] = nil
		end
	end)`, `	ExpeditionService.Ended:Connect(function(expedition)
		for _, player in ExpeditionService.playersOf(expedition) do
			states[player.UserId] = nil
			attachHeld(player)
		end
	end)`);

// ---------------------------------------------------------------- requires
rep(`local WeaponRegistry = require(Shared.Registry.WeaponRegistry)`, `local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
local WeaponModels = require(Shared.Registry.WeaponModels)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)`);
rep(`local CombatService = {}`, `local CombatService = {}

local handleArc: (Player, any, WeaponRegistry.WeaponDef, any, any) -> ()`);
fs.writeFileSync(f, s);
console.log("ok");
