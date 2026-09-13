dofile("test/harness.lua")
dofile("Config.lua")
dofile("Core.lua")
dofile("Trail.lua")
dofile("WorldMap.lua")
dofile("Minimap.lua")
dofile("Options.lua")

local TMP = TrackMyPath
local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then pass = pass + 1; print("  ok   " .. name)
	else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end
local function eq(name, got, want)
	check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end

-- Boot the addon the way the client would.
local core = TMP.coreFrame
local onEvent = core:GetScript("OnEvent")
local onUpdate = core:GetScript("OnUpdate")

print("== ADDON_LOADED wiring ==")
-- Wrong addon name must be ignored.
onEvent(core, "ADDON_LOADED", "SomeOtherAddon")
eq("ignores other addons", TMP.db, nil)
onEvent(core, "ADDON_LOADED", "TrackMyPath")
check("db initialised", TMP.db ~= nil)
eq("fadeTime default is 600", TMP.db.fadeTime, 600)
check("slash registered", SlashCmdList["TRACKMYPATH"] ~= nil)

-- Helper: drive the OnUpdate loop for `seconds`, in `step` slices.
local function run(seconds, step)
	step = step or 0.25
	local t = 0
	while t < seconds do
		advanceTime(step)
		onUpdate(core, step)
		t = t + step
	end
end

print("== records while walking in own zone ==")
TMP.Trail:Clear()
setTime(10000)
setMap(1, 2, 1)          -- area 1, continent 2, zone 1 -> trackable
setInstance(false)
WorldMapFrame.shown = false
-- establish playerMapID
onEvent(core, "ZONE_CHANGED_NEW_AREA")
eq("playerMapID resolved", TMP:GetPlayerMapID(), 1)

-- Walk: move position a bit every second for 10 seconds.
for i = 1, 10 do
	setPos(0.20 + i * 0.02, 0.30 + i * 0.01)
	advanceTime(1.0)
	onUpdate(core, 1.0)
end
local n = TMP.Trail:Count(1)
check("samples recorded while walking", n >= 8, "count=" .. n)

print("== standing still does not stack dots ==")
local before = TMP.Trail:Count(1)
-- Must genuinely differ from the walk loop's last position (0.40, 0.40),
-- otherwise this is a no-op and gets rejected as "did not move".
setPos(0.60, 0.55)       -- move once to a new spot
advanceTime(1.0); onUpdate(core, 1.0)
local afterMove = TMP.Trail:Count(1)
eq("the move itself recorded", afterMove, before + 1)
-- Now hold perfectly still at (0.60, 0.55) for 10 seconds.
for i = 1, 10 do
	advanceTime(1.0)
	onUpdate(core, 1.0)
end
eq("no dots added while stationary", TMP.Trail:Count(1), afterMove)

print("== instances are rejected ==")
TMP.Trail:Clear()
setInstance(true)
setPos(0.5, 0.5)
for i = 1, 5 do
	setPos(0.5 + i * 0.02, 0.5)
	advanceTime(1.0); onUpdate(core, 1.0)
end
eq("nothing recorded in instance", TMP.Trail:Count(1), 0)
setInstance(false)

print("== 0,0 position is rejected ==")
TMP.Trail:Clear()
setPos(0, 0)
for i = 1, 5 do advanceTime(1.0); onUpdate(core, 1.0) end
eq("0,0 not recorded", TMP.Trail:Count(1), 0)

print("== continent / cosmic view rejected ==")
TMP.Trail:Clear()
setPos(0.3, 0.3)
setMap(1, 2, 0)          -- zone 0 = whole continent displayed
for i = 1, 5 do
	setPos(0.3 + i * 0.02, 0.3)
	advanceTime(1.0); onUpdate(core, 1.0)
end
eq("continent view not recorded", TMP.Trail:Count(1), 0)

setMap(1, -1, 1)         -- continent -1 = cosmic / battleground
TMP.Trail:Clear()
for i = 1, 5 do
	setPos(0.4 + i * 0.02, 0.3)
	advanceTime(1.0); onUpdate(core, 1.0)
end
eq("cosmic view not recorded", TMP.Trail:Count(1), 0)

print("== browsing a foreign zone does not record onto it ==")
-- This is the subtle one: the player stays in area 1, but opens the map and
-- browses to area 99. GetPlayerMapPosition then reports a projection onto
-- area 99, which must not be recorded.
TMP.Trail:Clear()
setMap(1, 2, 1)
WorldMapFrame.shown = false
onEvent(core, "ZONE_CHANGED_NEW_AREA")
eq("player is in area 1", TMP:GetPlayerMapID(), 1)

-- User opens the map and browses elsewhere.
WorldMapFrame.shown = true
setMap(99, 2, 5)
for i = 1, 5 do
	setPos(0.6 + i * 0.02, 0.6)
	advanceTime(1.0); onUpdate(core, 1.0)
end
eq("nothing written to foreign zone 99", TMP.Trail:Count(99), 0)
eq("nothing written to own zone either", TMP.Trail:Count(1), 0)

-- Back to the player's own zone: recording resumes.
setMap(1, 2, 1)
for i = 1, 5 do
	setPos(0.2 + i * 0.03, 0.2)
	advanceTime(1.0); onUpdate(core, 1.0)
end
check("recording resumes in own zone", TMP.Trail:Count(1) > 0,
	"count=" .. TMP.Trail:Count(1))
WorldMapFrame.shown = false

print("== disabled means no recording ==")
TMP.Trail:Clear()
TMP.db.enabled = false
for i = 1, 5 do
	setPos(0.7 + i * 0.02, 0.7)
	advanceTime(1.0); onUpdate(core, 1.0)
end
eq("nothing recorded while disabled", TMP.Trail:Count(1), 0)
TMP.db.enabled = true

print("== automatic pruning during the update loop ==")
TMP.Trail:Clear()
TMP.db.fadeTime = 10
setMap(1, 2, 1)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
-- Lay a trail down over 8 seconds.
for i = 1, 8 do
	setPos(0.1 + i * 0.03, 0.1)
	advanceTime(1.0); onUpdate(core, 1.0)
end
local laid = TMP.Trail:Count(1)
check("trail laid down", laid > 0, "count=" .. laid)
-- Now stand still well past fadeTime; pruning must drain it.
for i = 1, 20 do advanceTime(1.0); onUpdate(core, 1.0) end
eq("trail fully faded out", TMP.Trail:Count(1), 0)
TMP.db.fadeTime = 600

print("== world map render layer ==")
TMP.Trail:Clear()
setMap(1, 2, 1)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
-- Use a short fade so the 6 samples below span a visible alpha range. With the
-- default 600s fade, samples taken 1s apart are all the same age to within one
-- alpha bucket, so there would be no gradient to assert on.
TMP.db.fadeTime = 60
for i = 1, 6 do
	setPos(0.2 + i * 0.03, 0.2)
	advanceTime(5.0); onUpdate(core, 5.0)
end
local recorded = TMP.Trail:Count(1)
check("have samples to draw", recorded > 0)
-- Draw them.
TMP:RefreshWorldMap()
local layer = _G["TrackMyPathWorldMapLayer"]
check("layer exists", layer ~= nil)
local visible = 0
for _, t in ipairs(layer.children) do if t.shown then visible = visible + 1 end end
eq("one texture shown per sample", visible, recorded)

-- Alpha must decrease with age: oldest dot dimmer than newest.
local first, last = layer.children[1], layer.children[recorded]
check("oldest dot is more transparent than newest",
	first.vc and last.vc and first.vc[4] < last.vc[4],
	string.format("oldest=%s newest=%s",
		tostring(first.vc and first.vc[4]), tostring(last.vc and last.vc[4])))

TMP.db.fadeTime = 600

print("== textures are pooled, not recreated ==")
local countBefore = #layer.children
TMP:RefreshWorldMap()
TMP:RefreshWorldMap()
TMP:RefreshWorldMap()
eq("no new textures created on redraw", #layer.children, countBefore)

print("== surplus textures are hidden when trail shrinks ==")
TMP.Trail:Clear()
TMP:RefreshWorldMap()
local stillVisible = 0
for _, t in ipairs(layer.children) do if t.shown then stillVisible = stillVisible + 1 end end
eq("all hidden after clear", stillVisible, 0)

print("== foreign zone displayed draws nothing ==")
TMP.Trail:Clear()
setMap(1, 2, 1)
onEvent(core, "ZONE_CHANGED_NEW_AREA")
for i = 1, 5 do
	setPos(0.3 + i * 0.03, 0.3)
	advanceTime(1.0); onUpdate(core, 1.0)
end
check("zone 1 has dots", TMP.Trail:Count(1) > 0)
setMap(77, 2, 3)   -- display an unrelated zone
TMP:RefreshWorldMap()
local leaked = 0
for _, t in ipairs(layer.children) do if t.shown then leaked = leaked + 1 end end
eq("zone 1 dots not painted onto zone 77", leaked, 0)
setMap(1, 2, 1)

print("== showWorldMap = false hides everything ==")
TMP:RefreshWorldMap()
local shownNow = 0
for _, t in ipairs(layer.children) do if t.shown then shownNow = shownNow + 1 end end
check("dots visible again", shownNow > 0, "shown=" .. shownNow)
TMP.db.showWorldMap = false
TMP:RefreshWorldMap()
shownNow = 0
for _, t in ipairs(layer.children) do if t.shown then shownNow = shownNow + 1 end end
eq("hidden when showWorldMap off", shownNow, 0)
TMP.db.showWorldMap = true

print("== minimap layer ==")
TMP.db.showMinimap = true
TMP:ApplyMinimapVisibility()
TMP:RefreshMinimap()
local mlayer = _G["TrackMyPathMinimapLayer"]
check("minimap layer exists", mlayer ~= nil)
local mvis = 0
for _, t in ipairs(mlayer.children) do if t.shown then mvis = mvis + 1 end end
check("minimap draws some dots", mvis > 0, "shown=" .. mvis)
TMP.db.showMinimap = false
TMP:ApplyMinimapVisibility()
mvis = 0
for _, t in ipairs(mlayer.children) do if t.shown then mvis = mvis + 1 end end
eq("minimap hidden when off", mvis, 0)

print("== slash commands ==")
local h = SlashCmdList["TRACKMYPATH"]
h("off");  eq("/tmp off disables", TMP.db.enabled, false)
h("on");   eq("/tmp on enables", TMP.db.enabled, true)
h("fade 300"); eq("/tmp fade 300", TMP.db.fadeTime, 300)
h("fade 5");   eq("/tmp fade rejects too small", TMP.db.fadeTime, 300)
h("fade 99999"); eq("/tmp fade rejects too large", TMP.db.fadeTime, 300)
h("fade abc");   eq("/tmp fade rejects garbage", TMP.db.fadeTime, 300)
h("rate 2");   eq("/tmp rate 2", TMP.db.sampleInterval, 2)
h("rate 0.01"); eq("/tmp rate rejects too small", TMP.db.sampleInterval, 2)
h("size 10");  eq("/tmp size 10", TMP.db.dotSize, 10)
h("size 99");  eq("/tmp size rejects too large", TMP.db.dotSize, 10)
local wmBefore = TMP.db.showWorldMap
h("worldmap"); eq("/tmp worldmap toggles", TMP.db.showWorldMap, not wmBefore)
h("worldmap")
h("minimap");  eq("/tmp minimap toggles", TMP.db.showMinimap, true)
h("minimap")
h("clear");    eq("/tmp clear empties trail", TMP.Trail:TotalCount(), 0)
h("status")
h("bogus")
h("reset");    eq("/tmp reset restores fadeTime", TMP.db.fadeTime, 600)

print("== options panel exists and toggles ==")
local opt = _G["TrackMyPathOptions"]
check("panel created", opt ~= nil)
eq("panel starts hidden", opt:IsShown(), false)
TMP:ToggleOptions(); eq("toggle shows", opt:IsShown(), true)
TMP:ToggleOptions(); eq("toggle hides", opt:IsShown(), false)

print("== WORLD_MAP_UPDATE does not error ==")
onEvent(core, "WORLD_MAP_UPDATE")
check("WORLD_MAP_UPDATE handled", true)

print("== config defaults fill in missing keys ==")
TrackMyPathDB = { fadeTime = 123 }
TMP:InitConfig()
eq("keeps existing value", TMP.db.fadeTime, 123)
eq("fills missing default", TMP.db.dotSize, 6)
check("fills nested colour table", TMP.db.color and TMP.db.color.g == 1.0)

print("== version is consistent between the TOC and Config.lua ==")
--[[ The version lives in two places: TrackMyPath.toc drives the CI release tag,
     and TMP.VERSION is what the options panel shows. They drift silently, so the
     suite compares them rather than trusting a note in the README.
]]
do
	local toc = io.open("TrackMyPath.toc", "r")
	if not toc then
		check("TrackMyPath.toc is readable", false, "could not open it")
	else
		local tocVersion
		for line in toc:lines() do
			tocVersion = line:match("^##%s*[Vv]ersion:%s*(%S+)")
			if tocVersion then break end
		end
		toc:close()
		check("TOC declares a version", tocVersion ~= nil)
		eq("TOC and TMP.VERSION agree", TMP.VERSION, tocVersion)
	end
end

print("")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
