--[[ TrackMyPath - Minimap.lua
     Optional minimap trail. Off by default.

     IMPORTANT LIMITATION, please read before trusting this layer:

     Placing something on the 3.3.5a minimap correctly requires knowing the
     current zone's size in yards, because minimap distances are in yards while
     GetPlayerMapPosition returns 0-1 fractions of the zone. There are two
     separate problems in that sentence, and they have different answers.

     1. ABSOLUTE DISTANCE - not solved. How far one map unit reaches in yards
        cannot be derived without either a zone dimension database or a known run
        speed. Astrolabe, LibMapData and HereBeDragons each ship such a database,
        but their data is not under a licence compatible with this addon's MIT,
        and the tables are the substance of those libraries rather than an
        incidental detail - so they are not copied here. A single mid-range zone
        size is assumed instead, leaving distance off by up to ~30%.

     2. AXIS STRETCH - solved, see the calibration block below. WotLK zones are
        not square, and x and y are each fractions of their own axis, so drawing
        both at one scale skews direction as well as distance. The height/width
        RATIO is recoverable from the player's own movement alone, because run
        speed scales both axes equally and cancels out. No external data needed.

     The ratio is measured once per zone and then locked permanently, so the
     trail never shifts underfoot after calibration.
]]

local TMP = TrackMyPath

-- Minimap view radius in yards per zoom level, outdoors and indoors.
-- These are the long-standing community-measured values for pre-Cataclysm
-- clients and match what Astrolabe used.
local MINIMAP_RADIUS_OUTDOOR = { 233, 200, 166, 133, 100, 66 }
local MINIMAP_RADIUS_INDOOR  = { 300, 265, 200, 133, 66, 33 }

local ALPHA_BUCKETS = 16
local REDRAW_INTERVAL = 0.05

--[[ Motion smoothing.

     Two things made the minimap trail feel hectic beyond the anchor bug:

     1. With rotateMinimap on, GetPlayerFacing() is re-read every frame, so every
        twitch of the mouse rotates the whole trail. The angle is now eased
        towards its target instead of snapping to it.

     2. Redrawing when nothing moved perceptibly is wasted work and, combined
        with pixel rounding, can make dots shimmer. A redraw is skipped when the
        anchor and facing are effectively unchanged.
]]
-- Fraction of the remaining angle difference closed per redraw. Lower is
-- smoother but lags further behind a fast turn.
local FACING_SMOOTHING = 0.25
-- Below this angular change (radians) the facing is treated as unchanged.
local FACING_EPSILON = 0.004
-- Below this positional change (map units) the anchor is treated as unchanged.
local ANCHOR_EPSILON = 0.00005

--[[ Dots vanish abruptly when they cross the minimap edge, which reads as
     popping while running. The outer band of the circle fades them out instead.
     0.8 means the outermost 20% of the radius is the fade band.
]]
local EDGE_FADE_START = 0.8

-- Eased facing angle, and the state the last redraw was built from.
local smoothFacing = nil
local lastDrawX, lastDrawY, lastDrawFacing = nil, nil, nil
local lastDrawZoom, lastDrawMapID, lastDrawCount = nil, nil, nil
local lastDrawAspect = nil
local lastDrawTime = nil

local pool = {}
local activeCount = 0
local container = nil
local updater = nil

-- Per-zone estimate of how many yards one map unit (0-1) spans.
local yardsPerUnit = {}

--[[ Ease `current` towards `target` along the shortest arc.

     Naive interpolation breaks when the angle wraps: easing from 6.2 rad to
     0.1 rad the long way round spins the trail a full turn even though the
     player barely moved. The difference is normalised into (-pi, pi] first.
]]
local TWO_PI = math.pi * 2

local function easeAngle(current, target, factor)
	if current == nil then return target end
	local diff = (target - current) % TWO_PI
	if diff > math.pi then diff = diff - TWO_PI end
	return (current + diff * factor) % TWO_PI
end

-- Shortest angular distance between two angles, always >= 0.
local function angleDelta(a, b)
	if a == nil or b == nil then return math.huge end
	local diff = (b - a) % TWO_PI
	if diff > math.pi then diff = TWO_PI - diff end
	return diff
end

--[[ Aspect-ratio calibration.

     The distance problem above is unfixable without a zone dimension database.
     The *stretch* problem is not, and it is the one that also breaks direction.

     WotLK zones are not square. Because x and y are each a 0-1 fraction of their
     own axis, one map unit of x and one map unit of y are different numbers of
     yards. Drawing both with a single scale squashes the trail along one axis:
     in Icecrown (roughly 3:2) a dot 45 degrees off is drawn about 34 degrees off.

     Only the RATIO r = height / width is needed, not the absolute size. A step of
     L yards in the world heading u = (ux, uy) (east, north) shows up on the map as

         dx =  L * ux / W          (map x grows east)
         dy = -L * uy / H          (map y grows south), H = r * W

     The player's heading comes from GetPlayerFacing (radians counter-clockwise
     from north), so u = (-sin(facing), cos(facing)). L and W are unknown, but
     both sit in the same factor a = L / W, which cancels:

         r * (dy * ux) = -(dx * uy)

     That is one equation per step in r alone. Speed, mounts, buffs and swimming
     drop out, and so does the direction of travel: the heading is an input, not
     something the result depends on. A square zone gives r = 1 whether the
     player runs mostly east or mostly north.

     Why not just compare the movement itself, sqrt(sum dx^2 / sum dy^2)? That
     equals r only if the player moved equally in every direction. Running
     mostly east in a square zone would lock a ratio of ~2.4 and bake it into the
     SavedVariables permanently - worse than not measuring.

     Steps are combined by least squares over s = dy * ux and t = dx * uy:

         r = -sum(s * t) / sum(s * s)

     which weights each step by how much it says about r. A step along an axis
     (ux or uy near 0) says nothing and is skipped. Steps where the character did
     not move the way it faces - backpedalling, strafing, being knocked back, or
     turning mid-step - would feed the fit a wrong heading, so they are skipped
     too, and the fit must also agree with itself (see MAX_RELATIVE_ERROR).

     Once locked the value is written to db.zoneAspect[mapID] and never revisited:
     the accumulator is discarded and every later frame is a plain table lookup.
     This is deliberate. A continuously refined estimate would shift the whole
     trail underfoot on every update, which is the same class of bug that live
     anchoring and facing easing were introduced to remove.
]]

-- Sums for the least-squares fit per zone, kept until the ratio locks.
-- zoneEvidence[mapID] = { sss = sum s^2, sst = sum s*t, stt = sum t^2, n = steps }
local zoneEvidence = {}
-- Previous sample per zone, to derive movement steps.
local lastCalX, lastCalY, lastCalFacing, lastCalMap = nil, nil, nil, nil

-- Informative steps required before a ratio may be locked. At the default 1s
-- sample interval this is a few seconds of ordinary movement.
local CALIBRATION_MIN_STEPS = 12
--[[ A step is informative when |ux * uy| = |sin * cos| of its heading reaches
     this. 0.1 is a heading about 6 degrees off an axis; closer than that the
     step is nearly pure east/west or north/south and only adds noise.
]]
local MIN_HEADING_SPREAD = 0.1
--[[ The step in map space (east, north) must point within 60 degrees of the
     heading the character faces. Strafing (90 degrees) and backpedalling
     (180 degrees) fail this; the stretch of a real 4:1 zone only bends the angle
     by about 37 degrees, so honest steps always pass.
]]
local MIN_HEADING_AGREEMENT = 0.5
-- Facing may change this much between two samples (about 20 degrees); a bigger
-- swing means the character turned during the step and the heading is unknown.
local MAX_TURN = 0.35
--[[ The fit must be this precise before it locks: the standard error of r, as a
     share of r. Noise-free movement scores 0; a path of strafing and drifting
     steps that slipped through the filters does not, and then waits for more
     data instead of locking a guess.
]]
local MAX_RELATIVE_ERROR = 0.1
-- Clamp: no WotLK zone is anywhere near this elongated. Guards against a bad
-- measurement from teleports or an unusual custom-server map.
local ASPECT_MIN, ASPECT_MAX = 0.25, 4.0

--[[ Feed one position and the facing at that moment into the zone's calibration.
     Cheap and a no-op once the zone is locked, so it is safe to call per sample.
     Without a facing there is no heading, so the step is dropped.
]]
function TMP:CalibrateAspect(mapID, x, y, facing)
	local db = self.db
	if not db or not mapID then return end
	-- Already locked: nothing to do, ever again.
	if db.zoneAspect[mapID] then return end

	local prevMap, prevX, prevY, prevFacing = lastCalMap, lastCalX, lastCalY, lastCalFacing
	lastCalMap, lastCalX, lastCalY, lastCalFacing = mapID, x, y, facing

	-- A zone change makes the previous position meaningless as a step origin.
	if prevMap ~= mapID or not prevX or not prevFacing or not facing then return end
	if angleDelta(prevFacing, facing) > MAX_TURN then return end

	local dx, dy = x - prevX, y - prevY

	-- Ignore steps that are pure noise or an obvious discontinuity (loading
	-- screen, summon, hearthstone) rather than walking.
	local distSq = dx * dx + dy * dy
	if distSq < 1e-10 or distSq > 0.01 then return end

	-- Heading in the world, east and north: the mean of both ends of the step.
	local ux = -(math.sin(prevFacing) + math.sin(facing)) / 2
	local uy = (math.cos(prevFacing) + math.cos(facing)) / 2
	local norm = math.sqrt(ux * ux + uy * uy)
	if norm < 1e-6 then return end
	ux, uy = ux / norm, uy / norm

	if math.abs(ux * uy) < MIN_HEADING_SPREAD then return end

	-- Did the character actually move the way it faces?
	local east, north = dx, -dy
	if (east * ux + north * uy) / math.sqrt(distSq) < MIN_HEADING_AGREEMENT then return end

	local s, t = dy * ux, dx * uy
	local ev = zoneEvidence[mapID]
	if not ev then
		ev = { sss = 0, sst = 0, stt = 0, n = 0 }
		zoneEvidence[mapID] = ev
	end
	ev.sss = ev.sss + s * s
	ev.sst = ev.sst + s * t
	ev.stt = ev.stt + t * t
	ev.n = ev.n + 1

	if ev.n < CALIBRATION_MIN_STEPS then return end
	if ev.sss <= 0 then return end

	local aspect = -ev.sst / ev.sss
	if aspect < ASPECT_MIN or aspect > ASPECT_MAX then
		-- Implausible (or the wrong sign: movement against the heading): discard
		-- the evidence and start over rather than lock in a bad value for good.
		zoneEvidence[mapID] = nil
		return
	end

	-- Residual of the fit, and from it the standard error of the ratio. The
	-- subtraction can dip a hair below zero from rounding on perfect data.
	local rss = math.max(0, ev.stt - ev.sst * ev.sst / ev.sss)
	local stdErr = math.sqrt(rss / ((ev.n - 1) * ev.sss))
	if stdErr > MAX_RELATIVE_ERROR * aspect then return end

	-- Lock it in and drop the accumulator. From here the value is a constant.
	db.zoneAspect[mapID] = aspect
	zoneEvidence[mapID] = nil
	self:InvalidateMinimap()
end

-- Locked height/width ratio for a zone, or 1 (square) while still measuring.
local function aspectFor(db, mapID)
	return db.zoneAspect and db.zoneAspect[mapID] or 1
end

--[[ Calibration state for a zone, for the status readout and tests.
     Returns "locked", aspect | "measuring", steps | "idle", 0
]]
function TMP:GetAspectState(mapID)
	local db = self.db
	if db and db.zoneAspect and db.zoneAspect[mapID] then
		return "locked", db.zoneAspect[mapID]
	end
	local ev = zoneEvidence[mapID]
	if ev then return "measuring", ev.n end
	return "idle", 0
end

-- Drop a locked ratio so the zone is measured again. Used by /tmp calibrate.
function TMP:ResetAspect(mapID)
	if self.db and self.db.zoneAspect then
		self.db.zoneAspect[mapID] = nil
	end
	zoneEvidence[mapID] = nil
	lastCalMap, lastCalX, lastCalY, lastCalFacing = nil, nil, nil, nil
	self:InvalidateMinimap()
end

--[[ Forget every measurement still in progress. ResetConfig replaces the saved
     table, so evidence gathered before it must not be added to evidence gathered
     after it and lock a ratio from movement the user asked to throw away.
]]
function TMP:DiscardAspectEvidence()
	zoneEvidence = {}
	lastCalMap, lastCalX, lastCalY, lastCalFacing = nil, nil, nil, nil
end

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

	-- Anchor on the player's *live* position, not on the newest trail sample.
	-- Using the newest sample makes the entire trail drift relative to the
	-- player between samples and then snap when a new sample lands, once per
	-- sampleInterval. Anchoring live means the trail sits still in the world
	-- while the player moves through it, which is what the eye expects.
	local anchorX, anchorY = self:GetLivePlayerPosition()
	if not anchorX then
		-- Position not trustworthy right now (browsing another zone, in an
		-- instance, loading). Leave the last frame on screen rather than
		-- flickering the trail out and back in.
		return
	end

	if self.Trail:Count(mapID) == 0 then
		releaseFrom(1)
		activeCount = 0
		return
	end

	local radius = currentRadius()
	local zoneYards = estimateYardsPerUnit(mapID)
	local mapW = Minimap:GetWidth()
	-- Pixels per yard on the current minimap.
	local pixPerYard = (mapW / 2) / radius
	-- Pixels per map unit along x.
	local pixPerUnit = zoneYards * pixPerYard

	--[[ y is scaled separately by the measured height/width ratio. Without this,
	     one map unit of y is treated as the same number of yards as one map unit
	     of x, which squashes the trail along y in any non-square zone and skews
	     every direction that is not exactly N/S/E/W.

	     1 while a zone is still calibrating, i.e. identical to the old behaviour.
	]]
	local aspect = aspectFor(db, mapID)
	local pixPerUnitY = pixPerUnit * aspect

	-- Minimap rotation has to be undone by hand: when rotateMinimap is on, the
	-- minimap's "up" is the player's facing, not north.
	local rotating = GetCVar("rotateMinimap") == "1"
	local facing = 0
	if rotating then
		-- GetPlayerFacing returns radians counter-clockwise from north. Ease
		-- towards it rather than snapping, so small camera twitches do not
		-- rotate the whole trail.
		local target = GetPlayerFacing() or 0
		smoothFacing = easeAngle(smoothFacing, target, FACING_SMOOTHING)
		facing = smoothFacing
	else
		smoothFacing = nil
	end
	local cosF, sinF = math.cos(facing), math.sin(facing)

	-- Skip the redraw when nothing that affects the output changed. Without
	-- this, dots are repositioned every frame even while standing still, and
	-- sub-pixel rounding makes them shimmer.
	--
	-- The fade must still animate while standing still, so the check includes an
	-- ageing term: alpha is quantised into ALPHA_BUCKETS steps over fadeTime, so
	-- the output can only change once per (fadeTime / ALPHA_BUCKETS) seconds.
	-- Redrawing on that cadence keeps the fade smooth without redrawing a
	-- visually identical frame.
	local count = self.Trail:Count(mapID)
	local zoom = Minimap:GetZoom()
	local now = GetTime()
	local bucketPeriod = TMP.db.fadeTime / ALPHA_BUCKETS

	if lastDrawX
		and lastDrawMapID == mapID
		and lastDrawCount == count
		and lastDrawZoom == zoom
		and lastDrawAspect == aspect
		and lastDrawTime and (now - lastDrawTime) < bucketPeriod
		and math.abs(anchorX - lastDrawX) < ANCHOR_EPSILON
		and math.abs(anchorY - lastDrawY) < ANCHOR_EPSILON
		and angleDelta(lastDrawFacing, facing) < FACING_EPSILON then
		return
	end
	lastDrawX, lastDrawY, lastDrawFacing = anchorX, anchorY, facing
	lastDrawZoom, lastDrawMapID, lastDrawCount = zoom, mapID, count
	lastDrawAspect = aspect
	lastDrawTime = now

	-- Cull anything beyond the visible circle.
	local limit = mapW / 2
	local limitSq = limit * limit

	local size = db.minimapDotSize
	local r, g, b = db.color.r, db.color.g, db.color.b
	local maxAlpha = db.maxAlpha

	local used = 0
	for s in self.Trail:Iterate(mapID) do
		-- Offset of this sample from the player, in map units.
		-- Map y grows downward (south), so north is -dy.
		local dx = (s.x - anchorX) * pixPerUnit
		local dy = (s.y - anchorY) * pixPerUnitY

		-- Screen offset: east is +x, north is +y on the minimap.
		local ox, oy = dx, -dy

		if rotating then
			-- Rotate the world offset into the minimap's rotated frame.
			ox, oy = ox * cosF - oy * sinF, ox * sinF + oy * cosF
		end

		local distSq = ox * ox + oy * oy
		if distSq <= limitSq then
			-- Fade towards the rim so dots dissolve rather than pop.
			local edgeFade = 1
			local fadeStartSq = limitSq * EDGE_FADE_START * EDGE_FADE_START
			if distSq > fadeStartSq then
				local dist = math.sqrt(distSq)
				local fadeStart = limit * EDGE_FADE_START
				edgeFade = 1 - (dist - fadeStart) / (limit - fadeStart)
				if edgeFade < 0 then edgeFade = 0 end
			end

			used = used + 1
			local tex = acquire(used)
			tex:ClearAllPoints()
			tex:SetPoint("CENTER", Minimap, "CENTER", ox, oy)
			tex:SetWidth(size)
			tex:SetHeight(size)

			local age = self.Trail:NormalisedAge(s, now)
			-- Quantise the age fade, not the scaled alpha, so rounding can
			-- never push a dot past maxAlpha. The edge fade is a continuous
			-- function of position and is applied on top, unquantised, since a
			-- dot's distance from the rim changes every frame anyway.
			local fade = 1 - age
			local bucket = math.floor(fade * ALPHA_BUCKETS + 0.5)
			local alpha = maxAlpha * (bucket / ALPHA_BUCKETS) * edgeFade
			tex:SetVertexColor(r, g, b, alpha)

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

--[[ Drop the redraw-skip cache.
     Must be called whenever something changes that the skip check does not
     itself compare (settings, visibility), or the next refresh takes the skip
     path and leaves a stale frame on screen.
]]
function TMP:InvalidateMinimap()
	lastDrawX, lastDrawY, lastDrawFacing = nil, nil, nil
	lastDrawZoom, lastDrawMapID, lastDrawCount = nil, nil, nil
	lastDrawAspect = nil
	lastDrawTime = nil
	smoothFacing = nil
end

-- Called by the options UI when showMinimap is toggled.
function TMP:ApplyMinimapVisibility()
	if not updater then return end
	self:InvalidateMinimap()
	if self.db and self.db.enabled and self.db.showMinimap then
		updater:Show()
	else
		updater:Hide()
		releaseFrom(1)
		activeCount = 0
	end
end
