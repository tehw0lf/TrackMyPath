#!/usr/bin/env bash
# Runs the whole suite. Execute from the addon root:  ./test/run.sh
#
# WoW 3.3.5a runs Lua 5.1, so the suite must be exercised against 5.1 - a newer
# interpreter accepts syntax the game rejects.
#
# Binary discovery matters here: a distro package installs `lua5.1`/`luac5.1`,
# while leafo/gh-actions-lua (used in CI) installs an unsuffixed `lua` on PATH.
# Hardcoding either name works in one place and breaks in the other, so both are
# probed. LUA / LUAC env vars override the search.
set -uo pipefail

cd "$(dirname "$0")/.."

find_bin() {
	# $1 = env override (may be empty), remaining args = candidate names
	local override="$1"; shift
	if [ -n "$override" ]; then
		if command -v "$override" >/dev/null 2>&1; then
			printf '%s' "$override"; return 0
		fi
		echo "error: '$override' from the environment is not executable" >&2
		return 1
	fi
	local candidate
	for candidate in "$@"; do
		if command -v "$candidate" >/dev/null 2>&1; then
			printf '%s' "$candidate"; return 0
		fi
	done
	return 1
}

LUA=$(find_bin "${LUA:-}" lua5.1 lua) || {
	echo "error: no Lua interpreter found (looked for lua5.1, lua)." >&2
	echo "       install Lua 5.1, or set LUA=/path/to/lua" >&2
	exit 1
}

# luac is optional: it only drives the syntax pass. If it is missing the suite
# still runs, because loading each file in the interpreter catches syntax errors
# too - it is just a less precise report.
LUAC=$(find_bin "${LUAC:-}" luac5.1 luac) || LUAC=""

version=$("$LUA" -v 2>&1 | head -1)
echo "interpreter: $LUA  ($version)"
case "$version" in
	*5.1*) ;;
	*) echo "warning: not Lua 5.1. WoW 3.3.5a runs 5.1, so results may differ." >&2 ;;
esac
if [ -n "$LUAC" ]; then
	echo "compiler:    $LUAC"
else
	echo "compiler:    not found - syntax pass falls back to loadfile"
fi
echo

fail=0

echo "== syntax =="
for f in *.lua; do
	if [ -n "$LUAC" ]; then
		if "$LUAC" -p "$f" 2>&1; then
			echo "  ok   $f"
		else
			echo "  FAIL $f"
			fail=1
		fi
	else
		# loadfile compiles without executing, so it reports syntax errors
		# without running any addon code.
		if "$LUA" -e "local f, err = loadfile('$f'); if not f then io.stderr:write(tostring(err) .. '\n'); os.exit(1) end" 2>&1; then
			echo "  ok   $f"
		else
			echo "  FAIL $f"
			fail=1
		fi
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
