#!/usr/bin/env bash
# Packages the addon into an installable ZIP under dist/.
#
# The ZIP must contain a single top-level TrackMyPath/ directory, because WoW
# loads an addon from Interface/AddOns/<Name>/ and the folder name has to match
# the .toc filename. Unzipping straight into AddOns/ therefore has to produce
# that folder - not loose files.
set -euo pipefail

cd "$(dirname "$0")"

# zip is present on GitHub's ubuntu images and on most desktops, but failing on a
# bare "command not found" three steps into a CI run is a poor diagnostic.
for dep in zip unzip; do
	if ! command -v "$dep" >/dev/null 2>&1; then
		echo "error: '$dep' is required but not installed" >&2
		exit 1
	fi
done

ADDON="TrackMyPath"
DIST="dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# `|| true` is needed because set -e would abort on grep's non-zero exit before
# the explicit check below could report a useful message.
VERSION=$(grep '^## Version:' "$ADDON.toc" | cut -d' ' -f3 || true)
if [ -z "$VERSION" ]; then
	echo "error: could not read '## Version:' from $ADDON.toc" >&2
	exit 1
fi
echo "packaging $ADDON $VERSION"

# Ship only what the client loads, plus the licence and readme. Tests, CI config
# and git metadata have no business inside an addon folder.
mkdir -p "$STAGE/$ADDON"
cp "$ADDON.toc" "$STAGE/$ADDON/"

# Every Lua file named in the TOC must exist; a typo there is silent in-game.
missing=0
while read -r f; do
	[ -z "$f" ] && continue
	if [ ! -f "$f" ]; then
		echo "error: $ADDON.toc lists '$f' but it does not exist" >&2
		missing=1
	else
		cp "$f" "$STAGE/$ADDON/"
	fi
done < <(grep -E '\.lua$|\.xml$' "$ADDON.toc" | grep -v '^#')

if [ "$missing" -ne 0 ]; then
	exit 1
fi

# Conversely, warn about Lua files that exist but are not loaded - usually a
# forgotten TOC entry, which means the file silently does nothing in-game.
for f in *.lua; do
	if ! grep -qxF "$f" "$ADDON.toc"; then
		echo "warning: $f is not listed in $ADDON.toc and will not be loaded" >&2
	fi
done

for extra in README.md LICENSE; do
	[ -f "$extra" ] && cp "$extra" "$STAGE/$ADDON/"
done

rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="$PWD/$DIST/$ADDON-$VERSION.zip"
( cd "$STAGE" && zip -qr "$ZIP" "$ADDON" )

echo "wrote $DIST/$ADDON-$VERSION.zip"
echo
echo "contents:"
unzip -l "$ZIP" | sed 's/^/  /'
