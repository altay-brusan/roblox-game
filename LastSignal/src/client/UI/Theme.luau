--!strict
--[[
	Theme
	-----
	The visual language of LAST SIGNAL's interface, in one place.

	The interface is meant to read as railway paperwork and enamel signage seen
	by lamplight: warm off-white on near-black, a single brass accent, one red
	for danger, and nothing else. Restraint is the point. A horror game whose
	menus are bright and busy stops being frightening the moment a panel opens.

	SIZING
	------
	Everything here is in scale-independent units. `space(n)` returns a pixel
	value already multiplied by the platform scale, so a phone gets larger
	touch targets and a desktop gets a tighter layout from the same code. No
	panel in this project hard-codes a pixel size.
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Theme = {}

local C = Color3.fromRGB

--------------------------------------------------------------------------
-- Palette
--------------------------------------------------------------------------

Theme.Colour = {
	-- Surfaces, darkest to lightest.
	void = C(8, 9, 11),
	backdrop = C(14, 15, 18),
	surface = C(22, 24, 28),
	surfaceRaised = C(30, 33, 38),
	surfaceHover = C(38, 42, 48),
	line = C(52, 56, 63),
	lineStrong = C(78, 84, 92),

	-- Text.
	text = C(232, 228, 218),
	textMuted = C(158, 156, 150),
	textFaint = C(108, 108, 104),
	textInverse = C(16, 16, 18),

	-- Accents.
	brass = C(198, 158, 78),
	brassDim = C(132, 106, 54),
	signalRed = C(198, 62, 52),
	signalGreen = C(96, 170, 108),
	signalAmber = C(212, 162, 62),
	cold = C(126, 158, 188),

	-- Meters.
	health = C(186, 72, 62),
	stamina = C(190, 178, 120),
	flashlight = C(214, 200, 150),
	fuel = C(168, 142, 86),
	condition = C(126, 158, 188),
	progress = C(198, 158, 78),
	danger = C(198, 62, 52),
}

--- A higher-contrast palette for the accessibility setting. Only the values
--- that matter for legibility change; the layout is identical.
Theme.HighContrast = {
	backdrop = C(0, 0, 0),
	surface = C(12, 12, 14),
	surfaceRaised = C(26, 26, 30),
	line = C(120, 124, 130),
	lineStrong = C(180, 184, 190),
	text = C(255, 253, 246),
	textMuted = C(212, 210, 204),
	textFaint = C(170, 168, 162),
	brass = C(255, 204, 96),
}

local highContrastActive = false

function Theme.setHighContrast(enabled: boolean)
	highContrastActive = enabled
end

--- Reads a colour, honouring the high-contrast setting.
function Theme.colour(name: string): Color3
	if highContrastActive then
		local override = (Theme.HighContrast :: any)[name]
		if override then
			return override
		end
	end
	return (Theme.Colour :: any)[name] or Theme.Colour.text
end

--------------------------------------------------------------------------
-- Type
--------------------------------------------------------------------------

-- Roblox's built-in font families. No external font assets are used, so the
-- interface renders identically on every device with no download.
Theme.Font = {
	display = Font.fromEnum(Enum.Font.GothamBold),
	heading = Font.fromEnum(Enum.Font.GothamMedium),
	body = Font.fromEnum(Enum.Font.Gotham),
	mono = Font.fromEnum(Enum.Font.RobotoMono),
}

Theme.TextSize = {
	display = 30,
	title = 22,
	heading = 18,
	body = 15,
	small = 13,
	tiny = 11,
}

--------------------------------------------------------------------------
-- Platform and scale
--------------------------------------------------------------------------

export type Platform = "desktop" | "tablet" | "phone" | "console"

local cachedPlatform: Platform? = nil

function Theme.platform(): Platform
	if cachedPlatform then
		return cachedPlatform
	end
	local resolved: Platform
	if GuiService:IsTenFootInterface() then
		resolved = "console"
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
		-- The split is by physical size rather than resolution: a small tablet
		-- and a large phone want the same layout, and pixel count does not
		-- distinguish them.
		resolved = if math.min(viewport.X, viewport.Y) >= 600 then "tablet" else "phone"
	else
		resolved = "desktop"
	end
	cachedPlatform = resolved
	return resolved
end

function Theme.isTouch(): boolean
	local platform = Theme.platform()
	return platform == "phone" or platform == "tablet"
end

--- Refreshes the cached platform, for a device that rotates or docks.
function Theme.refreshPlatform()
	cachedPlatform = nil
end

local userScale = 1

function Theme.setUserScale(scale: number)
	userScale = math.clamp(scale, 0.75, 1.5)
end

--- The multiplier applied to every size in the interface.
function Theme.scale(): number
	local platform = Theme.platform()
	local base: number
	if platform == "phone" then
		base = 1.25 -- larger targets, fewer of them on screen
	elseif platform == "tablet" then
		base = 1.1
	elseif platform == "console" then
		base = 1.3 -- read from across a room
	else
		base = 1.0
	end
	return base * userScale
end

function Theme.space(units: number): number
	return math.floor(units * 8 * Theme.scale() + 0.5)
end

function Theme.textSize(name: string): number
	local base = (Theme.TextSize :: any)[name] or Theme.TextSize.body
	return math.floor(base * Theme.scale() + 0.5)
end

--- The minimum tappable size. Below this, touch input is unreliable, so every
--- interactive widget in this project is clamped to it.
function Theme.minTouchTarget(): number
	return if Theme.isTouch() then math.floor(48 * Theme.scale()) else math.floor(28 * Theme.scale())
end

--------------------------------------------------------------------------
-- Safe area
--------------------------------------------------------------------------

--- Insets that keep content clear of notches, home indicators and the Roblox
--- top bar. GuiService reports the top inset; the others are conservative
--- constants because Roblox does not expose them directly.
function Theme.safeInsets(): { top: number, bottom: number, left: number, right: number }
	local topInset, bottomInset = GuiService:GetGuiInset()
	local platform = Theme.platform()
	local sideInset = if platform == "phone" then Theme.space(2) else Theme.space(1)
	return {
		top = topInset.Y + Theme.space(1),
		bottom = bottomInset.Y + (if platform == "phone" then Theme.space(3) else Theme.space(1)),
		left = sideInset,
		right = sideInset,
	}
end

--------------------------------------------------------------------------
-- Motion
--------------------------------------------------------------------------

local reducedMotion = false
local reducedFlashing = false

function Theme.setReducedMotion(enabled: boolean)
	reducedMotion = enabled
end

function Theme.setReducedFlashing(enabled: boolean)
	reducedFlashing = enabled
end

function Theme.motionReduced(): boolean
	return reducedMotion
end

function Theme.flashingReduced(): boolean
	return reducedFlashing
end

--- Tween duration, collapsed to near-zero when reduced motion is on. Panels
--- still change state; they simply stop animating.
function Theme.duration(seconds: number): number
	return if reducedMotion then 0.01 else seconds
end

Theme.Ease = {
	standard = Enum.EasingStyle.Quart,
	standardDirection = Enum.EasingDirection.Out,
}

function Theme.tweenInfo(seconds: number): TweenInfo
	return TweenInfo.new(Theme.duration(seconds), Theme.Ease.standard, Theme.Ease.standardDirection)
end

--------------------------------------------------------------------------
-- Layering
--------------------------------------------------------------------------

-- Display orders, so two panels can never fight over which is on top.
Theme.Layer = {
	world = 1, -- world-space markers and prompts
	hud = 10,
	interaction = 20,
	subtitles = 30,
	notification = 40,
	panel = 50,
	modal = 60,
	cinematic = 80,
	loading = 90,
}

return Theme
