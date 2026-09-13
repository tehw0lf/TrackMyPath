dofile("test/harness.lua")
dofile("Config.lua")
dofile("Trail.lua")

local TMP = TrackMyPath
TMP:InitConfig()
local Trail = TMP.Trail

local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then pass = pass + 1; print("  ok   " .. name)
	else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end
local function eq(name, got, want)
	check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end

print("== minDistance rejection ==")
Trail:Clear()
setTime(1000)
eq("first sample stored", Trail:Add(1, 0.5, 0.5, 1000), true)
-- default minDistance is 0.002; move far less than that
eq("near-identical sample rejected", Trail:Add(1, 0.5001, 0.5, 1000), false)
eq("count still 1", Trail:Count(1), 1)
eq("distant sample stored", Trail:Add(1, 0.52, 0.5, 1001), true)
eq("count now 2", Trail:Count(1), 2)

print("== zone separation ==")
Trail:Clear()
Trail:Add(1, 0.1, 0.1, 1000)
Trail:Add(2, 0.9, 0.9, 1000)
eq("zone 1 has 1", Trail:Count(1), 1)
eq("zone 2 has 1", Trail:Count(2), 1)
eq("zone 3 has 0", Trail:Count(3), 0)
eq("total is 2", Trail:TotalCount(), 2)
eq("active zones is 2", Trail:ActiveZoneCount(), 2)

print("== pruning by age ==")
Trail:Clear()
TMP.db.fadeTime = 100
-- lay down 5 samples 30s apart, far enough apart in space to not be rejected
for i = 0, 4 do
	Trail:Add(1, 0.1 + i * 0.05, 0.1, 1000 + i * 30)
end
eq("5 samples laid down", Trail:Count(1), 5)
-- now = 1120, cutoff = 1020 -> samples at t=1000 (age 120) expire; t=1030 stays
Trail:Prune(1120)
eq("oldest pruned", Trail:Count(1), 4)
-- now = 1200, cutoff = 1100 -> t=1030,1060,1090 all expire, t=1120 stays
Trail:Prune(1200)
eq("only newest survives", Trail:Count(1), 1)
-- everything expires
Trail:Prune(1400)
eq("all pruned", Trail:Count(1), 0)
eq("total zero", Trail:TotalCount(), 0)

print("== prune compacts drained bucket ==")
Trail:Clear()
TMP.db.fadeTime = 50
Trail:Add(1, 0.1, 0.1, 1000)
Trail:Prune(1100)
eq("drained to 0", Trail:Count(1), 0)
-- after compaction a fresh add must land at index 1 and be visible
eq("re-add after drain works", Trail:Add(1, 0.5, 0.5, 1100), true)
eq("count is 1 after re-add", Trail:Count(1), 1)
local seen = 0
for s in Trail:Iterate(1) do seen = seen + 1 end
eq("iterate sees re-added sample", seen, 1)

print("== maxSamples cap (FIFO head advance) ==")
Trail:Clear()
TMP.db.fadeTime = 100000
TMP.db.maxSamples = 5
for i = 1, 20 do
	Trail:Add(1, i * 0.01, 0.5, 1000 + i)
end
eq("capped at maxSamples", Trail:Count(1), 5)
-- The surviving 5 must be the NEWEST 5, i.e. i=16..20 -> x = 0.16 .. 0.20
local xs = {}
for s in Trail:Iterate(1) do xs[#xs+1] = s.x end
eq("oldest survivor is i=16", string.format("%.2f", xs[1]), "0.16")
eq("newest survivor is i=20", string.format("%.2f", xs[5]), "0.20")
eq("iterate yields exactly 5", #xs, 5)

print("== iteration order is oldest-first ==")
Trail:Clear()
TMP.db.maxSamples = 800
Trail:Add(1, 0.10, 0.5, 1000)
Trail:Add(1, 0.20, 0.5, 1001)
Trail:Add(1, 0.30, 0.5, 1002)
local ts = {}
for s in Trail:Iterate(1) do ts[#ts+1] = s.t end
check("chronological", ts[1] == 1000 and ts[2] == 1001 and ts[3] == 1002,
	table.concat({tostring(ts[1]),tostring(ts[2]),tostring(ts[3])}, ","))

print("== Latest() ==")
eq("latest is newest", Trail:Latest(1).t, 1002)
Trail:Clear()
eq("latest nil when empty", Trail:Latest(1), nil)

print("== NormalisedAge clamping ==")
TMP.db.fadeTime = 100
eq("brand new is 0", Trail:NormalisedAge({t = 1000}, 1000), 0)
eq("half way is 0.5", Trail:NormalisedAge({t = 1000}, 1050), 0.5)
eq("expired clamps to 1", Trail:NormalisedAge({t = 1000}, 9999), 1)
eq("future clamps to 0", Trail:NormalisedAge({t = 2000}, 1000), 0)

print("== Clear(mapID) is targeted ==")
Trail:Clear()
Trail:Add(1, 0.1, 0.1, 1000)
Trail:Add(2, 0.1, 0.1, 1000)
Trail:Clear(1)
eq("zone 1 cleared", Trail:Count(1), 0)
eq("zone 2 untouched", Trail:Count(2), 1)

print("")
print(string.format("RESULT: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
