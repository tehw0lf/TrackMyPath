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

     The world is a zone `ratio` times as tall as it is wide. A step covers
     `east` yards eastward and `north` yards northward, both in units of the
     zone's WIDTH, so on the map it is (east, -north / ratio): map y grows south,
     and the same yard distance spans `ratio` times fewer map units along y.

     The character faces the way it moves, as it does when running forward;
     `faceAs` overrides that to simulate strafing or backpedalling.

     Feeding such a walk in must make the calibration recover `ratio`.
]]
local TWO_PI = 2 * math.pi

local function stepTo(pos, ratio, east, north, faceAs)
	pos.x = pos.x + east
	pos.y = pos.y - north / ratio
	-- GetPlayerFacing is counter-clockwise from north: east is 3pi/2.
	setFacing(faceAs or (math.atan2(-east, north) % TWO_PI))
	setPos(pos.x, pos.y)
	advanceTime(1.0)
	onUpdate(core, 1.0)
end

-- Heading `deg` degrees counter-clockwise from north, `size` width-units per step.
local function headingStep(pos, ratio, deg, size)
	local th = math.rad(deg)
	stepTo(pos, ratio, -math.sin(th) * size, math.cos(th) * size)
end

-- A south-east run, the shape the old tests used.
local function walkDiagonal(mapID, ratio, steps, stepSize)
	stepSize = stepSize or 0.004
	local pos = { x = 0.30, y = 0.30 }
	for i = 1, steps do
		stepTo(pos, ratio, stepSize, -stepSize)
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
do
	local pos = { x = 0.20, y = 0.50 }
	for i = 1, 40 do stepTo(pos, 1.0, 0.004, 0) end   -- pure x movement
end
local s50 = TMP:GetAspectState(50)
check("straight-line movement does not lock a ratio", s50 ~= "locked",
	"state=" .. tostring(s50))

print("== a straight north-south run must NOT lock either ==")
setMap(51, 2, 1)
setPos(0.50, 0.20)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
do
	local pos = { x = 0.50, y = 0.20 }
	for i = 1, 40 do stepTo(pos, 1.0, 0, -0.004) end   -- pure y movement
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

print("== a lopsided path measures the zone, not the path ==")
--[[ The case the first version of this got wrong. Compare raw movement
     (sqrt(sum dx^2 / sum dy^2)) and a square zone run mostly east, with only 15%
     of the squared distance north-south, locks a ratio of ~2.4 - permanently.
     The heading removes that: whichever way the path leans, the answer is the
     zone's shape.
]]
local function lopsided(mapID, ratio, deg, steps)
	setMap(mapID, 2, 1)
	setPos(0.10, 0.50)
	onEvent(core, "ZONE_CHANGED_NEW_AREA")
	local pos = { x = 0.10, y = 0.50 }
	for i = 1, steps do headingStep(pos, ratio, deg, 0.004) end
end

-- 22.8 degrees north of east: cos^2 = 0.85, the 85/15 split of the report.
lopsided(7, 1.0, 90 - 22.8 + 180, 30)    -- heading counter-clockwise from north
do
	local st7, v7 = TMP:GetAspectState(7)
	eq("square zone, mostly-east run locks", st7, "locked")
	check("square zone, mostly-east run is not read as ~2.4", v7 and v7 < 1.5, "got " .. tostring(v7))
	near("square zone, mostly-east run is ~1.0", v7, 1.0, 0.05)
end

lopsided(8, 0.667, 90 - 22.8, 30)
do
	local st8, v8 = TMP:GetAspectState(8)
	eq("3:2 zone, mostly-east run locks", st8, "locked")
	near("3:2 zone, mostly-east run is ~0.667", v8, 0.667, 0.05)
end

lopsided(9, 1.0, 22.8, 30)               -- mostly north instead
do
	local st9, v9 = TMP:GetAspectState(9)
	eq("square zone, mostly-north run locks", st9, "locked")
	near("square zone, mostly-north run is ~1.0", v9, 1.0, 0.05)
end

print("== strafing and backpedalling do not skew the result ==")
--[[ The character is not always moving the way it faces. Strafe steps move 90
     degrees off the heading, backpedal steps move opposite to it. Both would feed
     the fit a wrong direction, so they have to be dropped, not averaged in.
]]
setMap(10, 2, 1)
setPos(0.30, 0.30)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
do
	local pos = { x = 0.30, y = 0.30 }
	local size = 0.004
	local faceSE = math.atan2(-size, -size) % TWO_PI
	for i = 1, 60 do
		if i % 3 == 0 then
			-- strafe: face south-east, move south-west
			stepTo(pos, 0.667, -size, -size, faceSE)
		elseif i % 5 == 0 then
			-- backpedal: face south-east, move north-west
			stepTo(pos, 0.667, -size, size, faceSE)
		else
			stepTo(pos, 0.667, size, -size)
		end
	end
	local st10, v10 = TMP:GetAspectState(10)
	eq("zone with strafe and backpedal steps locks", st10, "locked")
	near("strafe and backpedal steps are ignored", v10, 0.667, 0.05)
end

print("== no facing, no measurement ==")
do
	-- The point of the test: with GetPlayerFacing nil at sampling time, a step
	-- gives no heading and must be dropped rather than guessed.
	setMap(12, 2, 1)
	setPos(0.30, 0.30)
	onEvent(core, "ZONE_CHANGED_NEW_AREA")
	local x, y = 0.30, 0.30
	setFacing(nil)
	for i = 1, 40 do
		x, y = x + 0.004, y + 0.004 / 0.667
		setPos(x, y); advanceTime(1.0); onUpdate(core, 1.0)
	end
	check("steps without a facing never lock a ratio", TMP:GetAspectState(12) ~= "locked",
		"state=" .. tostring(TMP:GetAspectState(12)))
	eq("and collect no evidence", TMP:GetAspectState(12), "idle")
	setFacing(0)
end

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

print("== /tmp reset throws away a measurement in progress ==")
--[[ ResetConfig replaces the saved table but the evidence lives in Minimap.lua.
     Evidence from before the reset must not count towards a lock after it.
]]
setMap(13, 2, 1)
setPos(0.30, 0.30)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
do
	local pos = { x = 0.30, y = 0.30 }
	for i = 1, 8 do stepTo(pos, 0.667, 0.004, -0.004) end
	local st, n = TMP:GetAspectState(13)
	eq("eight steps in: still measuring", st, "measuring")

	TMP:ResetConfig()
	TMP.db.enabled = true
	eq("reset forgets the evidence", TMP:GetAspectState(13), "idle")

	for i = 1, 8 do stepTo(pos, 0.667, 0.004, -0.004) end
	check("8 + 8 steps across a reset do not lock", TMP:GetAspectState(13) ~= "locked",
		"state=" .. tostring(TMP:GetAspectState(13)))
	local st2, n2 = TMP:GetAspectState(13)
	eq("only the steps after the reset count", n2, 7)
	TMP.db.showMinimap = true
end

print("")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
