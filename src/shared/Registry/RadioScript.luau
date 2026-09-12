--!strict
--[[
	RadioScript
	-----------
	Every line the radio speaks in Chapter One.

	The story is told almost entirely through this file plus the environmental
	detail in StationRegistry. There is no exposition dump, and nothing here is
	required reading: every line that carries an objective also exists as text
	in the objective panel, so a player who mutes the radio is never lost.

	THE CENTRAL DEVICE
	------------------
	Some transmissions are not the dispatcher. Those lines are marked
	`source = "other"`. They are distinguishable if a player is paying
	attention, and the tells are consistent and learnable rather than random:

	  1  The dispatcher always opens with a callsign. The other voice never does.
	  2  The dispatcher never uses your username. The other voice does.
	  3  The other voice routes on the creature audio bus, so it carries a
	     faint doubled quality and ducks the music differently.
	  4  The other voice always asks you to do something that separates the crew
	     or opens the train.

	A player who learns those four things is rewarded: following a false
	instruction is survivable but costly, and ignoring it is always safe.
	Nothing in the chapter forces you to gamble on a voice.

	Subtitles are always available and always attribute the line as "Dispatch"
	or "Unknown", because an accessibility feature must not be a spoiler tax:
	the tells above are audio-only, so the subtitle attribution is the
	equivalent information for a player who cannot rely on the audio.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

export type LineSource = "dispatch" | "other" | "crew" | "recording"

export type RadioLine = {
	id: string,
	source: LineSource,
	-- Spoken text, also used verbatim as the subtitle.
	text: string,
	-- Seconds the line occupies, used for subtitle timing and for spacing
	-- transmissions so two never overlap.
	duration: number,
	-- Audio cue name from Config.Audio. When unconfigured the line still shows
	-- as a subtitle, so the story survives a project with no audio IDs.
	cue: string?,
	-- A false instruction. ExpeditionService records whether the crew complied
	-- and adjusts threat accordingly, and the results screen reports it.
	falseInstruction: { action: string, cost: string }?,
}

export type Beat = {
	id: string,
	-- When this beat fires. Interpreted by ExpeditionService.
	trigger: string,
	triggerParams: { [string]: any }?,
	lines: { RadioLine },
	-- Beats marked once fire a single time per expedition.
	once: boolean,
	priority: number,
}

local function line(def: RadioLine): RadioLine
	return def
end

--------------------------------------------------------------------------

local BEATS: { Beat } = {

	----------------------------------------------------------------------
	-- Departure
	----------------------------------------------------------------------
	{
		id = "departure",
		trigger = "expedition_start",
		once = true,
		priority = 100,
		lines = {
			line({
				id = "dep_1",
				source = "dispatch",
				text = "Control to the zero two seventeen. I have you leaving the yard. You are the last one out.",
				duration = 5.5,
				cue = "radio_open",
			}),
			line({
				id = "dep_2",
				source = "dispatch",
				text = "Line is clear as far as Marrow Halt. After that I am reading it off paper, same as you.",
				duration = 5.0,
			}),
			line({
				id = "dep_3",
				source = "dispatch",
				text = "Keep her moving, keep together, and keep the doors shut between stops. I will be here.",
				duration = 5.5,
				cue = "radio_close",
			}),
		},
	},

	----------------------------------------------------------------------
	-- Station 1: Marrow Halt
	----------------------------------------------------------------------
	{
		id = "approach_marrow",
		trigger = "station_approach",
		triggerParams = { station = "marrow_halt" },
		once = true,
		priority = 80,
		lines = {
			line({
				id = "mar_1",
				source = "dispatch",
				text = "Control to zero two seventeen. Marrow Halt ahead. The board is dark so you are doing this by hand.",
				duration = 6.0,
				cue = "radio_open",
			}),
			line({
				id = "mar_2",
				source = "dispatch",
				text = "Generator is in the goods shed, distribution board is in the station house. Power first, then fuel.",
				duration = 6.0,
			}),
		},
	},
	{
		id = "marrow_power_on",
		trigger = "objective_complete",
		triggerParams = { station = "marrow_halt", objective = "restore_power" },
		once = true,
		priority = 70,
		lines = {
			line({
				id = "mar_3",
				source = "dispatch",
				text = "Control. I can see Marrow Halt on the board again. Good work. Fuel point is live now.",
				duration = 5.5,
			}),
		},
	},
	{
		id = "marrow_departure",
		trigger = "station_complete",
		triggerParams = { station = "marrow_halt" },
		once = true,
		priority = 70,
		lines = {
			line({
				id = "mar_4",
				source = "dispatch",
				text = "Control. Before you go. Did anyone else hear that, or was it just my line?",
				duration = 5.0,
			}),
			line({
				id = "mar_5",
				source = "dispatch",
				text = "Never mind. Next stop is Tolbridge. Get going.",
				duration = 4.0,
				cue = "radio_close",
			}),
		},
	},

	----------------------------------------------------------------------
	-- Station 2: Tolbridge Camp
	----------------------------------------------------------------------
	{
		id = "approach_tolbridge",
		trigger = "station_approach",
		triggerParams = { station = "tolbridge_camp" },
		once = true,
		priority = 80,
		lines = {
			line({
				id = "tol_1",
				source = "dispatch",
				text = "Control to zero two seventeen. Tolbridge Camp. There is a timber loader stood across your running line.",
				duration = 6.5,
				cue = "radio_open",
			}),
			line({
				id = "tol_2",
				source = "dispatch",
				text = "Yard interlock has to be released at both ends before it will move. That means two of you, at opposite ends. Talk to each other.",
				duration = 7.5,
			}),
		},
	},
	{
		id = "tolbridge_first_false",
		trigger = "objective_progress",
		triggerParams = { station = "tolbridge_camp", objective = "clear_line", fraction = 0.5 },
		once = true,
		priority = 60,
		lines = {
			line({
				id = "tol_3",
				source = "other",
				text = "Leave the levers. Come back to the train. All of you, right now.",
				duration = 4.5,
				cue = "radio_distort",
				falseInstruction = {
					action = "abandon_objective",
					cost = "The interlock resets and the loader stays where it is.",
				},
			}),
			line({
				id = "tol_4",
				source = "dispatch",
				text = "Control. Ignore that. I did not send it. Finish the interlock.",
				duration = 4.5,
			}),
		},
	},
	{
		id = "tolbridge_complete",
		trigger = "station_complete",
		triggerParams = { station = "tolbridge_camp" },
		once = true,
		priority = 70,
		lines = {
			line({
				id = "tol_5",
				source = "dispatch",
				text = "Control. Line is clear. Listen to me: something is using this frequency that should not have it.",
				duration = 6.5,
			}),
			line({
				id = "tol_6",
				source = "dispatch",
				text = "I will open every transmission with my callsign from here on. Control, to zero two seventeen. Every time. If you do not hear it, it is not me.",
				duration = 9.0,
				cue = "radio_close",
			}),
		},
	},

	----------------------------------------------------------------------
	-- Station 3: Ninety-Three
	----------------------------------------------------------------------
	{
		id = "approach_93",
		trigger = "station_approach",
		triggerParams = { station = "tower_93" },
		once = true,
		priority = 80,
		lines = {
			line({
				id = "n93_1",
				source = "dispatch",
				text = "Control, to zero two seventeen. Ninety-Three. The section past the tower is locked out mechanically.",
				duration = 6.5,
				cue = "radio_open",
			}),
			line({
				id = "n93_2",
				source = "dispatch",
				text = "Someone climbs the tower and reads the frame. Everyone else works the ground levers. Say the numbers out loud, and say them twice.",
				duration = 8.0,
			}),
		},
	},
	{
		id = "n93_mimic_numbers",
		trigger = "objective_progress",
		triggerParams = { station = "tower_93", objective = "release_section", fraction = 0.4 },
		once = true,
		priority = 60,
		lines = {
			line({
				id = "n93_3",
				source = "other",
				text = "Two. Four. One. Three. That is the code. I am reading it from the frame now.",
				duration = 6.0,
				cue = "radio_distort",
				falseInstruction = {
					action = "wrong_code",
					cost = "The frame rejects it loudly, and the noise carries.",
				},
			}),
		},
	},
	{
		id = "n93_dispatcher_warns",
		trigger = "objective_progress",
		triggerParams = { station = "tower_93", objective = "release_section", fraction = 0.6 },
		once = true,
		priority = 60,
		lines = {
			line({
				id = "n93_4",
				source = "dispatch",
				text = "Control, to zero two seventeen. I have not read you any numbers. I cannot see your frame from here. Nobody can.",
				duration = 7.5,
			}),
		},
	},
	{
		id = "n93_complete",
		trigger = "station_complete",
		triggerParams = { station = "tower_93" },
		once = true,
		priority = 70,
		lines = {
			line({
				id = "n93_5",
				source = "dispatch",
				text = "Control, to zero two seventeen. Section released. Next is Hallow Bridge, and the span is going to be up.",
				duration = 7.0,
			}),
			line({
				id = "n93_6",
				source = "dispatch",
				text = "One more thing. I have been on this desk eleven days. In eleven days you are the first crew to answer me.",
				duration = 7.5,
				cue = "radio_close",
			}),
		},
	},

	----------------------------------------------------------------------
	-- Station 4: Hallow Bridge
	----------------------------------------------------------------------
	{
		id = "approach_bridge",
		trigger = "station_approach",
		triggerParams = { station = "hallow_bridge" },
		once = true,
		priority = 80,
		lines = {
			line({
				id = "brg_1",
				source = "dispatch",
				text = "Control, to zero two seventeen. Hallow Bridge. Span is up and the hydraulics are dead.",
				duration = 6.0,
				cue = "radio_open",
			}),
			line({
				id = "brg_2",
				source = "dispatch",
				text = "There is one spare valve in the depot stores. Fit it at the pump house and then hold that ground until the pumps prime. Four minutes, in the open.",
				duration = 9.0,
			}),
		},
	},
	{
		id = "bridge_pumps_running",
		trigger = "step_start",
		triggerParams = { station = "hallow_bridge", step = "run_pumps" },
		once = true,
		priority = 65,
		lines = {
			line({
				id = "brg_3",
				source = "dispatch",
				text = "Control. Pumps are turning. Whatever happens, do not let them stop. Flares if you have them.",
				duration = 6.5,
			}),
		},
	},
	{
		id = "bridge_false_recall",
		trigger = "step_progress",
		triggerParams = { station = "hallow_bridge", step = "run_pumps", fraction = 0.55 },
		once = true,
		priority = 60,
		lines = {
			line({
				id = "brg_4",
				source = "other",
				text = "Open the carriage doors. I am at the train. Let me in.",
				duration = 4.5,
				cue = "radio_distort",
				falseInstruction = {
					action = "open_doors",
					cost = "Something gets into the carriage, and it is still there later.",
				},
			}),
			line({
				id = "brg_5",
				source = "dispatch",
				text = "Control, to zero two seventeen. I am seventy miles from your train. Keep the doors shut.",
				duration = 6.0,
			}),
		},
	},
	{
		id = "bridge_complete",
		trigger = "station_complete",
		triggerParams = { station = "hallow_bridge" },
		once = true,
		priority = 70,
		lines = {
			line({
				id = "brg_6",
				source = "dispatch",
				text = "Control, to zero two seventeen. Span is down. That is the last obstacle between you and Ward Hill.",
				duration = 7.0,
				cue = "radio_close",
			}),
		},
	},

	----------------------------------------------------------------------
	-- Station 5: Ward Hill, and the ending
	----------------------------------------------------------------------
	{
		id = "approach_ward",
		trigger = "station_approach",
		triggerParams = { station = "ward_hill" },
		once = true,
		priority = 80,
		lines = {
			line({
				id = "wrd_1",
				source = "dispatch",
				text = "Control, to zero two seventeen. Ward Hill Relay. This is the one that matters.",
				duration = 5.5,
				cue = "radio_open",
			}),
			line({
				id = "wrd_2",
				source = "dispatch",
				text = "Get the transmitter up and we can put out a real signal, to everyone still out there, all at once.",
				duration = 7.0,
			}),
			line({
				id = "wrd_3",
				source = "dispatch",
				text = "And listen to me very carefully. That relay has been transmitting for eleven days with nobody in the building. Whatever answers you up there is not me.",
				duration = 10.0,
			}),
		},
	},
	{
		id = "ward_mast_power",
		trigger = "step_start",
		triggerParams = { station = "ward_hill", step = "raise_power" },
		once = true,
		priority = 65,
		lines = {
			line({
				id = "wrd_4",
				source = "dispatch",
				text = "Control. Mast is drawing power. Two and a half minutes and you are transmitting.",
				duration = 6.0,
			}),
		},
	},
	{
		id = "ward_the_voice",
		trigger = "step_progress",
		triggerParams = { station = "ward_hill", step = "raise_power", fraction = 0.5 },
		once = true,
		priority = 60,
		lines = {
			line({
				id = "wrd_5",
				source = "other",
				text = "Control, to zero two seventeen. Shut the mast down. You are transmitting my position.",
				duration = 6.5,
				cue = "radio_distort",
				falseInstruction = {
					action = "shutdown_mast",
					cost = "The sequence restarts, and it gets one more chance at you.",
				},
			}),
			line({
				id = "wrd_6",
				source = "dispatch",
				text = "Control, to zero two seventeen. It has my callsign now. It has had eleven days to learn it. Do not shut that mast down.",
				duration = 8.5,
			}),
		},
	},
	{
		id = "ending_success",
		trigger = "expedition_success",
		once = true,
		priority = 100,
		lines = {
			line({
				id = "end_1",
				source = "dispatch",
				text = "Control, to zero two seventeen. Signal is out. It is out across the whole region.",
				duration = 6.0,
				cue = "radio_open",
			}),
			line({
				id = "end_2",
				source = "dispatch",
				text = "I am getting answers. Four of them. Five. They are coming in faster than I can write them down.",
				duration = 7.5,
			}),
			line({
				id = "end_3",
				source = "dispatch",
				text = "Bring her home, zero two seventeen. I will keep the frequency open. There is a lot of line left, and now there are people on it.",
				duration = 9.0,
				cue = "radio_close",
			}),
		},
	},
	{
		id = "ending_failure",
		trigger = "expedition_failure",
		once = true,
		priority = 100,
		lines = {
			line({
				id = "fail_1",
				source = "dispatch",
				text = "Control, to zero two seventeen. Zero two seventeen, respond.",
				duration = 5.0,
				cue = "radio_open",
			}),
			line({
				id = "fail_2",
				source = "dispatch",
				text = "Zero two seventeen. Anyone. Please.",
				duration = 4.5,
				cue = "radio_close",
			}),
		},
	},

	----------------------------------------------------------------------
	-- Ambient and reactive lines
	----------------------------------------------------------------------
	{
		id = "low_fuel",
		trigger = "train_low_fuel",
		once = false,
		priority = 40,
		lines = {
			line({
				id = "amb_fuel",
				source = "dispatch",
				text = "Control, to zero two seventeen. Your fuel is low. Do not run her dry between stops.",
				duration = 6.0,
			}),
		},
	},
	{
		id = "low_condition",
		trigger = "train_low_condition",
		once = false,
		priority = 40,
		lines = {
			line({
				id = "amb_cond",
				source = "dispatch",
				text = "Control. She is in a bad way. Find a repair kit before something important lets go.",
				duration = 6.0,
			}),
		},
	},
	{
		id = "crew_down",
		trigger = "crew_downed",
		once = false,
		priority = 50,
		lines = {
			line({
				id = "amb_down",
				source = "dispatch",
				text = "Control. Somebody is down out there. Go and get them.",
				duration = 4.5,
			}),
		},
	},
	{
		id = "tunnel_blackout",
		trigger = "travel_event",
		triggerParams = { event = "service_tunnel" },
		once = true,
		priority = 55,
		lines = {
			line({
				id = "amb_tunnel",
				source = "dispatch",
				text = "Control. You are about to lose me in Ashcombe Tunnel. Doors shut, lights on, and I will see you the other side.",
				duration = 8.0,
			}),
		},
	},
	{
		id = "mimic_crew_voice",
		trigger = "threat_band",
		triggerParams = { band = 3, requiresMimicry = true },
		once = false,
		priority = 30,
		lines = {
			line({
				id = "mim_1",
				source = "other",
				text = "I am hurt. I am behind the shed. Come on your own, it is quicker.",
				duration = 5.5,
				cue = "creature_mimic",
				falseInstruction = {
					action = "isolate",
					cost = "Whoever goes alone is alone.",
				},
			}),
		},
	},
}

--------------------------------------------------------------------------
-- Recordings found in the world
--------------------------------------------------------------------------

export type RecordingDef = {
	id: string,
	station: string,
	title: string,
	text: string,
	duration: number,
	credits: number,
}

local RECORDINGS: { RecordingDef } = {
	{
		id = "rec_marrow",
		station = "marrow_halt",
		title = "Marrow Halt, day two",
		text = "We put everything we had against the waiting room door. Then Ellis said the sensible thing, which is that it was already inside with us, and we went out the window instead.",
		duration = 11,
		credits = 30,
	},
	{
		id = "rec_tolbridge",
		station = "tolbridge_camp",
		title = "Camp office tape",
		text = "It copies the saw. Not the sound of the saw, the pattern of it. Three cuts and a pause, three cuts and a pause. We stopped cutting on the second day and it kept going for a week.",
		duration = 13,
		credits = 30,
	},
	{
		id = "rec_93",
		station = "tower_93",
		title = "Tower cabin tape",
		text = "It has learned the callsign. It has not learned that Control signs off at the end, not the start. That is the only thing keeping me sat in this chair.",
		duration = 12,
		credits = 35,
	},
	{
		id = "rec_bridge",
		station = "hallow_bridge",
		title = "Pump house tape",
		text = "The span has been up for two years. The gearing is fine. The valve is fine. Somebody took the valve out and put it in the stores, deliberately, and I would like to know who and I would like to know why.",
		duration = 14,
		credits = 35,
	},
	{
		id = "rec_ward_1",
		station = "ward_hill",
		title = "Operator, day one",
		text = "Regional says evacuate. I am not leaving a transmitter this size unattended. Someone has to hold the frequency open or none of them can find each other.",
		duration = 12,
		credits = 40,
	},
	{
		id = "rec_ward_2",
		station = "ward_hill",
		title = "Operator, day six",
		text = "It sits outside the hall and it says my own callsign back at me in my own voice. I have stopped answering. The carrier stays up. That is the job.",
		duration = 13,
		credits = 40,
	},
	{
		id = "rec_ward_3",
		station = "ward_hill",
		title = "Operator, day eleven",
		text = "Valve has gone in the transmitter. There is a spare in the cabinet. I am going to fit it, and if I do not come back from that room, the spare is in the cabinet. Whoever you are. The spare is in the cabinet.",
		duration = 15,
		credits = 50,
	},
	{
		id = "rec_ward_4",
		station = "ward_hill",
		title = "Unmarked tape",
		text = "Control, to zero two seventeen. Control, to zero two seventeen. Control, to zero two seventeen.",
		duration = 10,
		credits = 60,
	},
}

--------------------------------------------------------------------------

local RadioScript = {}

RadioScript.Beats = TableUtil.deepFreeze(BEATS) :: { Beat }
RadioScript.Recordings = TableUtil.deepFreeze(RECORDINGS) :: { RecordingDef }

--- The dispatcher's callsign, used by the client to render the attribution and
--- by the mimicry system to know what it is imitating.
RadioScript.DispatchCallsign = "Control, to zero two seventeen"

function RadioScript.beatsFor(trigger: string): { Beat }
	local out: { Beat } = {}
	for _, beat in BEATS do
		if beat.trigger == trigger then
			table.insert(out, beat)
		end
	end
	table.sort(out, function(a, b)
		return a.priority > b.priority
	end)
	return out
end

function RadioScript.beatById(id: string): Beat?
	for _, beat in BEATS do
		if beat.id == id then
			return beat
		end
	end
	return nil
end

function RadioScript.recordingsFor(station: string): { RecordingDef }
	local out: { RecordingDef } = {}
	for _, rec in RECORDINGS do
		if rec.station == station then
			table.insert(out, rec)
		end
	end
	return out
end

--- Total spoken duration of a beat, used to reserve the radio so two beats
--- never talk over each other.
function RadioScript.beatDuration(beat: Beat): number
	local total = 0
	for _, l in beat.lines do
		total += l.duration + 0.4
	end
	return total
end

return RadioScript
