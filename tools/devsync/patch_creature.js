const fs = require("fs");
const f = "server/Services/CreatureService.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 60)); s = s.replace(a, b); }
rep(`	lastAttackAt: number,
	lastCallAt: number,`, `	lastAttackAt: number,
	lastCallAt: number,
	-- Stunned by the Arc Rail Projector: frozen until this time. Stuns weaken
	-- with repetition and cannot be chained; see CreatureService.stun.
	stunnedUntil: number,
	stunImmuneUntil: number,
	recentStuns: { number },`);
rep(`		driveOffMeter = 0,`, `		driveOffMeter = 0,
		stunnedUntil = 0,
		stunImmuneUntil = 0,
		recentStuns = {},`);
rep(`	local now = os.clock()
	local target, targetPosition, targetDistance = nearestTarget(creature, expedition)`, `	local now = os.clock()
	if now < creature.stunnedUntil then
		-- Locked rigid by the arc. It does nothing, which is the point, and
		-- for no longer than CreatureService.stun allows.
		return
	end
	local target, targetPosition, targetDistance = nearestTarget(creature, expedition)`);
rep(`--- A flare, a burning brazier or a lit carriage: ground it will not cross.`, `--- Freezes the creature for up to \`seconds\`. It learns: every stun in the last
--- \`resistWindow\` seconds halves the next one, and after a stun ends it cannot
--- be stunned again for \`immunitySeconds\`. Returns the seconds actually
--- applied, 0 when it shrugged the stun off, so the weapon can say so.
function CreatureService.stun(creature: Creature, seconds: number, resistWindow: number, immunitySeconds: number): number
	local now = os.clock()
	if now < creature.stunnedUntil or now < creature.stunImmuneUntil then
		return 0
	end
	local recent = {}
	for _, at in creature.recentStuns do
		if now - at < resistWindow then
			table.insert(recent, at)
		end
	end
	local applied = seconds * (0.5 ^ #recent)
	if applied < 0.4 then
		creature.recentStuns = recent
		return 0
	end
	table.insert(recent, now)
	creature.recentStuns = recent
	creature.stunnedUntil = now + applied
	creature.stunImmuneUntil = now + applied + immunitySeconds
	log.debug(string.format("%s stunned for %.1fs", creature.id, applied))
	return applied
end

--- A flare, a burning brazier or a lit carriage: ground it will not cross.`);
fs.writeFileSync(f, s);
console.log("ok");
