--[[ TrackMyPath - Trail.lua
     The data model: recording position samples and ageing them out.

     Samples are stored per map area ID, so walking from one zone into the next
     does not connect unrelated dots, and so the world map only ever draws the
     trail belonging to the zone currently displayed.

     Storage is an array used as a FIFO with explicit head/tail indices rather
     than table.remove(t, 1). Two reasons:

       - table.remove from the front is O(n) and would shift up to maxSamples
         entries on every expiry tick; moving an index is O(1).
       - Freeing entries by assigning nil leaves holes in the array, and the #
         operator is explicitly undefined on a table with holes. So the live
         range is tracked as [head, tail] and # is never used on samples.
]]

local TMP = TrackMyPath

-- zones[mapAreaID] = { samples = {}, head = 1, tail = 0 }
-- Live range is samples[head..tail]; empty when tail < head.
local zones = {}

TMP.Trail = {}
local Trail = TMP.Trail

local function getZone(mapID)
	local z = zones[mapID]
	if not z then
		z = { samples = {}, head = 1, tail = 0 }
		zones[mapID] = z
	end
	return z
end

-- Number of live samples in a zone bucket.
function Trail:Count(mapID)
	local z = zones[mapID]
	if not z then return 0 end
	local n = z.tail - z.head + 1
	if n < 0 then return 0 end
	return n
end

-- Iterate live samples oldest-first.
-- Callers must not add or remove samples while iterating.
function Trail:Iterate(mapID)
	local z = zones[mapID]
	if not z then return function() return nil end end
	local samples = z.samples
	local i, tail = z.head - 1, z.tail
	return function()
		i = i + 1
		if i > tail then return nil end
		return samples[i]
	end
end

-- Most recent sample of a zone, or nil.
function Trail:Latest(mapID)
	local z = zones[mapID]
	if not z or z.tail < z.head then return nil end
	return z.samples[z.tail]
end

--[[ Record a sample.
     Returns true if a sample was stored, false if it was rejected for being too
     close to the previous one.
]]
function Trail:Add(mapID, x, y, now)
	local db = TMP.db
	local z = getZone(mapID)
	local samples = z.samples

	-- Reject samples that barely moved, so standing still does not stack dots.
	if z.tail >= z.head then
		local last = samples[z.tail]
		local dx, dy = x - last.x, y - last.y
		if (dx * dx + dy * dy) < (db.minDistance * db.minDistance) then
			return false
		end
	end

	z.tail = z.tail + 1
	samples[z.tail] = { x = x, y = y, t = now }

	-- Enforce the hard cap by advancing the head past the oldest entries.
	local live = z.tail - z.head + 1
	if live > db.maxSamples then
		local newHead = z.head + (live - db.maxSamples)
		for i = z.head, newHead - 1 do
			samples[i] = nil
		end
		z.head = newHead
	end

	return true
end

--[[ Drop samples older than fadeTime.
     Samples are appended in chronological order, so expired entries are always
     a prefix of the live range and this only ever walks the front.
]]
function Trail:Prune(now)
	local cutoff = now - TMP.db.fadeTime
	for mapID, z in pairs(zones) do
		local samples = z.samples
		local head, tail = z.head, z.tail
		while head <= tail and samples[head].t < cutoff do
			samples[head] = nil
			head = head + 1
		end
		z.head = head

		-- Bucket fully drained: reset it so the indices do not drift upward
		-- forever across a long session.
		if head > tail then
			z.samples = {}
			z.head = 1
			z.tail = 0
		end
	end
end

--[[ Age of a sample normalised to 0..1, where 0 is brand new and 1 is expired.
]]
function Trail:NormalisedAge(sample, now)
	local age = (now - sample.t) / TMP.db.fadeTime
	if age < 0 then return 0 end
	if age > 1 then return 1 end
	return age
end

-- Clear one zone, or everything when mapID is nil.
function Trail:Clear(mapID)
	if mapID then
		zones[mapID] = nil
	else
		zones = {}
	end
end

-- Total live samples across all zones, for the status readout.
function Trail:TotalCount()
	local total = 0
	for mapID, z in pairs(zones) do
		local n = z.tail - z.head + 1
		if n > 0 then total = total + n end
	end
	return total
end

-- Zones that currently hold samples, for the status readout.
function Trail:ActiveZoneCount()
	local n = 0
	for mapID, z in pairs(zones) do
		if z.tail >= z.head then n = n + 1 end
	end
	return n
end
