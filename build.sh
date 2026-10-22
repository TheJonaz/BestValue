#!/usr/bin/env bash
# Local build of the same zip the release workflow uploads. The game picks the right TOC:
# Retail reads BestValue_Mainline.toc, Forever reads BestValue_Forever.toc and Classic reads BestValue.toc.
#
#   ./build.sh            build dist/BestValue-<version>.zip
#   ./build.sh install    build, then copy the addon into every game's AddOns folder
#
# Releases are built by .github/workflows/release.yml when a tag like v1.3.0 is pushed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
WOW="$HOME/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft"
GAME_FOLDERS=(_classic_beta_ _retail_)

# Files that go into the release (logo.svg is only the source for logo.png).
FILES=(BestValue.lua BestValue.toc BestValue_Forever.toc BestValue_Mainline.toc CHANGELOG.md LICENSE logo.png)

# Same version the packager would use: the latest tag, plus commits since then.
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo dev)"
VERSION="${VERSION#v}"

rm -rf "$DIST"
stage="$DIST/BestValue"
mkdir -p "$stage"
for file in "${FILES[@]}"; do
	cp "$ROOT/$file" "$stage/"
done
sed -i "s/@project-version@/$VERSION/" "$stage"/*.toc

zip_path="$DIST/BestValue-$VERSION.zip"
(cd "$DIST" && zip -qr "$zip_path" BestValue)
echo "Built $zip_path"

if [[ ${1:-} == install ]]; then
	for folder in "${GAME_FOLDERS[@]}"; do
		dest="$WOW/$folder/Interface/AddOns"
		if [[ -d $dest ]]; then
			rm -rf "$dest/BestValue"
			cp -r "$stage" "$dest/"
			echo "  installed to $folder"
		else
			echo "  skipped install: $dest not found"
		fi
	done
fi
