--[[ TrackMyPath - Config.lua
     Default settings and SavedVariables handling.

     Note: only the *settings* persist across sessions. The recorded trail is
     deliberately session-only (kept in Trail.lua's memory), so there is no
     SavedVariables bloat and no stale trail after a relog.
]]

local ADDON = "TrackMyPath"
TrackMyPath = TrackMyPath or {}
local TMP = TrackMyPath

TMP.ADDON_NAME = ADDON
TMP.VERSION = "0.1.1"

-- Defaults. Kept flat on purpose: easier to migrate and to reset individually.
TMP.defaults = {
	enabled = true,

	-- Trail lifetime in seconds. 600 = 10 minutes.
	fadeTime = 600,

	-- How often a position sample is taken, in seconds.
	-- 1.0s over 600s = 600 samples max. See maxSamples below.
	sampleInterval = 1.0,

	-- Hard cap on stored samples. Acts as a safety net so a long session or a
	-- very low sampleInterval can never grow the pool without bound.
	maxSamples = 800,

	-- Minimum distance (in map units, 0-1 range) between two samples. Prevents
	-- piling up hundreds of dots while standing still or fighting.
	minDistance = 0.002,

	-- Dot appearance
	dotSize = 6,
	color = { r = 0.2, g = 1.0, b = 0.4 },

	-- Alpha of the newest dot. Older dots fade linearly towards 0.
	maxAlpha = 0.9,

	-- Draw targets
	showWorldMap = true,
	showMinimap = false,

	-- Minimap dots are smaller by default; the minimap is a busy, small surface.
	minimapDotSize = 4,
}

-- Copy any missing default into the live DB. Runs on every load so new options
-- added in a later version get filled in without wiping the user's settings.
local function applyDefaults(db, defaults)
	for k, v in pairs(defaults) do
		if type(v) == "table" then
			if type(db[k]) ~= "table" then db[k] = {} end
			applyDefaults(db[k], v)
		elseif db[k] == nil then
			db[k] = v
		end
	end
end

function TMP:InitConfig()
	if type(TrackMyPathDB) ~= "table" then
		TrackMyPathDB = {}
	end
	applyDefaults(TrackMyPathDB, self.defaults)
	self.db = TrackMyPathDB
end

-- Reset every setting back to defaults.
function TMP:ResetConfig()
	TrackMyPathDB = {}
	applyDefaults(TrackMyPathDB, self.defaults)
	self.db = TrackMyPathDB
end
