#!/bin/bash
# Everything that can be checked off-hardware:
#   core C++ tests, Swift app tests, then the CLI's own smoke run.
#
# The live-Pi phases are opt-in, because they need the DAC up:
#   ./verify.sh --net          adds the app's network playback test
#
# The app's library is never touched: AppTests points CANTUS_LIBRARY_PATH at a
# temp file.
set -euo pipefail
cd "$(dirname "$0")"

NET=0
for a in "$@"; do [ "$a" = "--net" ] && NET=1; done

./build_app.sh
./build_tests.sh
./build_tools.sh

echo
echo "== core ==" 
./build/test_core

echo
echo "== app =="
if [ "$NET" = "1" ]; then
  ./build/apptests --net
else
  ./build/apptests
fi
