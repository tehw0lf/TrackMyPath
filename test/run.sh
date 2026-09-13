#!/usr/bin/env bash
# Runs the whole suite. Must be executed from the addon root:  ./test/run.sh
set -uo pipefail

cd "$(dirname "$0")/.."

LUA=${LUA:-lua5.1}
LUAC=${LUAC:-luac5.1}

if ! command -v "$LUA" >/dev/null 2>&1; then
	echo "error: $LUA not found. WoW 3.3.5a runs Lua 5.1, so test against 5.1." >&2
	exit 1
fi

fail=0

echo "== syntax =="
for f in *.lua; do
	if "$LUAC" -p "$f" 2>&1; then
		echo "  ok   $f"
	else
		echo "  FAIL $f"
		fail=1
	fi
done

for t in test/test_trail.lua test/test_integration.lua test/test_minimap.lua test/test_stress.lua; do
	echo
	echo "== $t =="
	if ! "$LUA" "$t"; then
		fail=1
	fi
done

echo
if [ "$fail" -eq 0 ]; then
	echo "ALL TESTS PASSED"
else
	echo "TESTS FAILED"
fi
exit "$fail"
