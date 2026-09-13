--[[ Minimap layer tests.

     The bug these exist for: the trail used to be anchored on the newest trail
     *sample* rather than the player's live position. Between samples the player
     moved but the anchor did not, so the whole trail slid relative to the
     player and then snapped back when a new sample landed - once per
     sampleInterval. These tests pin the corrected behaviour.
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
local function eq(name, got, want)
	check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end

local mlayer
local function shownDots()
	local out = {}
	for _, t in ipairs(mlayer.children) do
		if t.shown then out[#out+1] = t end
	end
	return out
end

-- Record the screen offset of every visible dot, keyed by texture identity, so
-- successive frames can be compared.
local function snapshot()
	local snap = {}
	for i, t in ipairs(mlayer.children) do
		if t.shown then snap[i] = { t.px, t.py } end
	end
	return snap
end

TMP.db.showMinimap = true
TMP.db.enabled = true
setTime(0); setMap(1, 2, 1); setInstance(false); WorldMapFrame.shown = false
setMinimapZoom(3)
onEvent(core, "ZONE_CHANGED_NEW_AREA")

-- Lay down a trail while walking east.
for i = 1, 20 do
	setPos(0.30 + i * 0.005, 0.50)
	advanceTime(1.0); onUpdate(core, 1.0)
end
TMP:ApplyMinimapVisibility()
TMP:RefreshMinimap()
mlayer = _G["TrackMyPathMinimapLayer"]
TMP:InvalidateMinimap()
TMP:RefreshMinimap()

print("== trail is drawn ==")
local dots = shownDots()
check("minimap draws dots", #dots > 0, "#dots=" .. #dots)

print("== anchored on live position, not on last sample ==")
--[[ The decisive test. Move the player a small amount WITHOUT letting a new
     sample be taken, then redraw. Every dot must shift by exactly the negative
     of the player's movement, because the trail is fixed in the world and the
     player moved through it.

     Under the old sample-anchored code the dots would not move at all here, and
     would then jump by the full sample distance when the next sample landed.
]]
local px0, py0 = 0.40, 0.50
setPos(px0, py0)
TMP:InvalidateMinimap()
TMP:RefreshMinimap()
local before = snapshot()

-- Nudge the player east by a fraction of a sample step. No onUpdate, so no new
-- sample is recorded.
local step = 0.001
setPos(px0 + step, py0)
TMP:InvalidateMinimap()
TMP:RefreshMinimap()
local after = snapshot()

-- Every dot must have moved west (negative x) by the same amount.
local deltas = {}
for i, b in pairs(before) do
	local a = after[i]
    if a then deltas[#deltas+1] = a[1] - b[1] end
end
check("dots moved when player moved between samples", #deltas > 0, "#deltas=" .. #deltas)

local allNegative, spread = true, 0
local first = deltas[1]
for _, d in ipairs(deltas) do
	if d >= 0 then allNegative = false end
	local diff = math.abs(d - first)
	if diff > spread then spread = diff end
end
check("all dots shifted west as the player moved east", allNegative,
	"first delta=" .. tostring(first))
check("all dots shifted by the SAME amount (rigid trail)", spread < 0.001,
	"spread=" .. spread)

print("== no snap when a new sample lands ==")
--[[ Walk in small steps, redrawing every step, and watch a single dot. With a
     live anchor its motion must be smooth: no step may be dramatically larger
     than the others. Under the old code the frame where a sample landed showed
     a jump.
]]
TMP.Trail:Clear()
setPos(0.40, 0.50)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
for i = 1, 10 do
	setPos(0.40 + i * 0.004, 0.50)
	advanceTime(1.0); onUpdate(core, 1.0)
end
TMP:InvalidateMinimap()
TMP:RefreshMinimap()

--[[ Follow ONE identifiable dot across many sub-sample frames.

     Tracking "the first visible dot" or "the last visible dot" is wrong: dots
     are drawn into a pool in trail iteration order and culled at the rim, so as
     soon as any dot enters or leaves the circle every later dot shifts slot and
     the comparison silently switches subjects. That shows up as a multi-pixel
     jump the addon never made.

     The robust approach is to derive the expected offset for one chosen sample
     analytically and compare the drawn set against it. Since a dot's offset is a
     pure function of (sample - anchor), the per-frame change of ANY dot equals
     the per-frame change of the anchor. So rather than following a slot, assert
     on the property that actually matters: within a single frame, every dot must
     have moved by the same amount as every other dot (a rigid trail), and that
     common shift must match the player's own movement.
]]
local perStep = 0.0004   -- 10 sub-steps per 0.004 sample step
local commonShifts = {}
local rigidityViolations = 0

local function offsetsByPosition()
	-- Key each drawn dot by its rounded offset so a frame can be compared to the
	-- next without relying on pool order.
	local out = {}
	for _, t in ipairs(mlayer.children) do
		if t.shown and t.px then out[#out+1] = { t.px, t.py } end
	end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	return out
end

local prevFrame = nil
for i = 1, 40 do
	setPos(0.44 + i * perStep, 0.50)
	advanceTime(0.1)
	onUpdate(core, 0.1)
	TMP:InvalidateMinimap()
	TMP:RefreshMinimap()

	local frame = offsetsByPosition()
	if prevFrame and #frame == #prevFrame and #frame > 1 then
		-- Same number of dots: the sets correspond, so per-dot deltas are
		-- meaningful. They must all be equal.
		local deltas = {}
		for k = 1, #frame do
			deltas[k] = frame[k][1] - prevFrame[k][1]
		end
		local lo, hi = deltas[1], deltas[1]
		for _, d in ipairs(deltas) do
			if d < lo then lo = d end
			if d > hi then hi = d end
		end
		if (hi - lo) > 0.01 then rigidityViolations = rigidityViolations + 1 end
		commonShifts[#commonShifts+1] = math.abs(deltas[1])
	end
	prevFrame = frame
end

check("collected frames to compare", #commonShifts > 15, "#=" .. #commonShifts)
check("the trail moves rigidly - every dot shifts alike", rigidityViolations == 0,
	"violations=" .. rigidityViolations)

local steps = commonShifts
local maxStep, sum = 0, 0
for _, v in ipairs(steps) do
	if v > maxStep then maxStep = v end
	sum = sum + v
end
local meanStep = sum / math.max(#steps, 1)
print(string.format("   common per-frame shift: mean %.4f px, max %.4f px", meanStep, maxStep))
-- With a live anchor the shift per frame is the player's own movement, which is
-- constant in this walk. A snap would show up as a max far above the mean.
check("per-frame shift is steady, no snap", maxStep <= meanStep * 1.5 + 0.01,
	string.format("mean=%.4f max=%.4f", meanStep, maxStep))

print("== redraw is skipped while standing perfectly still ==")
--[[ Standing still must not reposition dots every frame, but the fade must
     still progress. The skip is time-bounded by fadeTime/ALPHA_BUCKETS.
]]
local calls = 0
local realSetPoint = {}
for i, t in ipairs(mlayer.children) do
	realSetPoint[i] = t.SetPoint
	t.SetPoint = function(self, ...) calls = calls + 1; return realSetPoint[i](self, ...) end
end

TMP.db.fadeTime = 600   -- bucketPeriod = 600/16 = 37.5s
TMP:InvalidateMinimap()
TMP:RefreshMinimap()
calls = 0
-- 20 redraws at the same position within one bucket period.
for i = 1, 20 do
	advanceTime(0.05)
	TMP:RefreshMinimap()
end
eq("no repositioning while stationary inside one alpha bucket", calls, 0)

print("== fade still progresses while standing still ==")
calls = 0
advanceTime(40)          -- past bucketPeriod of 37.5s
TMP:RefreshMinimap()
check("redraw happens once the alpha bucket would change", calls > 0, "calls=" .. calls)

print("== zoom change forces a redraw ==")
calls = 0
setMinimapZoom(1)
TMP:RefreshMinimap()
check("zoom change redraws", calls > 0, "calls=" .. calls)
setMinimapZoom(3)

print("== rotation easing takes the short way round ==")
--[[ easeAngle must not spin the long way when the facing wraps past north.
     Reach into the module by exercising the observable behaviour: set a facing
     just below 2pi, then just above 0, and confirm dots do not swing through a
     large arc.
]]
SetCVarStub("rotateMinimap", "1")
TMP.Trail:Clear()
setPos(0.50, 0.50)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
for i = 1, 8 do
	setPos(0.50 + i * 0.004, 0.50)
	advanceTime(1.0); onUpdate(core, 1.0)
end

-- Settle the eased angle at just under 2*pi.
setFacing(6.28)
TMP:InvalidateMinimap()
for i = 1, 60 do TMP:RefreshMinimap(); advanceTime(0.05) end
local d = shownDots()
local settledX, settledY = d[1] and d[1].px, d[1] and d[1].py
check("dot tracked before wrap", settledX ~= nil)

-- Now wrap past north to 0.02 rad. The true angular change is ~0.02 rad, so the
-- dot should barely move even after easing converges.
setFacing(0.02)
for i = 1, 60 do TMP:RefreshMinimap(); advanceTime(0.05) end
d = shownDots()
local wrappedX, wrappedY = d[1] and d[1].px, d[1] and d[1].py
if settledX and wrappedX then
	local moved = math.sqrt((wrappedX-settledX)^2 + (wrappedY-settledY)^2)
	local radius = math.sqrt(settledX^2 + settledY^2)
	print(string.format("   dot moved %.3f px on a %.3f px radius across the wrap", moved, radius))
	-- A long-way-round spin would sweep the dot across most of the diameter.
	check("wrapping past north does not spin the trail", moved < radius * 0.5,
		string.format("moved=%.3f radius=%.3f", moved, radius))
end

print("== rotation easing smooths a sudden turn ==")
-- A 90 degree snap must be approached gradually, not applied in one frame.
setFacing(0)
TMP:InvalidateMinimap()
for i = 1, 80 do TMP:RefreshMinimap(); advanceTime(0.05) end
d = shownDots()
local ax, ay = d[1] and d[1].px, d[1] and d[1].py

setFacing(math.pi / 2)
TMP:RefreshMinimap()          -- exactly ONE frame after the turn
d = shownDots()
local bx, by = d[1] and d[1].px, d[1] and d[1].py

-- Converge fully.
for i = 1, 120 do TMP:RefreshMinimap(); advanceTime(0.05) end
d = shownDots()
local cx, cy = d[1] and d[1].px, d[1] and d[1].py

if ax and bx and cx then
	local oneFrame = math.sqrt((bx-ax)^2 + (by-ay)^2)
	local total = math.sqrt((cx-ax)^2 + (cy-ay)^2)
	print(string.format("   one frame moved %.3f of the total %.3f", oneFrame, total))
	check("a 90 degree turn is not applied in a single frame",
		total > 0 and oneFrame < total * 0.6,
		string.format("one=%.3f total=%.3f", oneFrame, total))
	check("the turn does converge eventually", total > 0.5, "total=" .. total)
end
SetCVarStub("rotateMinimap", "0")

print("== dots outside the minimap circle are culled ==")
TMP.Trail:Clear()
TMP.db.fadeTime = 600
setMap(1, 2, 1)
setPos(0.10, 0.10)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
-- Walk a long way across the zone so early dots fall far outside the circle.
for i = 1, 60 do
	setPos(0.10 + i * 0.012, 0.10)
	advanceTime(1.0); onUpdate(core, 1.0)
end
TMP:InvalidateMinimap()
TMP:RefreshMinimap()
local total = TMP.Trail:Count(1)
local visible = #shownDots()
print(string.format("   %d samples recorded, %d drawn on the minimap", total, visible))
check("distant dots are culled", visible < total, string.format("%d of %d", visible, total))
check("some near dots survive", visible > 0, "visible=" .. visible)

print("== dots fade towards the rim instead of popping ==")
--[[ A dot crossing the minimap edge used to vanish in one frame. The outer band
     now fades it out, so alpha must decrease with distance from the centre.
]]
do
	local outer, inner = nil, nil
	local outerD, innerD = -1, math.huge
	for _, t in ipairs(mlayer.children) do
		if t.shown and t.px and t.vc then
			local d = math.sqrt(t.px * t.px + t.py * t.py)
			if d > outerD then outerD, outer = d, t end
			if d < innerD then innerD, inner = d, t end
		end
	end
	if outer and inner and outer ~= inner then
		local radius = Minimap:GetWidth() / 2
		print(string.format("   innermost dot at %.1f px alpha %.3f | outermost at %.1f px alpha %.3f (radius %.0f)",
			innerD, inner.vc[4], outerD, outer.vc[4], radius))
		-- Only meaningful if the outer dot is actually inside the fade band.
		if outerD > radius * 0.8 then
			check("dot near the rim is fainter than one near the centre",
				outer.vc[4] < inner.vc[4],
				string.format("outer=%.3f inner=%.3f", outer.vc[4], inner.vc[4]))
		else
			print("   (outermost dot not in the fade band; skipping comparison)")
		end
	end
end

print("== hiding the layer clears it, re-enabling redraws ==")
TMP.db.showMinimap = false
TMP:ApplyMinimapVisibility()
eq("all hidden when disabled", #shownDots(), 0)
TMP.db.showMinimap = true
TMP:ApplyMinimapVisibility()
TMP:RefreshMinimap()
check("dots return when re-enabled", #shownDots() > 0, "#dots=" .. #shownDots())

print("== no draw while position is untrustworthy ==")
-- Browsing a foreign zone: the last frame should be left alone, not flickered.
local beforeCount = #shownDots()
setMap(99, 2, 5)
TMP:RefreshMinimap()
eq("frame left intact while browsing elsewhere", #shownDots(), beforeCount)
setMap(1, 2, 1)

print("")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
