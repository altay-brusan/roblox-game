--!strict
--[[
	SignalRegistry
	--------------
	The authored signal calls that the Signal Integrity Analyzer works on.

	Every call has a hidden truth: a real HUMAN, an ECHO (a recording of
	someone who is not there), a MIMIC (something using a voice), or an
	ANOMALY (no one at all). The truth lives only in this file and on the
	server; clients only ever receive the evidence a crew has gathered.

	Evidence comes from six channels, and no single channel decides a call:
	  bearing     two sweeps from different spots are triangulated by the
	              server from the call's real source; compared with where the
	              caller claims to be. Pure geometry, not authored.
	  waveform    what the signal looks like (authored per call)
	  timing      timestamp, dispatch ID, kilometre post (authored)
	  challenge   ask the caller a question, hear the reply (authored)
	  clue        a physical clue at the place the caller names (authored)
	  compare     two calls side by side: shared phrasing (authored links)

	Each authored item carries `weight`, its support for
	{ human, echo, mimic, anomaly }. The confidence label is computed from the
	weights of the evidence a crew has actually collected.

	Some calls are built to be hard: a real child behind heavy interference,
	a mimic that spoofs a clean waveform. Cautious investigation solves both.
]]

local TableUtil = require(game:GetService("ReplicatedStorage").LastSignal.Core.TableUtil)

export type Truth = "human" | "echo" | "mimic" | "anomaly"
-- Support for { human, echo, mimic, anomaly }.
export type Weight = { number }

export type Evidence = { text: string, weight: Weight }

export type Question = { ask: string, reply: string, weight: Weight }

export type CallDef = {
	id: string,
	station: number,
	-- Seconds after arriving at the station.
	delay: number,
	caller: string, -- how the notebook labels it before anyone knows
	transcript: { string },
	-- Where the caller says they are: a landmark id at this station.
	claims: string,
	-- Where the signal really comes from: a landmark id, plus an offset in
	-- studs (a mimic is usually out in the trees, not where it says).
	source: string,
	sourceOffset: Vector3,
	-- Interference (steel structures, a dead handset) scatters bearings.
	interference: number,
	truth: Truth,
	waveform: Evidence,
	waveShape: string, -- what the analyzer screen draws
	timing: Evidence,
	questions: { Question },
	-- The physical clue, placed at the claimed landmark.
	clue: Evidence,
	-- Phrases shared with other calls, for the compare channel.
	phrases: { string },
	-- What happens. `go`: someone answered the call in person. `mark`:
	-- the crew marked it a mimic.
	onGo: string,
	onMark: string,
}

local H, E, M, A = 1, 2, 3, 4
local function w(h: number, e: number, m: number, a: number): Weight
	local out = { 0, 0, 0, 0 }
	out[H], out[E], out[M], out[A] = h, e, m, a
	return out
end

local CALLS: { CallDef } = {
	----------------------------------------------------------------------
	-- Marrow Halt: the tutorial. One real person, one harmless anomaly.
	----------------------------------------------------------------------
	{
		id = "marrow_porter",
		station = 1,
		delay = 20,
		caller = "Woman, station house",
		transcript = {
			"Is someone there? On the radio? This is Marrow Halt, I'm in the station house.",
			"The door's jammed from the outside. I've been in here since the lights went. Please.",
		},
		claims = "station_house",
		source = "station_house",
		sourceOffset = Vector3.new(0, 0, 0),
		interference = 0,
		truth = "human",
		waveform = { text = "Ordinary speech: uneven breathing, natural pitch drift, a voice that cracks.", weight = w(2, 1, 0, 0) },
		waveShape = "clean",
		timing = { text = "Timestamp 02:33, two minutes after you stopped. Handset ID matches the halt's own line.", weight = w(2, 0, 0, 0) },
		questions = {
			{ ask = "What's painted on the station house door?", reply = "A two. A white number two, half flaked off. Why does that matter?", weight = w(2, 0, -1, 0) },
			{ ask = "How long have you been in there?", reply = "Since the lights went. I stopped counting. Days. Is it days?", weight = w(1, 0, 0, 0) },
		},
		clue = { text = "Fresh footprints in the dust of the station house step, one set, going in. The door is wedged shut with a fallen sign.", weight = w(2, -1, -1, 0) },
		phrases = {},
		onGo = "survivor:Edith Marr, relief porter. She has been here eleven days.",
		onMark = "lost:Nobody calls from the station house again.",
	},
	{
		id = "marrow_tannoy",
		station = 1,
		delay = 75,
		caller = "Announcement",
		transcript = {
			"The. Zero. Two. Seventeen. Is. Delayed. We apologise. For. The.",
		},
		claims = "water_tower",
		source = "water_tower",
		sourceOffset = Vector3.new(0, 0, 0),
		interference = 0.2,
		truth = "anomaly",
		waveform = { text = "No breath, no voice: stitched recorded words with machine gaps. A tannoy, not a person.", weight = w(-1, 1, 0, 2) },
		waveShape = "mechanical",
		timing = { text = "No timestamp at all. The tannoy circuit has no clock.", weight = w(0, 0, 0, 1) },
		questions = {
			{ ask = "Who is this?", reply = "[No reply. The announcement starts again from the beginning.]", weight = w(-1, 1, 0, 1) },
		},
		clue = { text = "A tannoy horn on the water tower, wires chewed through, still humming.", weight = w(0, 0, 0, 2) },
		phrases = {},
		onGo = "anomaly:Just the old tannoy, talking to nobody.",
		onMark = "anomaly:Just the old tannoy. Nothing was listening.",
	},

	----------------------------------------------------------------------
	-- Tolbridge Camp: the first real dilemma.
	----------------------------------------------------------------------
	{
		id = "tolbridge_saw",
		station = 2,
		delay = 25,
		caller = "Man, saw shed",
		transcript = {
			"Help me. I'm trapped in the saw shed. There's fuel in here, cans of it, all you can carry.",
			"Come alone, it's quicker. Come alone.",
		},
		claims = "sawshed",
		source = "sawshed",
		sourceOffset = Vector3.new(-90, 0, 70),
		interference = 0,
		truth = "mimic",
		waveform = { text = "Clean speech, but every breath is identical: the same breath, copied.", weight = w(-1, 1, 2, 0) },
		waveShape = "loop",
		timing = { text = "Timestamp 02:51, eleven minutes in the future.", weight = w(-2, 0, 2, 1) },
		questions = {
			{ ask = "Which way does the saw shed door face?", reply = "The door faces the door. Come alone. It's quicker.", weight = w(-2, 0, 2, 0) },
			{ ask = "What's your name?", reply = "A name. Yes. Come alone.", weight = w(-2, 0, 2, 0) },
		},
		clue = { text = "The saw shed handset is thick with dust. Nobody has lifted it in days.", weight = w(-2, 0, 2, 0) },
		phrases = { "come alone" },
		onGo = "trap:Nobody in the shed. Something was out in the trees, and now it knows where you are.",
		onMark = "cache:Marked as a mimic. With nothing waiting, the fuel in the saw shed is there to take.",
	},
	{
		id = "tolbridge_loader",
		station = 2,
		delay = 70,
		caller = "Men, the loader",
		transcript = {
			"Loader's jammed again, Pete, give it a kick. No, the other side. There.",
			"[The same nine seconds, again.] Loader's jammed again, Pete...",
		},
		claims = "loader",
		source = "loader",
		sourceOffset = Vector3.new(0, 0, 0),
		interference = 0.1,
		truth = "echo",
		waveform = { text = "Two natural voices, but the same nine seconds repeat exactly: a tape loop.", weight = w(0, 3, 0, 0) },
		waveShape = "loop",
		timing = { text = "Timestamp eleven days old: the night the line went quiet.", weight = w(-1, 2, 0, 0) },
		questions = {
			{ ask = "Pete? Can you hear me?", reply = "[No reply. 'Loader's jammed again, Pete...']", weight = w(-1, 2, 0, 0) },
		},
		clue = { text = "A dictaphone on the loader seat, the tape worn thin, still turning.", weight = w(0, 3, -1, 0) },
		phrases = {},
		onGo = "echo:A dictaphone on the loader seat. The last shift at Tolbridge, on a loop.",
		onMark = "echo:It was only a recording. Nothing was using it.",
	},
	{
		id = "tolbridge_child",
		station = 2,
		delay = 120,
		caller = "Child, very faint",
		transcript = {
			"...can anyone... I'm in the... bunkhouse... my dad went to the line and...",
			"...please don't be the other voice...",
		},
		claims = "bunkhouse",
		source = "bunkhouse",
		sourceOffset = Vector3.new(0, 0, 0),
		interference = 1.0,
		truth = "human",
		waveform = { text = "Heavy interference, a handheld set on a flat battery. Under the noise: uneven, natural breathing.", weight = w(1, 0, 0, 0) },
		waveShape = "noise",
		timing = { text = "No timestamp: a toy radio with no clock. Nothing to check, either way.", weight = w(0, 0, 0, 0) },
		questions = {
			{ ask = "What's your dad's name?", reply = "Tom. Tom Adey. He drives the loader. Did you see him?", weight = w(2, 0, -1, 0) },
			{ ask = "Come to the train on your own.", reply = "No! It said that too. The other voice. It says come alone.", weight = w(2, 0, -1, 0) },
		},
		clue = { text = "Small boots in the dust of the bunkhouse floor, going in, not out. A half-eaten ration. 'T. ADEY' stencilled on a locker.", weight = w(3, -1, -1, 0) },
		phrases = { "come alone" },
		onGo = "survivor:Lily Adey, nine. She has been hiding from the other voice.",
		onMark = "lost:The bunkhouse radio goes quiet. It does not come back.",
	},

	----------------------------------------------------------------------
	-- Ninety-Three: the mimic learns Control's voice; a recording that
	-- should not exist.
	----------------------------------------------------------------------
	{
		id = "ninetythree_control",
		station = 3,
		delay = 30,
		caller = "Control?",
		transcript = {
			"Control to the zero two seventeen. Leave the train and walk to the gantry. I will meet you there.",
			"You are the last one out. Out. Out.",
		},
		claims = "gantry",
		source = "gantry",
		sourceOffset = Vector3.new(110, 0, -60),
		interference = 0,
		truth = "mimic",
		waveform = { text = "A clean, convincing waveform. Too clean: no line noise at all on a hundred miles of wire.", weight = w(0, 0, 1, 0) },
		waveShape = "clean",
		timing = { text = "Dispatch ID 4471. Control signs as 0217-C. 4471 is not a Control ID.", weight = w(-2, 0, 2, 0) },
		questions = {
			{ ask = "Control, what did you say as we left the yard?", reply = "You are the last one out. Out. Out. Out.", weight = w(-1, 1, 2, 0) },
		},
		clue = { text = "The gantry ladder is rusted solid. Nobody has climbed it to meet anyone.", weight = w(-1, 0, 2, 0) },
		phrases = { "the last one out" },
		onGo = "trap:Nobody at the gantry. The voice was Control's, and it was not Control.",
		onMark = "cache:Marked as a mimic. The relay spares in the gantry cabinet are yours.",
	},
	{
		id = "ninetythree_crew",
		station = 3,
		delay = 85,
		caller = "Your own crew?",
		transcript = {
			"This is the zero two seventeen. We're at Hallow Bridge. The span is down and the pumps won't prime.",
			"If anyone gets this: do not trust the voice at Ward Hill. Do not.",
		},
		claims = "relay_room",
		source = "relay_room",
		sourceOffset = Vector3.new(0, 0, 0),
		interference = 0.2,
		truth = "echo",
		waveform = { text = "Natural voices, recorded: tape hiss under them. One of them sounds like you.", weight = w(0, 2, 0, 0) },
		waveShape = "clean",
		timing = { text = "Timestamp: tonight, forty minutes from now. Recorded at Hallow Bridge, which you have not reached.", weight = w(-1, 2, 0, 1) },
		questions = {
			{ ask = "Who is speaking?", reply = "[No reply. 'This is the zero two seventeen. We're at Hallow Bridge...']", weight = w(-1, 2, 0, 0) },
		},
		clue = { text = "A reel recorder in the relay room, its reel labelled in your handwriting: 'HALLOW. PLAY AT 93.'", weight = w(0, 3, 0, 0) },
		phrases = { "the zero two seventeen" },
		onGo = "echo:A reel labelled in your own handwriting. Someone on this train will record it, later tonight.",
		onMark = "echo:It was a recording. Of you.",
	},

	----------------------------------------------------------------------
	-- Hallow Bridge: steel bends bearings; the river talks.
	----------------------------------------------------------------------
	{
		id = "hallow_ganger",
		station = 4,
		delay = 30,
		caller = "Man, pump house",
		transcript = {
			"Permanent way gang. I'm in the pump house. I can prime the pumps if you get the depot open.",
			"Code's on the depot door. I chalked it before I hid.",
		},
		claims = "pump_house",
		source = "pump_house",
		sourceOffset = Vector3.new(0, 0, 0),
		interference = 0.7,
		truth = "human",
		waveform = { text = "Natural speech, distorted: the bridge steel is scattering the signal.", weight = w(1, 0, 0, 0) },
		waveShape = "noise",
		timing = { text = "Timestamp 03:20, now. Kilometre post 10.4, the bridge.", weight = w(2, 0, 0, 0) },
		questions = {
			{ ask = "What's the depot code?", reply = "Four, one, one. Same as the old line number.", weight = w(2, 0, -1, 0) },
		},
		clue = { text = "Chalk on the depot door: 411. The chalk is fresh.", weight = w(2, 0, -1, 0) },
		phrases = {},
		onGo = "survivor:Ray Okafor, ganger. He kept the pumps alive as long as he could.",
		onMark = "lost:The pump house goes silent.",
	},
	{
		id = "hallow_river",
		station = 4,
		delay = 80,
		caller = "Someone in the water",
		transcript = {
			"I fell. I'm in the water under the span. Jump. It's not deep. Jump in.",
		},
		claims = "span",
		source = "span",
		sourceOffset = Vector3.new(60, -10, 40),
		interference = 0.3,
		truth = "mimic",
		waveform = { text = "Phase reversed: the words arrive before the breath that should carry them.", weight = w(-2, 0, 3, 0) },
		waveShape = "phase",
		timing = { text = "Kilometre post 11.8. That post is on the far bank, a kilometre away.", weight = w(-1, 0, 1, 1) },
		questions = {
			{ ask = "How did you fall?", reply = "Jump. It's not deep. How did you fall?", weight = w(-2, 0, 2, 0) },
		},
		clue = { text = "Wet handprints on the span rail, on the outside, going down. None coming up.", weight = w(-1, 0, 2, 0) },
		phrases = {},
		onGo = "trap:The river was empty. The span was not.",
		onMark = "cache:Marked as a mimic. The depot's flood locker is safe to open.",
	},
	{
		id = "hallow_telemetry",
		station = 4,
		delay = 130,
		caller = "Tones",
		transcript = {
			"[Three rising tones. A pause. Three rising tones.]",
		},
		claims = "span",
		source = "span",
		sourceOffset = Vector3.new(0, 0, 0),
		interference = 0.5,
		truth = "anomaly",
		waveform = { text = "Pure machine tones on a schedule: the span's lift telemetry, still reporting.", weight = w(-1, 0, 0, 3) },
		waveShape = "mechanical",
		timing = { text = "Every ninety seconds exactly, since eleven days ago.", weight = w(0, 1, 0, 1) },
		questions = {
			{ ask = "Is anyone there?", reply = "[Three rising tones.]", weight = w(-1, 0, 0, 1) },
		},
		clue = { text = "A telemetry box on the span, its lamp blinking in time with the tones.", weight = w(0, 0, 0, 3) },
		phrases = {},
		onGo = "anomaly:The bridge, talking to a control room that no longer listens.",
		onMark = "anomaly:Only telemetry. Nothing heard you.",
	},

	----------------------------------------------------------------------
	-- Ward Hill: the truth, and the last voice.
	----------------------------------------------------------------------
	{
		id = "wardhill_engineer",
		station = 8,
		delay = 25,
		caller = "Woman, accommodation",
		transcript = {
			"I'm in the accommodation block. The voice in the relay hall isn't Control. It's a loop. I made it.",
			"I recorded his last shift so the trains would keep moving. Don't trust the loop.",
		},
		claims = "accommodation",
		source = "accommodation",
		sourceOffset = Vector3.new(0, 0, 0),
		interference = 0.1,
		truth = "human",
		waveform = { text = "Natural speech, a smoker's rasp, crying at the end of a sentence.", weight = w(2, 0, 0, 0) },
		waveShape = "clean",
		timing = { text = "Timestamp now. Handset ID: Ward Hill accommodation, extension 4.", weight = w(2, 0, 0, 0) },
		questions = {
			{ ask = "Whose voice is on the loop?", reply = "My husband's. He was Control. He went out to the mast and didn't come back.", weight = w(2, 0, -1, 0) },
		},
		clue = { text = "A bed slept in recently. Tins opened this week. A photograph of a man in a dispatcher's jacket.", weight = w(3, -1, -1, 0) },
		phrases = {},
		onGo = "survivor:Ann Hale, relay engineer. She made the recording that guided you.",
		onMark = "lost:The accommodation block goes dark.",
	},
	{
		id = "wardhill_crewvoice",
		station = 8,
		delay = 90,
		caller = "Your crew, outside",
		transcript = {
			"It's us. It's the crew. We're outside the mast door, open it. Come alone, it's quicker.",
		},
		claims = "mast",
		source = "mast",
		sourceOffset = Vector3.new(-120, 0, 30),
		interference = 0,
		truth = "mimic",
		waveform = { text = "Clean speech in a familiar voice, but the syllables don't line up with the breath.", weight = w(-1, 0, 2, 0) },
		waveShape = "phase",
		timing = { text = "Handset ID 0217: the train's own cab radio. Your cab radio is not transmitting.", weight = w(-2, 0, 2, 0) },
		questions = {
			{ ask = "What did we find at Tolbridge?", reply = "Fuel. All you can carry. Come alone, it's quicker.", weight = w(-2, 0, 3, 0) },
		},
		clue = { text = "No footprints at the mast door. The mud there is unbroken.", weight = w(-2, 0, 2, 0) },
		phrases = { "come alone" },
		onGo = "trap:Nobody at the mast door. Your crew was behind you the whole time.",
		onMark = "cache:Marked as a mimic. The mast store is open, and nothing is waiting in it.",
	},
}

local SignalRegistry = {}

SignalRegistry.Calls = TableUtil.deepFreeze(CALLS) :: { CallDef }

SignalRegistry.TruthNames = { "human", "echo", "mimic", "anomaly" }

function SignalRegistry.get(id: string): CallDef?
	for _, def in CALLS do
		if def.id == id then
			return def
		end
	end
	return nil
end

function SignalRegistry.forStation(index: number): { CallDef }
	local out = {}
	for _, def in CALLS do
		if def.station == index then
			table.insert(out, def)
		end
	end
	return out
end

return SignalRegistry
