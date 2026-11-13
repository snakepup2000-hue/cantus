# Cantus

A local music player for macOS with its own DSP core: arbitrary-ratio resampling
with selectable filters, parametric EQ, convolution, a peak clip guard, and a
1-bit sigma-delta modulator for native DSD output.

It plays to this Mac, or — the reason it exists — streams to a Raspberry Pi over
SSH, where `aplay` feeds a USB DAC. The Mac does the DSP; the Pi just clocks.

![icon](app/AppIcon.icns)

## What it is not

Not an HQPlayer clone and not trying to be. There is no network protocol of its
own (it speaks SSH and feeds `aplay`), no claim of bit-perfect local output, and
no attempt to match HQPlayer's filter catalogue — the filters here are
windowed-sinc designs of my own, and the note on each entry in `Catalog.filters`
says what it is.

## Requirements

- macOS 14 or later, Apple silicon (the build targets `arm64-apple-macos14.0`)
- Xcode's toolchain, **not** just CommandLineTools: the CLT SDK has no
  `SwiftUIMacros` plugin, so `@State` cannot expand and the build stops with
  "plugin for module 'SwiftUIMacros' not found". Both scripts point
  `DEVELOPER_DIR` at Xcode for this reason.
- For network playback: a Raspberry Pi reachable over SSH with a USB DAC and
  stock `aplay`. Nothing is installed on the Pi.

Developed against a Raspberry Pi 4B running the Signalyst NAA image (no sudo,
pubkey-only SSH) and a FiiO K11 R2R. The K11 advertises PCM 44.1–384 kHz
(S16/S24/S32) and native DSD as `DSD_U32_BE` up to 384 kHz *word* rate — DSD256
is 352.8 kHz words. Any ALSA-visible DAC that `aplay` can open should work; see
[Setting up your Pi](#setting-up-your-pi). A DAC with a narrower rate range
refuses the rates it does not support, which surfaces as a stream error rather
than silent conversion.

## Build and run

```bash
./build_app.sh        # core objects -> build/libcantuscore.a, then swiftc -> build/Cantus.app
open build/Cantus.app
./install.sh          # or build and copy it to /Applications
```

The bundle runs from wherever it is. Settings and the library live in
`~/Library/Application Support/Cantus`, so building another copy does not disturb
what the installed one plays.

Both build scripts pin `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
and `-target arm64-apple-macos14.0`; there is no CMake or Xcode project, just
`swiftc` invocations. Products land in `build/`.

To run everything that can be checked without the DAC:

```bash
./verify.sh           # core C++ tests, then the Swift app tests
./verify.sh --net     # adds live playback to the Pi (needs the DAC up)
```

`verify.sh` builds all three binaries and runs both suites. It never touches your
library — the app tests point `CANTUS_LIBRARY_PATH` at a temp file.

## The pieces

- `core/` — the DSP, portable C++17 with no Apple dependencies:
  `src.cpp` (resampler: linear, minimum-phase and closed-form kernels, with a
  halfband cascade for large ratios), `eq.cpp` (parametric biquad EQ),
  `fx.cpp` (overlap-save convolution, clip guard, PCM quantisation with dither,
  meters), `dsd.cpp` (sigma-delta modulator, DSD word and DoP packing, and
  halfband decimation for DSD input)
- `include/` — the public C interface plus a modulemap, which is how Swift sees
  the core
- `app/Cantus/` — the SwiftUI player. `Engine.swift` owns the audio thread and
  the queue; `Sinks.swift` has the two outputs (CoreAudio, and SSH to `aplay`);
  `DSP.swift` is the chain the UI configures
- `tools/` — `AppTests.swift` (headless tests against the real `ProcessingChain`
  and `PlayerEngine`), `cantus_cli.mm` (a CLI verifier), `make_icon.*`
- `test/test_core.cpp` — numeric tests for the core on its own

## Output rate

PCM plays at each track's own rate by default. If the rate is one the DAC lists,
nothing is resampled: `ProcessingChain` copies instead (`passthrough`), because a
ratio-1 sinc still low-passes at 0.46·fs and delays by half its kernel. A queue
that changes rate reopens the sink between tracks, so the DAC re-clocks at the
boundary; a same-rate album streams continuously.

Switch to a fixed rate in Settings if you would rather resample everything.

DSD always runs through the modulator, so it is resampled from the source rate by
definition. Match-track preserves the *rate*, not bit-perfection — volume, the
clip guard and dither still apply.

## Setting up your Pi

Cantus assumes nothing about your network. The defaults are a Raspberry Pi
answering to its mDNS name, the standard `pi` account, `~/.ssh/id_ed25519`, and
ALSA device `hw:0,0`. Here is what actually has to be true for that to work.

**1. The Pi answers on the network, and you can log in.**

```bash
ssh pi@raspberrypi.local
```

If the name does not resolve, use the address instead: `ping raspberrypi.local`,
or find it in your router's client list. Raspberry Pi OS ships mDNS via Avahi;
minimal images (Signalyst's NAA, for instance) may not advertise a name at all,
in which case the address is the only way in.

**2. Key-based, non-interactive SSH.** Cantus opens `ssh` in batch mode, so a
password prompt is a hang.

```bash
ssh-keygen -t ed25519 -C cantus          # if you do not already have a key
ssh-copy-id pi@raspberrypi.local
ssh -o BatchMode=yes pi@raspberrypi.local true && echo works
```

That last command is exactly what the app's `Test connection` requires to
succeed. If it prompts, the key is not in `~/.ssh/authorized_keys`.

**3. `aplay` is present and the DAC is visible.**

```bash
ssh pi@raspberrypi.local 'aplay -l; cat /proc/asound/cards'
```

You want a `card N: ... [Your DAC]`. The device to put in Settings is
`hw:N,0` — card number from that output, device 0. `hw:0,0` is the usual answer
for a single USB DAC. The app needs the `hw:` form: it hands the bytes to
`aplay` untouched, so there is no conversion layer to fall back on.

**4. Tell Cantus about it.** Settings → Output → Raspberry Pi: host, user, ALSA
device, SSH key. Then `Test connection`, which reports whether the Pi answered
and which sound card it found.

For CI or a scripted run, the same four values can come from the environment
instead — `PIBRIDGE_HOST`, `PIBRIDGE_USER`, `PIBRIDGE_DEVICE`, `PIBRIDGE_KEY` —
which is also how the live tests are pointed at a rig:

```bash
PIBRIDGE_HOST=192.168.1.50 PIBRIDGE_USER=pi ./verify.sh --net
```

Without `PIBRIDGE_HOST` the live tests skip rather than fail, so `./verify.sh`
works on a machine with no Pi attached.

## Known limits

- Output is stereo only; the core is interleaved stereo throughout.
- Network playback has no drift correction. The DAC clock paces the stream
  because `aplay` blocks when its buffer is full, which is enough over a LAN and
  is why there is no separate timing protocol.
- The ALSA buffer setting is a plain `aplay` buffer time; the K11 will not hold
  the very small ones. 80 ms is the default and is conservative.
- The clip guard has no look-ahead. Its attack is instantaneous, so nothing
  passes the ceiling, but on a hard transient it reduces gain *at* the peak
  rather than before it. It protects the DAC from clipping; it is not a
  mastering-grade limiter and should not be used as one.
- Local output goes through AVAudioEngine, which does its own conversion to the
  hardware format — "this Mac" is not a bit-perfect path.

## Licence

GPL-3.0. See `LICENSE`.

`AGENTS.md` is a note to coding agents working in this repo, not user
documentation.
