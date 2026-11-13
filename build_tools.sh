#!/bin/bash
# Builds the two headless harnesses:
#   build/test_core  — C++ numeric self-tests for the DSP core
#   build/cantus-cli — the CLI verifier (decode, process, stream to the Pi)
#
# Run build_app.sh first: both link -lcantuscore from build/.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TARGET=arm64-apple-macos14.0

if [ ! -f build/libcantuscore.a ]; then
  echo "build/libcantuscore.a missing — run ./build_app.sh first" >&2
  exit 1
fi

echo "== core tests =="
xcrun --sdk macosx clang++ -O2 -std=c++17 -target $TARGET \
  -I. test/test_core.cpp -L build -lcantuscore -lc++ \
  -framework CoreFoundation -framework Foundation \
  -o build/test_core

echo "== cli =="
xcrun --sdk macosx clang++ -O2 -std=c++17 -fobjc-arc -target $TARGET \
  -I. tools/cantus_cli.mm -L build -lcantuscore -lc++ \
  -framework AVFoundation -framework CoreFoundation -framework Foundation \
  -o build/cantus-cli

echo "== bench =="
xcrun --sdk macosx clang++ -O2 -std=c++17 -target $TARGET \
  -I. tools/bench_dsd.cpp -L build -lcantuscore -lc++ \
  -o build/bench_dsd

echo "== built build/test_core build/cantus-cli build/bench_dsd =="
