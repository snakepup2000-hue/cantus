# Cantus — project notes

Machine-wide rig facts (Pi, K11 R2R, no local DAC on this host) live in
`/Users/chriswilson/AGENTS.md` — read that too; Kiln only auto-loads the nearest file,
so this one overrides it.

## What it is

C++ DSP core + SwiftUI player, bundle id `local.cantus.player`. Not in `/Applications`;
it runs from `build/Cantus.app`.

## Build and run

```bash
./build_app.sh          # core .o -> build/libcantuscore.a, then swiftc -> build/Cantus.app
./build_tests.sh        # builds build/apptests (swiftc, excludes App.swift, links tools/AppTests.swift)
open build/Cantus.app
```

`build/cantus-cli` (the CLI harness) has **no build script** — it was compiled ad hoc:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun --sdk macosx clang++ -O2 -std=c++17 -fobjc-arc -target arm64-apple-macos14.0 \
  -I. tools/cantus_cli.mm -L build -lcantuscore -lc++ \
  -framework AVFoundation -framework CoreFoundation -framework Foundation \
  -o build/cantus-cli
```

Usage: `./build/cantus-cli local <file.wav> --seconds 4 --dsd 256`,
`./build/cantus-cli net <file.wav> --native --seconds 6` (sends the file's own rate).

Both scripts force `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and
`-target arm64-apple-macos14.0`. Build products go to `build/`, objects to `build/obj/`.

## Output rate

`OutputFormat.rateMode` is `.fixed` by default: everything is resampled to
`OutputFormat.rate` (384 kHz), so an 88.2 kHz track plays as 384 kHz. `.matchTrack` is
the opt-in toggle: PCM plays at the source rate when it is one of the K11's rates
(`OutputFormat.dacRates`) and the engine reopens the sink between tracks when the rate
changes (observable as `Momentary freq` in `/proc/asound/card0/stream0` on the Pi).
`ProcessingChain` copies instead of resampling when in and out rates match
(`passthrough`). DSD always runs the modulator. Match-track preserves the rate, not
bit-perfection: volume, clip guard and dither still apply.

Don't change this default again without being asked: making match-track the default
once made an 88.2 kHz track lock the DAC at 88.2 while the user expected upsampling,
which reads as a regression.

## Layout

- `core/` — `src.cpp`, `eq.cpp`, `fx.cpp`, `dsd.cpp`, headers `cantus_core.h`,
  `stage.h`, `util.h`
- `include/` — public `cantus_core.h` + `module.modulemap` (C++ exposed to Swift)
- `app/Cantus/` — `App.swift`, `ContentView.swift`, `Browser.swift`, `Settings.swift`,
  `Decoder.swift`, `DSP.swift`, `Engine.swift`, `Library.swift`, `Sinks.swift`,
  `Transport.swift`
- `tools/` — `AppTests.swift`, `cantus_cli.mm`, `probe_render.swift`,
  `make_icon.swift` + `make_icon.sh`
- `test/test_core.cpp` — C++ core tests
- `build_tools.sh` — builds `build/test_core` and `build/cantus-cli`
- `install.sh` — builds and installs to /Applications (not needed to run it)
- `verify.sh` — runs `build_app.sh`, `build_tests.sh`, `build_tools.sh`, then both
  suites; `--net` adds the live-Pi playback tests

## Traps

- The app links `-lcantuscore` from `build/`, so a clean build must run `build_app.sh`
  (or build the core first) before `build_tests.sh` or `build_tools.sh`.
- `build_tests.sh` explicitly skips `App.swift`; adding a new top-level app file that
  defines `@main` will collide if the exclusion list isn't updated.
- CommandLineTools alone cannot compile the app: the CLT SDK has no `SwiftUIMacros`
  plugin, so `@State` fails to expand. The scripts set `DEVELOPER_DIR` to Xcode.
- Output goes to the Pi over the network via PiBridge/NAA — there is no local DAC here,
  so `system_profiler SPAudioDataType` showing no FiiO is normal.
