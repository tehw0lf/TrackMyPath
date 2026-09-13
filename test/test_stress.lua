--[[ Stress test: the real farming scenario.
     10 minutes of continuous movement at 1 sample/second, then verify the
     buffer stays bounded, the render layer does not leak textures, and the
     per-frame redraw cost does not grow over time.
]]
dofile("test/harness.lua")
dofile("Config.lua")
dofile("Core.lua")
dofile("Trail.lua")
dofile("WorldMap.lua")
dofile("Minimap.lua")
dofile("Options.lua")

local TMP = TrackMyPath
local core = TMP.coreFrame
local onEvent, onUpdate = core:GetScript("OnEvent"), core:GetScript("OnUpdate")
onEvent(core, "ADDON_LOADED", "TrackMyPath")

local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then pass = pass + 1; print("  ok   " .. name)
	else fail = fail + 1; print("  FAIL " .. name .. "  -> " .. tostring(extra)) end
end

setTime(0); setMap(1, 2, 1); setInstance(false); WorldMapFrame.shown = false
onEvent(core, "ZONE_CHANGED_NEW_AREA")

-- Simulate a circular farming route: never stands still, never leaves the zone.
local SECONDS = 1800  -- 30 minutes, i.e. 3x the fade window
local peak = 0
for t = 1, SECONDS do
	local a = t * 0.05
	setPos(0.5 + 0.2 * math.cos(a), 0.5 + 0.2 * math.sin(a))
	advanceTime(1.0)
	onUpdate(core, 1.0)
	local c = TMP.Trail:Count(1)
	if c > peak then peak = c end
end

print(string.format("== 30 min of continuous movement (fade=%ds, rate=%.1fs) ==",
	TMP.db.fadeTime, TMP.db.sampleInterval))
print(string.format("   peak live samples: %d", peak))
print(string.format("   final live samples: %d", TMP.Trail:Count(1)))

-- With fadeTime=600 and 1 sample/s, the steady state is ~600 samples.
-- Allow slack for the 2s prune interval.
check("buffer stays bounded near fadeTime/rate", peak <= 620, "peak=" .. peak)
check("buffer did not collapse", TMP.Trail:Count(1) > 500, "final=" .. TMP.Trail:Count(1))
check("hard cap never exceeded", peak <= TMP.db.maxSamples, "peak=" .. peak)

-- Render and count textures.
WorldMapFrame.shown = true
TMP:RefreshWorldMap()
local layer = _G["TrackMyPathWorldMapLayer"]
local created = #layer.children
print(string.format("   textures in pool after first draw: %d", created))

-- Redraw many times; the pool must not grow.
for i = 1, 200 do TMP:RefreshWorldMap() end
check("texture pool does not grow across 200 redraws", #layer.children == created,
	string.format("%d -> %d", created, #layer.children))

-- Keep walking for another 10 minutes while redrawing every frame, the way it
-- behaves with the map held open.
for t = 1, 600 do
	local a = (SECONDS + t) * 0.05
	setPos(0.5 + 0.2 * math.cos(a), 0.5 + 0.2 * math.sin(a))
	advanceTime(1.0)
	onUpdate(core, 1.0)
	TMP:RefreshWorldMap()
end
check("pool still bounded after another 10 min", #layer.children <= TMP.db.maxSamples,
	"pool=" .. #layer.children)
print(string.format("   final texture pool: %d", #layer.children))

-- Alpha gradient sanity: walk the drawn dots and confirm alpha rises
-- monotonically from oldest to newest (allowing for bucket quantisation).
TMP:RefreshWorldMap()
local n = TMP.Trail:Count(1)
local violations = 0
local prev = -1
for i = 1, n do
	local tex = layer.children[i]
	if tex and tex.shown and tex.vc then
		local a = tex.vc[4]
		if a + 1e-9 < prev then violations = violations + 1 end
		prev = a
	end
end
check("alpha increases from oldest to newest dot", violations == 0,
	"violations=" .. violations)

-- The oldest visible dot should be near-transparent, the newest near maxAlpha.
local oldest = layer.children[1]
local newest = layer.children[n]
if oldest and newest and oldest.vc and newest.vc then
	print(string.format("   oldest alpha=%.3f  newest alpha=%.3f (maxAlpha=%.2f)",
		oldest.vc[4], newest.vc[4], TMP.db.maxAlpha))
	check("oldest dot is faint", oldest.vc[4] < 0.2, oldest.vc[4])
	check("newest dot is near maxAlpha", newest.vc[4] > TMP.db.maxAlpha - 0.1, newest.vc[4])
end

print("== zone hopping does not leak buckets ==")
TMP.Trail:Clear()
TMP.db.fadeTime = 60
for zone = 1, 40 do
	setMap(zone, 2, 1)
	onEvent(core, "ZONE_CHANGED_NEW_AREA")
	for t = 1, 10 do
		setPos(0.3 + t * 0.02, 0.3)
		advanceTime(1.0); onUpdate(core, 1.0)
	end
end
-- Most of those zones are now long expired; pruning should have drained them.
advanceTime(200); onUpdate(core, 200)
local active = TMP.Trail:ActiveZoneCount()
print(string.format("   active zones after hopping 40 zones + 200s idle: %d", active))
check("expired zone buckets drained", active <= 1, "active=" .. active)
check("total samples drained", TMP.Trail:TotalCount() == 0, TMP.Trail:TotalCount())

print("")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
