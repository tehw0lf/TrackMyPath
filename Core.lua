--[[ TrackMyPath - Core.lua
     Event wiring and the sampling loop.

     The tricky part on 3.3.5a is that GetPlayerMapPosition("player") reports
     coordinates relative to *whatever zone the world map is currently showing*,
     not relative to the zone the player is standing in. If the user opens the
     map and browses to another zone, the API keeps returning the player's
     position projected onto that other map, which is meaningless for us.

     We must not call SetMapToCurrentZone() to force it back, because that would
     yank the map away from the user while they are browsing. Instead we only
     record while the displayed map actually is the player's zone, and we detect
     that by comparing the displayed area ID against the one we cached the last
     time we knew the map was correct (on zone change, with the map closed).
]]

local TMP = TrackMyPath

local frame = CreateFrame("Frame", "TrackMyPathCoreFrame")

-- The map area ID of the zone the player is physically in.
local playerMapID = nil
-- Set when we need to refresh playerMapID at the next safe moment.
local mapIDDirty = true

local elapsedSinceSample = 0
local elapsedSincePrune = 0
local PRUNE_INTERVAL = 2.0

--[[ Last position we actually sampled, and the zone it belonged to.

     This is deliberately kept here rather than read back from Trail, because
     "has the player moved" is a question about the player, not about the
     display buffer. Asking Trail would reintroduce a bug where a trail that has
     just fully faded out has no previous sample to compare against, so a
     motionless player starts dropping a fresh dot on the same spot once per
     fade interval.
]]
local lastSampleX, lastSampleY, lastSampleMapID = nil, nil, nil

--[[ Resolve the player's own map area ID.
     Only safe to call when the world map is closed, since it changes the
     displayed map as a side effect.
]]
local function refreshPlayerMapID()
	if WorldMapFrame and WorldMapFrame:IsShown() then
		-- Cannot touch the map while the user is looking at it.
		return false
	end
	SetMapToCurrentZone()
	local id = GetCurrentMapAreaID()
	if id and id > 0 then
		playerMapID = id
		mapIDDirty = false
		return true
	end
	return false
end

--[[ True when we are somewhere positions are meaningful.
     Instances, battlegrounds and the cosmic/continent views all report
     unusable coordinates, so recording there just produces a blob of dots in
     the top-left corner.
]]
local function isTrackableLocation()
	if IsInInstance() then return false end

	local continent = GetCurrentMapContinent()
	-- -1 is the cosmic map and battleground maps; 0 is the "Azeroth" world view.
	if not continent or continent <= 0 then return false end

	-- GetCurrentMapZone() == 0 means a whole continent is displayed rather than
	-- a single zone, and coordinates are not per-zone there.
	local zone = GetCurrentMapZone()
	if not zone or zone == 0 then return false end

	return true
end

--[[ The player's current position in their own zone's coordinate space, or nil
     when it cannot be trusted.

     The minimap layer needs this rather than the newest trail sample. Anchoring
     the minimap trail to the last *sample* makes the whole trail drift relative
     to the player between samples and then jump when a new sample lands, which
     reads as the trail sliding and snapping once per sampleInterval.

     Same gating as sample(): the displayed map has to be the player's own zone,
     otherwise GetPlayerMapPosition reports a projection onto a foreign map.
]]
function TMP:GetLivePlayerPosition()
	if not playerMapID then return nil end
	if TMP:GetDisplayedMapID() ~= playerMapID then return nil end
	if not isTrackableLocation() then return nil end

	local x, y = GetPlayerMapPosition("player")
	if not x or not y or (x == 0 and y == 0) then return nil end
	if x < 0 or x > 1 or y < 0 or y > 1 then return nil end
	return x, y
end

--[[ The area ID currently drawn on the world map. Read-only, no side effects.
]]
function TMP:GetDisplayedMapID()
	local id = GetCurrentMapAreaID()
	if id and id > 0 then return id end
	return nil
end

function TMP:GetPlayerMapID()
	return playerMapID
end

--[[ Take one position sample if everything lines up.
]]
local function sample(now)
	if not TMP.db.enabled then return end
	if mapIDDirty and not refreshPlayerMapID() then return end
	if not playerMapID then return end

	-- Only record when the displayed map is the player's own zone, otherwise
	-- GetPlayerMapPosition is reporting a projection onto a foreign map.
	local displayed = TMP:GetDisplayedMapID()
	if displayed ~= playerMapID then return end

	if not isTrackableLocation() then return end

	local x, y = GetPlayerMapPosition("player")
	-- Blizzard's own convention: 0,0 means "position unknown".
	if not x or not y or (x == 0 and y == 0) then return end
	-- Guard against the occasional out-of-range value on custom servers.
	if x < 0 or x > 1 or y < 0 or y > 1 then return end

	-- Skip samples that barely moved, so standing still or fighting in place
	-- does not stack dots. Compared against the last position we sampled, not
	-- against the trail contents, so a fully faded trail does not reset this.
	if lastSampleMapID == playerMapID and lastSampleX then
		local dx, dy = x - lastSampleX, y - lastSampleY
		local minD = TMP.db.minDistance
		if (dx * dx + dy * dy) < (minD * minD) then return end
	end

	lastSampleX, lastSampleY, lastSampleMapID = x, y, playerMapID
	TMP.Trail:Add(playerMapID, x, y, now)
end

frame:SetScript("OnUpdate", function(self, elapsed)
	if not TMP.db then return end

	elapsedSincePrune = elapsedSincePrune + elapsed
	if elapsedSincePrune >= PRUNE_INTERVAL then
		TMP.Trail:Prune(GetTime())
		elapsedSincePrune = 0
	end

	elapsedSinceSample = elapsedSinceSample + elapsed
	if elapsedSinceSample >= TMP.db.sampleInterval then
		elapsedSinceSample = 0
		sample(GetTime())
	end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_INDOORS")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("WORLD_MAP_UPDATE")

frame:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= TMP.ADDON_NAME then return end
		TMP:InitConfig()
		TMP:InitWorldMap()
		TMP:InitMinimap()
		TMP:InitOptions()
		TMP:InitSlash()
		return
	end

	if event == "WORLD_MAP_UPDATE" then
		-- The displayed map changed; the world map layer needs to redraw
		-- against whatever zone is now shown.
		TMP:RefreshWorldMap()
		return
	end

	-- Any zone transition invalidates our cached area ID, and the previous
	-- sample position is meaningless in the new zone's coordinate space.
	mapIDDirty = true
	lastSampleX, lastSampleY, lastSampleMapID = nil, nil, nil
	refreshPlayerMapID()
end)

TMP.coreFrame = frame
