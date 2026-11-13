#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDK=macosx
TARGET=arm64-apple-macos14.0
mkdir -p build/obj build/Cantus.app/Contents/MacOS build/Cantus.app/Contents/Resources

echo "== core library =="
for f in core/src.cpp core/eq.cpp core/fx.cpp core/dsd.cpp; do
  obj="build/obj/$(basename "${f%.cpp}").o"
  xcrun --sdk $SDK clang++ -O2 -std=c++17 -target $TARGET -c "$f" -o "$obj"
done
xcrun --sdk $SDK libtool -static -o build/libcantuscore.a build/obj/*.o

echo "== swift app =="
xcrun --sdk $SDK swiftc -O -target $TARGET -parse-as-library \
  -I include -L build -lcantuscore \
  -lc++ \
  -framework AppKit -framework AVFoundation -framework SwiftUI \
  $(find app/Cantus -name '*.swift') \
  -o build/Cantus.app/Contents/MacOS/Cantus 2>&1

cp app/Info.plist build/Cantus.app/Contents/Info.plist 2>/dev/null || true
if [ -f app/AppIcon.icns ]; then cp app/AppIcon.icns build/Cantus.app/Contents/Resources/; fi
codesign --force --deep --sign - build/Cantus.app 2>/dev/null || true
echo "== built build/Cantus.app =="
