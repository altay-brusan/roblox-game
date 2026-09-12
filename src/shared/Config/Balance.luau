--!strict
--[[
	Balance
	-------
	Tuning numbers for survival, the train, combat, threat and economy.
	Isolated from logic so the game can be re-tuned without touching systems.

	Units used throughout:
	  distance  studs (1 stud is treated as 0.28 m for display only)
	  speed     studs per second
	  time      seconds
	  weight    kilograms, an abstract carry budget
]]

local Balance = {}

--------------------------------------------------------------------------
-- Player vitals
--------------------------------------------------------------------------

Balance.Player = {
	maxHealth = 100,
	-- Passive regeneration is deliberately tiny. It removes the tedium of
	-- chip damage without making bandages pointless.
	healthRegenPerSecond = 0.35,
	healthRegenDelay = 22,

	maxStamina = 100,
	sprintDrainPerSecond = 13,
	staminaRegenPerSecond = 9,
	staminaRegenDelay = 1.4,
	-- Below this, sprint is locked out until stamina passes the recovery gate.
	staminaExhaustedAt = 0,
	staminaRecoverGate = 22,

	walkSpeed = 14,
	sprintSpeed = 23,
	crouchSpeed = 7,
	aimSpeed = 9,
	carryHeavySpeedMultiplier = 0.78,

	jumpPower = 42,
	fallDamageThreshold = 42, -- studs of fall before damage begins
	fallDamagePerStud = 2.1,

	-- Carry budget. Cargo Rigging adds to both, and that is the only paid
	-- product that touches any number in this file.
	baseInventorySlots = 18,
	baseCarryWeight = 42,
	quickSlots = 5,
}

Balance.Flashlight = {
	maxCharge = 100,
	drainPerSecond = 0.55,
	-- Flicker starts here, giving a clear warning before darkness.
	lowChargeWarning = 22,
	criticalCharge = 8,
	batteryRestore = 55,
	range = 78,
	angle = 42,
	brightness = 2.6,
	-- A dying light is a horror beat, not a stealth mechanic: the creature does
	-- not track light level, so a low battery never makes players safer.
	colour = Color3.fromRGB(255, 243, 214),
}

--------------------------------------------------------------------------
-- Train
--------------------------------------------------------------------------

Balance.Train = {
	-- Acceleration is deliberately slow. A train that starts instantly does not
	-- feel like a train, and the wind-up is where the tension lives.
	maxSpeed = 92,
	accelerationPerNotch = 3.4,
	notches = 8,
	coastDeceleration = 1.6,
	serviceBrakeDeceleration = 7.5,
	emergencyBrakeDeceleration = 19,
	-- Emergency braking is punishing on purpose: it costs condition and wakes
	-- things up, so it is a real decision rather than a free stop.
	emergencyBrakeConditionCost = 4,
	emergencyBrakeNoiseRadius = 900,

	reverseMaxSpeed = 18,

	maxFuel = 100,
	fuelPerStudAtFullSpeed = 0.00042,
	fuelIdleDrainPerSecond = 0.012,
	fuelCanRestore = 26,

	maxCondition = 100,
	conditionDriftPerMinute = 0.9,
	repairKitRestore = 22,
	-- Below this the train cannot depart a station until repaired.
	conditionDepartureMinimum = 15,
	-- Below this, failures begin: lights cut, doors stick, the engine stalls.
	conditionFailureThreshold = 40,

	headlightRange = 260,
	hornNoiseRadius = 1400,
	doorOpenSeconds = 1.6,
	wiperCycleSeconds = 1.35,

	-- Passengers are welded to a carriage platform rather than relying on
	-- friction. Rolling stock plus Roblox physics plus six players equals
	-- players sliding off the back, every time, without this.
	passengerAnchorRadius = 3.2,
	boardingSpeedLimit = 6,
}

--------------------------------------------------------------------------
-- Combat
--------------------------------------------------------------------------

Balance.Combat = {
	-- Server tolerance for client-reported hits. Generous enough for a 250 ms
	-- connection, tight enough that a teleporting client is rejected.
	hitPositionTolerance = 14,
	maxHitDistanceGrace = 1.25, -- multiplier on a weapon's stated range
	fireIntervalGrace = 0.06,

	headshotMultiplier = 2.1,
	limbMultiplier = 0.82,

	-- Noise made by weapons, feeding the threat director.
	noiseRadiusMelee = 55,
	noiseRadiusSuppressed = 180,
	noiseRadiusFirearm = 620,

	meleeStaminaCost = 8,
	-- Firearms are scarce by design: ammunition is a resource decision, and
	-- most encounters are meant to be avoided rather than won.
	startingAmmoFraction = 0.4,
}

--------------------------------------------------------------------------
-- Downed state and revival
--------------------------------------------------------------------------

Balance.Downed = {
	-- A downed player bleeds out over this window and can be revived the whole
	-- time. The number is long enough to cross a station, which is the point.
	bleedoutSeconds = 95,
	reviveSeconds = 12, -- overridden per difficulty
	reviveHealthFraction = 0.45,
	selfReviveHealthFraction = 0.40,
	-- Crawling keeps a downed player an actor rather than a spectator.
	crawlSpeed = 3.2,
	-- Each subsequent down in one expedition shortens the next bleedout.
	bleedoutDecayPerDown = 0.85,
	minBleedoutSeconds = 40,
	-- Dropped on death, recoverable from the body by teammates.
	dropFractionOnDeath = 0.5,
	spectatorSwitchCooldown = 0.6,
}

--------------------------------------------------------------------------
-- Threat and horror direction
--------------------------------------------------------------------------

Balance.Threat = {
	-- Threat is a 0-100 meter driven by noise, light, time spent away from the
	-- train, and objective progress. The director reads it to decide what to
	-- schedule. It is never shown to players as a number.
	baseline = 8,
	decayPerSecond = 0.55,
	noisePerGunshot = 14,
	noisePerEmergencyBrake = 18,
	noisePerHorn = 9,
	noisePerGenerator = 6,
	perSecondAwayFromTrain = 0.32,
	perSecondAlone = 0.18,
	objectiveCompleteRelief = -12,

	-- Escalation bands. The director will not schedule a band-3 event while
	-- threat sits in band 1, which is what stops the random jumpscare feeling.
	bands = { 0, 25, 55, 80 },

	-- Minimum quiet between any two scheduled events, and a longer floor on
	-- repeating the same event type.
	globalCooldown = 42,
	perEventCooldown = 150,
	-- After a major encounter the director enforces genuine relief. Horror
	-- without quiet stops working after about ten minutes.
	postEncounterCalm = 75,

	-- Hard safety rails. The director will never fire anything while any of
	-- these hold, which is how "no unavoidable deaths during loading" is
	-- actually guaranteed rather than hoped for.
	blockedDuringCinematic = true,
	blockedDuringLoading = true,
	respawnImmunitySeconds = 6,
	boardingImmunitySeconds = 3,
}

Balance.Creature = {
	-- The Signal-Eater. Hunts by sound, investigates light, and loses interest
	-- when a target breaks line of sight and stays quiet.
	hearingRadius = 420,
	sightRadius = 165,
	sightAngle = 118,
	investigateSeconds = 18,
	chaseSeconds = 26,
	loseInterestSeconds = 9,

	patrolSpeed = 9,
	investigateSpeed = 15,
	chaseSpeed = 22,

	attackRange = 7.5,
	attackDamage = 34,
	attackCooldown = 2.2,

	-- Counterplay: it will not enter lit carriages, it recoils from the horn at
	-- close range, and flares deny an area for a while.
	repelledByHorn = true,
	hornRepelRadius = 60,
	flareDenialSeconds = 24,
	flareDenialRadius = 45,
	avoidsLitTrain = true,

	-- It cannot be killed, only driven off. Damage extends the driven-off timer
	-- so weapons still matter without turning the game into a shooter.
	drivenOffSeconds = 45,
	damageToDriveOff = 120,
}

--------------------------------------------------------------------------
-- Economy and progression
--------------------------------------------------------------------------

Balance.Economy = {
	-- Credits are the free currency. Everything cosmetic can eventually be
	-- earned with them; Robux buys time and a few exclusive finishes.
	creditsPerStationCleared = 120,
	creditsPerOptionalObjective = 65,
	creditsPerExpeditionComplete = 400,
	creditsPerRescue = 45,
	creditsPerCollectible = 30,
	creditsFailurePenaltyFraction = 0.4, -- kept on a failed run, not zero

	xpPerStationCleared = 90,
	xpPerOptionalObjective = 45,
	xpPerExpeditionComplete = 320,
	xpPerRescue = 60,

	-- Cooperation pays more than solo grinding, without making solo unviable.
	crewBonusPerMember = 0.06,
	maxCrewBonus = 0.30,

	dailyLoginCredits = { 100, 150, 200, 275, 350, 450, 700 },
	-- Streaks are forgiving: missing a day steps the streak back by one rather
	-- than resetting it, and nothing is ever taken away.
	streakGraceDays = 1,
	playtimeRewardIntervalSeconds = 900,
	playtimeRewardCredits = 85,
	maxPlaytimeRewardsPerDay = 6,
}

Balance.Progression = {
	maxLevel = 60,
	-- Curve: gentle early so the first few levels arrive quickly, then linear.
	baseXp = 420,
	xpGrowth = 1.085,
	xpLinearAfterLevel = 25,
	xpLinearStep = 2600,
}

--- XP needed to go from `level` to `level + 1`.
function Balance.xpForLevel(level: number): number
	local p = Balance.Progression
	if level >= p.maxLevel then
		return math.huge
	end
	if level < p.xpLinearAfterLevel then
		return math.floor(p.baseXp * (p.xpGrowth ^ (level - 1)))
	end
	local atTransition = math.floor(p.baseXp * (p.xpGrowth ^ (p.xpLinearAfterLevel - 1)))
	return atTransition + (level - p.xpLinearAfterLevel) * p.xpLinearStep
end

--------------------------------------------------------------------------
-- Crew scaling
--------------------------------------------------------------------------

-- Objective requirements and threat pressure scale with crew size so a solo
-- run is genuinely completable and a six-player run is not trivial.
Balance.CrewScaling = {
	[1] = { objectiveQuantity = 1.0, threat = 0.78, loot = 1.0, creatureCount = 1 },
	[2] = { objectiveQuantity = 1.25, threat = 0.9, loot = 1.15, creatureCount = 1 },
	[3] = { objectiveQuantity = 1.5, threat = 1.0, loot = 1.3, creatureCount = 1 },
	[4] = { objectiveQuantity = 1.75, threat = 1.12, loot = 1.45, creatureCount = 2 },
	[5] = { objectiveQuantity = 2.0, threat = 1.22, loot = 1.6, creatureCount = 2 },
	[6] = { objectiveQuantity = 2.25, threat = 1.32, loot = 1.75, creatureCount = 2 },
}

function Balance.crewScaling(size: number)
	return Balance.CrewScaling[math.clamp(math.floor(size), 1, 6)]
end

--------------------------------------------------------------------------
-- Anti-grief
--------------------------------------------------------------------------

Balance.AntiGrief = {
	-- Doors a player closed cannot be re-locked by the same player immediately,
	-- which defeats the standard door-spam grief without annoying real play.
	doorToggleCooldown = 1.1,
	doorToggleBurstLimit = 5,
	doorToggleBurstWindow = 8,

	-- Essential items cannot be destroyed, and dropping one inside the train
	-- places it in the supply rack rather than the floor.
	essentialItemsIndestructible = true,

	-- Emergency brake spam is rate limited per player, not globally, so one
	-- player cannot hold a crew hostage.
	emergencyBrakeCooldown = 12,

	-- Repeated friendly interference is tracked and reported to the crew leader
	-- rather than auto-punished, because false positives are worse than grief.
	interferenceReportThreshold = 4,
}

return Balance
