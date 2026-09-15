--[[ Zone aspect-ratio calibration tests.

     What this covers: the minimap used to scale x and y by one factor, which
     squashes the trail in any non-square zone and skews every direction that is
     not exactly N/S/E/W. The height/width ratio is now measured from the
     player's own movement and then LOCKED PERMANENTLY.

     The locking is the part that matters most here. A continuously refined
     estimate would shift the whole trail underfoot on every update - the same
     class of bug that live anchoring and facing easing were added to remove. So
     several of these tests exist purely to prove the value never moves again
     once set.
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
local function near(name, got, want, tol)
	check(name, got and math.abs(got - want) <= tol,
		string.format("got %s, want %s +/- %s", tostring(got), tostring(want), tostring(tol)))
end

TMP.db.enabled = true
TMP.db.showMinimap = true

--[[ Walk a path whose true shape is known.

     The player moves at a constant speed in YARDS. In a zone that is `ratio`
     times taller than it is wide, covering the same yard distance along y takes
     `ratio` times fewer map units than along x. So to simulate a zone of a given
     aspect, a diagonal step in map units is (d, d/ratio).

     Feeding that in must make the calibration recover `ratio`.
]]
local function walkDiagonal(mapID, ratio, steps, stepSize)
	stepSize = stepSize or 0.004
	local x, y = 0.30, 0.30
	for i = 1, steps do
		x = x + stepSize
		y = y + stepSize / ratio
		setPos(x, y)
		advanceTime(1.0)
		onUpdate(core, 1.0)
	end
end

print("== a zone starts out unmeasured ==")
setTime(0); setMap(1, 2, 1); setInstance(false); WorldMapFrame.shown = false
setMinimapZoom(3)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
local state = TMP:GetAspectState(1)
check("fresh zone is not locked", state ~= "locked", "state=" .. tostring(state))

print("== a straight east-west run must NOT lock ==")
--[[ Running due east gives no information about the y axis at all. Locking on
     that evidence would bake in a meaningless number for the life of the zone.
]]
setMap(50, 2, 1)
setPos(0.20, 0.50)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
for i = 1, 40 do
	setPos(0.20 + i * 0.004, 0.50)   -- pure x movement
	advanceTime(1.0); onUpdate(core, 1.0)
end
local s50 = TMP:GetAspectState(50)
check("straight-line movement does not lock a ratio", s50 ~= "locked",
	"state=" .. tostring(s50))

print("== a straight north-south run must NOT lock either ==")
setMap(51, 2, 1)
setPos(0.50, 0.20)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
for i = 1, 40 do
	setPos(0.50, 0.20 + i * 0.004)   -- pure y movement
	advanceTime(1.0); onUpdate(core, 1.0)
end
local s51 = TMP:GetAspectState(51)
check("pure north-south movement does not lock a ratio", s51 ~= "locked",
	"state=" .. tostring(s51))

print("== a square zone measures ~1.0 ==")
setMap(2, 2, 1)
setPos(0.30, 0.30)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
walkDiagonal(2, 1.0, 30)
local st, val = TMP:GetAspectState(2)
eq("square zone locks", st, "locked")
near("square zone ratio is 1.0", val, 1.0, 0.05)

print("== a 3:2 zone (Icecrown-ish) measures ~0.667 ==")
--[[ Icecrown is roughly 4181 x 2787 yards, i.e. height/width ~= 0.667. Under the
     old single-scale code this zone's trail was stretched by 50% along y.
]]
setMap(3, 2, 1)
setPos(0.30, 0.30)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
walkDiagonal(3, 0.667, 30)
local st3, val3 = TMP:GetAspectState(3)
eq("3:2 zone locks", st3, "locked")
near("3:2 zone ratio recovered", val3, 0.667, 0.05)

print("== the locked value NEVER moves again ==")
--[[ The decisive test for the stability requirement. Keep walking - including
     along a deliberately DIFFERENT shape - and the locked ratio must not budge.
]]
local lockedBefore = select(2, TMP:GetAspectState(3))
walkDiagonal(3, 2.5, 60)          -- wildly different apparent shape
local lockedAfter = select(2, TMP:GetAspectState(3))
eq("further movement does not change a locked ratio", lockedAfter, lockedBefore)

walkDiagonal(3, 0.3, 60)          -- and again, the other way
eq("still unchanged after more contradictory movement",
	select(2, TMP:GetAspectState(3)), lockedBefore)

print("== a locked zone renders bit-identical frames ==")
--[[ This is the user-visible form of "locked means locked": standing still in a
     calibrated zone must produce byte-for-byte the same dot positions, with no
     drift creeping in from a still-updating estimate.
]]
local mlayer = _G["TrackMyPathMinimapLayer"]
TMP:ApplyMinimapVisibility()

--[[ Lay a short fresh trail and stand in the middle of it. Standing somewhere
     the trail is not would cull every dot, and the comparison below would then
     "pass" by comparing two empty frames.
]]
TMP.Trail:Clear()
setPos(0.50, 0.50)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
for i = 1, 8 do
	setPos(0.50 + i * 0.002, 0.50 + i * 0.001)
	advanceTime(1.0); onUpdate(core, 1.0)
end
setPos(0.508, 0.504)   -- inside the trail we just laid
TMP:InvalidateMinimap()
TMP:RefreshMinimap()

local function positions()
	local out = {}
	for i, t in ipairs(mlayer.children) do
		if t.shown and t.px then out[#out+1] = string.format("%.6f,%.6f", t.px, t.py) end
	end
	return table.concat(out, "|")
end

local frameA = positions()
-- Guard the guard: an empty frame would make the comparison below meaningless.
check("locked-zone frame actually drew dots", #frameA > 0, "frame was empty")

for i = 1, 30 do
	advanceTime(0.05)
	TMP:InvalidateMinimap()   -- force a real redraw, not a skipped one
	TMP:RefreshMinimap()
end
local frameB = positions()
check("repeated redraws in a locked zone are identical", frameA == frameB and #frameA > 0,
	string.format("len=%d identical=%s", #frameA, tostring(frameA == frameB)))

print("== the aspect actually reaches the drawing ==")
--[[ Prove the ratio is not merely stored but applied: the same north-south
     offset must be drawn differently in a 1:1 zone and a 3:2 zone.
]]
local function drawnSpanY(mapID)
	setMap(mapID, 2, 1)
	TMP.Trail:Clear()
	setPos(0.50, 0.50)
	onEvent(core, "ZONE_CHANGED_NEW_AREA")
	-- Lay two samples a fixed distance apart along y only.
	TMP.Trail:Add(mapID, 0.50, 0.50, GetTime())
	TMP.Trail:Add(mapID, 0.50, 0.53, GetTime())
	setPos(0.50, 0.50)
	TMP:InvalidateMinimap()
	TMP:RefreshMinimap()
	local lo, hi = math.huge, -math.huge
	for _, t in ipairs(mlayer.children) do
		if t.shown and t.py then
			if t.py < lo then lo = t.py end
			if t.py > hi then hi = t.py end
		end
	end
	return hi - lo
end

-- Zone 2 locked at ~1.0, zone 3 locked at ~0.667.
local spanSquare = drawnSpanY(2)
local spanTall   = drawnSpanY(3)
print(string.format("   same 0.03 y-offset draws as %.2f px (ratio 1.0) vs %.2f px (ratio 0.667)",
	spanSquare, spanTall))
check("a non-square zone draws y at a different scale", spanSquare > 0 and spanTall > 0
	and math.abs(spanSquare - spanTall) > 1,
	string.format("square=%.3f tall=%.3f", spanSquare, spanTall))
-- The 0.667 zone must compress y relative to the square one, by roughly that factor.
near("y scale follows the measured ratio", spanTall / spanSquare, 0.667, 0.08)

print("== /tmp calibrate clears the lock ==")
setMap(3, 2, 1)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
eq("zone 3 is locked before", select(1, TMP:GetAspectState(3)), "locked")
SlashCmdList["TRACKMYPATH"]("calibrate")
check("calibrate clears the locked ratio", TMP:GetAspectState(3) ~= "locked",
	"state=" .. tostring(TMP:GetAspectState(3)))

print("== the lock survives a config reload, but not a reset ==")
--[[ zoneAspect lives in SavedVariables so a relog does not re-enter the
     measuring state. Simulate a reload by re-running InitConfig over the same
     saved table.
]]
setMap(4, 2, 1)
setPos(0.30, 0.30)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
walkDiagonal(4, 0.8, 30)
eq("zone 4 locked", select(1, TMP:GetAspectState(4)), "locked")
local before4 = select(2, TMP:GetAspectState(4))

TMP:InitConfig()      -- as if the addon reloaded against existing SavedVariables
near("locked ratio survives a reload", select(2, TMP:GetAspectState(4)), before4, 1e-9)

TMP:ResetConfig()
check("reset drops locked ratios", TMP:GetAspectState(4) ~= "locked",
	"state=" .. tostring(TMP:GetAspectState(4)))

print("== an implausible measurement is rejected, not locked ==")
--[[ A teleport or a custom-server oddity must not permanently bake in a
     nonsense ratio. Movement shaped like a 20:1 zone is outside every real
     WotLK zone and must be discarded.
]]
TMP.db.enabled = true
setMap(5, 2, 1)
setPos(0.30, 0.30)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
walkDiagonal(5, 20.0, 40)
check("absurd ratio is not locked in", TMP:GetAspectState(5) ~= "locked",
	"state=" .. tostring(TMP:GetAspectState(5)))

print("== calibration does not run in untrackable places ==")
setMap(6, 2, 1)
setPos(0.30, 0.30)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
setInstance(true)
walkDiagonal(6, 0.667, 40)
setInstance(false)
check("no lock while in an instance", TMP:GetAspectState(6) ~= "locked",
	"state=" .. tostring(TMP:GetAspectState(6)))

print("")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
