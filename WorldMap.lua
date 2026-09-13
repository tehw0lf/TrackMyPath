--[[ TrackMyPath - WorldMap.lua
     Draws the trail onto the world map.

     Two decisions worth knowing about:

     1. The dot textures are children of WorldMapDetailFrame. That frame gets
        :SetScale() when the user toggles between windowed and fullscreen map
        (WORLDMAP_WINDOWED_SIZE / WORLDMAP_FULLMAP_SIZE), so anchoring to it
        means scaling is inherited for free. Blizzard's own player arrow has to
        multiply by WORLDMAP_SETTINGS.size only because it lives on UIParent.

     2. Alpha is quantised into buckets. A 10 minute trail at 1 sample/second is
        up to 600 textures; calling SetAlpha on all of them every frame is
        needless work for a change nobody can see. We only push a new alpha when
        a dot crosses into a different bucket.
]]

local TMP = TrackMyPath

local ALPHA_BUCKETS = 24
-- Redraw cadence while the map is open. The map is a static surface; 10/second
-- is far smoother than the eye needs for a slow fade.
local REDRAW_INTERVAL = 0.1

local pool = {}       -- all created textures
local activeCount = 0 -- how many of them are currently in use
local container = nil
local updater = nil

local function acquire(index)
	local tex = pool[index]
	if not tex then
		tex = container:CreateTexture(nil, "ARTWORK")
		-- A plain white square tinted via SetVertexColor. Using a blank texture
		-- avoids shipping an art file and lets the colour be configurable.
		tex:SetTexture("Interface\\Buttons\\WHITE8X8")
		pool[index] = tex
	end
	return tex
end

--[[ Hide every texture from `from` onwards. Called after a redraw that used
     fewer dots than the previous one.
]]
local function releaseFrom(from)
	for i = from, activeCount do
		local tex = pool[i]
		if tex then tex:Hide() end
	end
end

function TMP:RefreshWorldMap()
	if not container then return end

	local db = self.db
	if not db or not db.enabled or not db.showWorldMap then
		releaseFrom(1)
		activeCount = 0
		return
	end

	-- Only draw the trail belonging to the zone actually on screen. Without
	-- this, browsing to a different zone would paint this zone's dots onto it.
	local mapID = self:GetDisplayedMapID()
	if not mapID then
		releaseFrom(1)
		activeCount = 0
		return
	end

	local w = WorldMapDetailFrame:GetWidth()
	local h = WorldMapDetailFrame:GetHeight()
	if not w or w == 0 then return end

	local now = GetTime()
	local size = db.dotSize
	local r, g, b = db.color.r, db.color.g, db.color.b
	local maxAlpha = db.maxAlpha

	local used = 0
	for s in self.Trail:Iterate(mapID) do
		used = used + 1
		local tex = acquire(used)

		-- Reposition only when the sample moved into a different slot or the
		-- map was resized. Cheap enough to just always set; SetPoint on a
		-- texture is not the expensive part, SetAlpha churn was.
		local px = s.x * w
		local py = -s.y * h

		tex:ClearAllPoints()
		tex:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT", px, py)
		tex:SetWidth(size)
		tex:SetHeight(size)

		-- Newest dot at maxAlpha, oldest approaching 0.
		local age = self.Trail:NormalisedAge(s, now)
		-- Quantise the alpha so we are not writing a microscopically different
		-- value every single frame. Quantise the 0..1 fade fraction rather than
		-- the scaled alpha, so rounding can never push a dot past maxAlpha.
		local fade = 1 - age
		local bucket = math.floor(fade * ALPHA_BUCKETS + 0.5)
		local alpha = maxAlpha * (bucket / ALPHA_BUCKETS)
		-- Only touch the texture when something it displays actually changed.
		-- Alpha is compared via the bucket, colour and maxAlpha directly, so a
		-- settings change still takes effect immediately.
		if tex.__tmpBucket ~= bucket or tex.__tmpMax ~= maxAlpha
			or tex.__tmpR ~= r or tex.__tmpG ~= g or tex.__tmpB ~= b then
			tex.__tmpBucket, tex.__tmpMax = bucket, maxAlpha
			tex.__tmpR, tex.__tmpG, tex.__tmpB = r, g, b
			tex:SetVertexColor(r, g, b, alpha)
		end

		tex:Show()
	end

	if used < activeCount then
		releaseFrom(used + 1)
	end
	activeCount = used
end

function TMP:InitWorldMap()
	-- Anchor container to the detail frame so it inherits map scaling.
	container = CreateFrame("Frame", "TrackMyPathWorldMapLayer", WorldMapDetailFrame)
	container:SetAllPoints(WorldMapDetailFrame)
	-- Sit above the map art but below Blizzard's POI icons and the player arrow.
	container:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 1)

	-- Drive the fade only while the map is actually visible. No point animating
	-- a surface nobody is looking at.
	updater = CreateFrame("Frame", nil, container)
	local acc = 0
	updater:SetScript("OnUpdate", function(self, elapsed)
		acc = acc + elapsed
		if acc < REDRAW_INTERVAL then return end
		acc = 0
		TMP:RefreshWorldMap()
	end)

	WorldMapFrame:HookScript("OnShow", function()
		updater:Show()
		TMP:RefreshWorldMap()
	end)
	WorldMapFrame:HookScript("OnHide", function()
		updater:Hide()
	end)

	if not WorldMapFrame:IsShown() then
		updater:Hide()
	end
end
