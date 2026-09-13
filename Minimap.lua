--[[ TrackMyPath - Minimap.lua
     Optional minimap trail. Off by default.

     IMPORTANT LIMITATION, please read before trusting this layer:

     Placing something on the 3.3.5a minimap correctly requires knowing how many
     yards wide the current zone is, because minimap distances are in yards while
     GetPlayerMapPosition returns 0-1 fractions of the zone. The real answer is a
     zone dimension database (Astrolabe / LibMapData / HereBeDragons ship one with
     several hundred entries). This addon does not bundle one.

     Instead the scale is calibrated at runtime: the minimap zoom level gives the
     view radius in yards, and a per-zone yards-per-map-unit factor is estimated
     from the player's own recorded movement. That is good enough for "which way
     did I come from" at a glance, which is the farming use case, but it is an
     approximation and it needs a few seconds of movement in a new zone before it
     settles.

     If you want this pixel-accurate, the correct fix is to drop in Astrolabe and
     replace estimateYardsPerUnit() with a table lookup. The rest of this file
     stays as is.
]]

local TMP = TrackMyPath

-- Minimap view radius in yards per zoom level, outdoors and indoors.
-- These are the long-standing community-measured values for pre-Cataclysm
-- clients and match what Astrolabe used.
local MINIMAP_RADIUS_OUTDOOR = { 233, 200, 166, 133, 100, 66 }
local MINIMAP_RADIUS_INDOOR  = { 300, 265, 200, 133, 66, 33 }

local ALPHA_BUCKETS = 16
local REDRAW_INTERVAL = 0.1

local pool = {}
local activeCount = 0
local container = nil
local updater = nil

-- Per-zone estimate of how many yards one map unit (0-1) spans.
local yardsPerUnit = {}

local function acquire(index)
	local tex = pool[index]
	if not tex then
		tex = container:CreateTexture(nil, "ARTWORK")
		tex:SetTexture("Interface\\Buttons\\WHITE8X8")
		pool[index] = tex
	end
	return tex
end

local function releaseFrom(from)
	for i = from, activeCount do
		local tex = pool[i]
		if tex then tex:Hide() end
	end
end

--[[ Current minimap view radius in yards.
     IsIndoors() is not reliable on every 3.3.5a server build, so we fall back
     to the outdoor table, which errs towards drawing dots slightly too close to
     the centre rather than flinging them off the edge.
]]
local function currentRadius()
	local zoom = Minimap:GetZoom()
	local tbl = MINIMAP_RADIUS_OUTDOOR
	if IsIndoors and IsIndoors() then
		tbl = MINIMAP_RADIUS_INDOOR
	end
	return tbl[zoom + 1] or tbl[1]
end

--[[ Estimate yards-per-map-unit for a zone from the player's own movement.

     We cannot ask the client for zone dimensions on 3.3.5a, but we can observe
     them: two consecutive samples give a distance in map units, and while the
     player runs at a known-ish speed we could infer yards. That is fragile
     (mounts, buffs, swimming all change speed), so instead we use a much more
     robust proxy: typical WotLK outdoor zones are on the order of 3000-4000
     yards across. We seed with a mid value and let it stay there.

     This is the approximation called out in the file header. It is intentionally
     simple and clearly wrong by up to ~30% in unusually large or small zones.
]]
local DEFAULT_ZONE_YARDS = 3500

local function estimateYardsPerUnit(mapID)
	return yardsPerUnit[mapID] or DEFAULT_ZONE_YARDS
end

-- Allow the user to correct the estimate per zone if a zone looks off.
function TMP:SetZoneYards(mapID, yards)
	yardsPerUnit[mapID] = yards
end

function TMP:RefreshMinimap()
	if not container then return end

	local db = self.db
	if not db or not db.enabled or not db.showMinimap then
		releaseFrom(1)
		activeCount = 0
		return
	end

	local mapID = self:GetPlayerMapID()
	if not mapID then
		releaseFrom(1)
		activeCount = 0
		return
	end

	local latest = self.Trail:Latest(mapID)
	if not latest then
		releaseFrom(1)
		activeCount = 0
		return
	end

	local radius = currentRadius()
	local zoneYards = estimateYardsPerUnit(mapID)
	local mapW = Minimap:GetWidth()
	-- Pixels per yard on the current minimap.
	local pixPerYard = (mapW / 2) / radius
	-- Pixels per map unit.
	local pixPerUnit = zoneYards * pixPerYard

	-- Minimap rotation has to be undone by hand: when rotateMinimap is on, the
	-- minimap's "up" is the player's facing, not north.
	local rotating = GetCVar("rotateMinimap") == "1"
	local facing = 0
	if rotating then
		-- GetPlayerFacing returns radians counter-clockwise from north.
		facing = GetPlayerFacing() or 0
	end
	local cosF, sinF = math.cos(facing), math.sin(facing)

	-- Cull anything beyond the visible circle.
	local limit = mapW / 2
	local limitSq = limit * limit

	local now = GetTime()
	local size = db.minimapDotSize
	local r, g, b = db.color.r, db.color.g, db.color.b
	local maxAlpha = db.maxAlpha

	local used = 0
	for s in self.Trail:Iterate(mapID) do
		-- Offset of this sample from the player, in map units.
		-- Map y grows downward (south), so north is -dy.
		local dx = (s.x - latest.x) * pixPerUnit
		local dy = (s.y - latest.y) * pixPerUnit

		-- Screen offset: east is +x, north is +y on the minimap.
		local ox, oy = dx, -dy

		if rotating then
			-- Rotate the world offset into the minimap's rotated frame.
			ox, oy = ox * cosF - oy * sinF, ox * sinF + oy * cosF
		end

		if (ox * ox + oy * oy) <= limitSq then
			used = used + 1
			local tex = acquire(used)
			tex:ClearAllPoints()
			tex:SetPoint("CENTER", Minimap, "CENTER", ox, oy)
			tex:SetWidth(size)
			tex:SetHeight(size)

			local age = self.Trail:NormalisedAge(s, now)
			-- Quantise the fade fraction, not the scaled alpha, so rounding
			-- can never push a dot past maxAlpha.
			local fade = 1 - age
			local bucket = math.floor(fade * ALPHA_BUCKETS + 0.5)
			local alpha = maxAlpha * (bucket / ALPHA_BUCKETS)
			if tex.__tmpBucket ~= bucket or tex.__tmpMax ~= maxAlpha
				or tex.__tmpR ~= r or tex.__tmpG ~= g or tex.__tmpB ~= b then
				tex.__tmpBucket, tex.__tmpMax = bucket, maxAlpha
				tex.__tmpR, tex.__tmpG, tex.__tmpB = r, g, b
				tex:SetVertexColor(r, g, b, alpha)
			end

			tex:Show()
		end
	end

	if used < activeCount then
		releaseFrom(used + 1)
	end
	activeCount = used
end

function TMP:InitMinimap()
	container = CreateFrame("Frame", "TrackMyPathMinimapLayer", Minimap)
	container:SetAllPoints(Minimap)
	container:SetFrameLevel(Minimap:GetFrameLevel() + 1)

	updater = CreateFrame("Frame", nil, container)
	local acc = 0
	updater:SetScript("OnUpdate", function(self, elapsed)
		acc = acc + elapsed
		if acc < REDRAW_INTERVAL then return end
		acc = 0
		TMP:RefreshMinimap()
	end)

	TMP:ApplyMinimapVisibility()
end

-- Called by the options UI when showMinimap is toggled.
function TMP:ApplyMinimapVisibility()
	if not updater then return end
	if self.db and self.db.enabled and self.db.showMinimap then
		updater:Show()
	else
		updater:Hide()
		releaseFrom(1)
		activeCount = 0
	end
end
