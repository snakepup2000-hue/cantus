#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TARGET=arm64-apple-macos14.0
xcrun --sdk macosx swiftc -O -target $TARGET -parse-as-library \
  -I include -L build -lcantuscore -lc++ \
  -framework AppKit -framework AVFoundation -framework SwiftUI \
  $(find app/Cantus -name '*.swift' ! -name 'App.swift') \
  tools/AppTests.swift \
  -o build/apptests
