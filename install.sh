#!/bin/sh
# Builds and installs Cantus into /Applications.
#
# The app keeps its library and settings in ~/Library/Application Support/Cantus,
# so where the bundle lives does not change what it plays.
set -e
cd "$(dirname "$0")"
./build_app.sh

# Quit a running copy first: replacing the bundle under a live process leaves the
# old code mapped in memory and the Dock icon stale.
osascript -e 'tell application id "local.cantus.player" to quit' >/dev/null 2>&1 || true
sleep 1

rm -rf /Applications/Cantus.app
cp -R build/Cantus.app /Applications/Cantus.app
codesign --force --deep --sign - /Applications/Cantus.app >/dev/null 2>&1 || true
codesign -v /Applications/Cantus.app
echo "installed /Applications/Cantus.app"
