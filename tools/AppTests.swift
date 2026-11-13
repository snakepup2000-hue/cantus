// AppTests — exercises the app's own LibraryModel, PlayerEngine, ProcessingChain
// and sinks headlessly, so claims about behaviour are measured rather than assumed.
import Foundation
import AVFoundation

// MARK: - tiny assertion helpers

nonisolated(unsafe) var gFailures = 0
nonisolated(unsafe) var gChecks = 0

func check(_ ok: Bool, _ what: String) {
    gChecks += 1
    if !ok { gFailures += 1 }
    print("  \(ok ? "ok  " : "FAIL") \(what)")
}

func section(_ s: String) { print("\n§ \(s)") }

/// Waits until `cond` is true or the timeout elapses.
@MainActor
func waitUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return cond()
}

@MainActor
func drainMain(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

// MARK: - fixtures

func makeFixtures() -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cantus-apptests-\(UUID().uuidString)")
    let album = root.appendingPathComponent("Album")
    let sub = album.appendingPathComponent("Disc2")
    let bare = root.appendingPathComponent("Loose")
    for d in [root, album, sub, bare] {
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }
    writeTone(album.appendingPathComponent("01-first.wav"), rate: 44100, seconds: 3, freq: 440)
    writeTone(album.appendingPathComponent("02-second.wav"), rate: 48000, seconds: 3, freq: 550)
    writeTone(sub.appendingPathComponent("03-deep.wav"), rate: 96000, seconds: 2, freq: 330)
    writeTone(bare.appendingPathComponent("04-loose.wav"), rate: 44100, seconds: 2, freq: 660)
    return root
}

/// Writes a stereo sine WAV at `rate`, so tests can pick their own source rate.
func writeTone(_ url: URL, rate: Int, seconds: Double, freq: Double) {
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2),
          let file = try? AVAudioFile(forWriting: url, settings: fmt.settings),
          let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                     frameCapacity: AVAudioFrameCount(Double(rate) * seconds))
    else { return }
    let n = Int(Double(rate) * seconds)
    buf.frameLength = AVAudioFrameCount(n)
    if let ch = buf.floatChannelData {
        for i in 0..<n {
            let v = Float(0.3 * sin(2 * .pi * freq * Double(i) / Double(rate)))
            ch[0][i] = v
            ch[1][i] = v
        }
    }
    try? file.write(from: buf)
}

// MARK: - library tests

@MainActor
func testLibrary(root: URL) {
    section("library: add files, folders, subfolders, search, sort")

    let lib = LibraryModel()
    lib.tracks.removeAll()
    lib.folders.removeAll()
    lib.playlists.removeAll()
    lib.save()

    let loose = root.appendingPathComponent("Loose/04-loose.wav")
    lib.addFiles([loose])
    check(lib.tracks.count == 1, "addFiles adds one individual track")
    check(lib.tracks.first?.path == loose.path, "the added file path is recorded")

    // Folder add is async; wait for the scan.
    let album = root.appendingPathComponent("Album")
    lib.addFolder(album)
    _ = waitUntil(6) { lib.tracks.count >= 4 && !lib.isLoading }
    check(lib.tracks.count == 4, "addFolder finds files including the subfolder (4 total)")

    let albumFolder = lib.folders.first { $0.path == album.path }
    check(albumFolder != nil, "folder appears in the sidebar model")
    if let fid = albumFolder?.id {
        let inFolder = lib.tracks(in: fid, search: "", sort: .filename, ascending: true)
        check(inFolder.count == 3, "expanding the folder lists its 3 tracks, subfolder included")
        let names = inFolder.map { ($0.path as NSString).lastPathComponent }
        check(names == ["01-first.wav", "02-second.wav", "03-deep.wav"],
              "tracks are listed in natural filename order: \(names)")
    }

    // metadata
    let first = lib.tracks.first { $0.path.hasSuffix("01-first.wav") }
    check(first?.sampleRate == 44100, "sample rate read from the file")
    check((first?.duration ?? 0) > 2.5 && (first?.duration ?? 0) < 3.5, "duration read from the file")

    // search
    let hits = lib.tracks(in: nil, search: "second", sort: .filename, ascending: true)
    check(hits.count == 1, "search narrows to one match")
    let noHits = lib.tracks(in: nil, search: "zzzz", sort: .filename, ascending: true)
    check(noHits.isEmpty, "search with no match returns nothing")

    // sort by duration
    let byDur = lib.tracks(in: nil, search: "", sort: .duration, ascending: false)
    check(byDur.first!.duration >= byDur.last!.duration, "duration sort orders correctly")

    // playlists
    let pl = lib.createPlaylist(name: "Test list", paths: [loose.path])
    check(lib.playlistTracks(pl.id).count == 1, "playlist resolves its tracks")

    // persistence
    lib.save()
    let reloaded = LibraryModel()
    check(reloaded.tracks.count == lib.tracks.count, "library survives a reload")
    check(reloaded.folders.count == lib.folders.count, "folders survive a reload")
    check(reloaded.playlists.contains { $0.name == "Test list" }, "playlists survive a reload")
    reloaded.tracks.removeAll()
    reloaded.folders.removeAll()
    reloaded.playlists.removeAll()
    reloaded.save()
}

// MARK: - DSP tests (through the same ProcessingChain the app uses)

func testDSP() {
    section("dsp: resampling, EQ, limiter, bypass, DSD")

    let chain = ProcessingChain()

    // A 1 kHz tone at 44.1 kHz.
    let inRate = 44100
    let frames = 8192
    var input = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let v = Float(0.4 * sin(2 * .pi * 1000.0 * Double(i) / Double(inRate)))
        input[i * 2] = v
        input[i * 2 + 1] = v
    }

    chain.outRate = 384000
    chain.configure(sourceRate: inRate)
    let plain = chain.process(input, frames: frames)
    check(!plain.isEmpty, "resampler produces output")
    let expected = frames * 384000 / inRate
    check(abs(plain.count / 2 - expected) < 200,
          "output length matches the upsample ratio (\(plain.count / 2) vs ~\(expected))")

    func peak(_ b: [Float]) -> Float { b.reduce(0) { max($0, abs($1)) } }
    func rms(_ b: [Float]) -> Float {
        guard !b.isEmpty else { return 0 }
        let s = b.reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float((s / Double(b.count)).squareRoot())
    }

    // Bypass must not alter level.
    chain.bypassDSP = true
    chain.configure(sourceRate: inRate)
    let bypassed = chain.process(input, frames: frames)
    check(abs(peak(bypassed) - peak(plain)) < 0.02, "bypass keeps the same peak level")

    // EQ: a big low-shelf boost must raise the level of a low tone.
    chain.bypassDSP = false
    chain.eqEnabled = true
    chain.eqBands = EQBand.defaults
    chain.eqBands[0] = EQBand(type: 1, freq: 100, gain: 12, q: 0.7, enabled: true)
    chain.applyEQ()
    chain.configure(sourceRate: inRate)
    let lowTone = input
    let eqLow = chain.process(lowTone, frames: frames)
    check(!eqLow.isEmpty, "EQ path produces output")

    // A 60 Hz tone with a +12 dB low shelf at 100 Hz should get louder.
    var bass = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let v = Float(0.1 * sin(2 * .pi * 60.0 * Double(i) / Double(inRate)))
        bass[i * 2] = v
        bass[i * 2 + 1] = v
    }
    chain.bypassDSP = true
    chain.configure(sourceRate: inRate)
    let bassFlat = chain.process(bass, frames: frames)
    chain.bypassDSP = false
    chain.eqEnabled = true
    chain.applyEQ()
    chain.configure(sourceRate: inRate)
    let bassEq = chain.process(bass, frames: frames)
    let gainDb = 20 * log10(Double(rms(bassEq)) / Double(max(rms(bassFlat), 1e-9)))
    print("    60 Hz tone with +12 dB low shelf: \(String(format: "%.1f", gainDb)) dB")
    check(gainDb > 6.0, "EQ measurably boosts the low tone")

    // EQ off again must return to the flat level.
    chain.eqEnabled = false
    chain.applyEQ()
    chain.configure(sourceRate: inRate)
    let bassOff = chain.process(bass, frames: frames)
    let offDb = 20 * log10(Double(rms(bassOff)) / Double(max(rms(bassFlat), 1e-9)))
    check(abs(offDb) < 1.5, "disabling EQ restores the flat level")

    // Limiter: a hot signal must not exceed full scale.
    var hot = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let v = Float(2.0 * sin(2 * .pi * 200.0 * Double(i) / Double(inRate)))
        hot[i * 2] = v
        hot[i * 2 + 1] = v
    }
    chain.limiterEnabled = true
    chain.limiterCeiling = -0.3
    chain.configure(sourceRate: inRate)
    let limited = chain.process(hot, frames: frames)
    check(peak(limited) <= 0.968, "clip guard holds output below the ceiling (peak \(peak(limited)))")

    chain.limiterEnabled = false
    chain.configure(sourceRate: inRate)
    let unlimited = chain.process(hot, frames: frames)
    check(peak(unlimited) >= 0.9, "with the limiter off the hot signal stays hot")

    // DSD encode produces the expected byte counts.
    let dsdChain = ProcessingChain()
    dsdChain.outRate = 2822400
    dsdChain.configure(sourceRate: 44100)
    let hi = dsdChain.process(input, frames: frames)
    var fmt = OutputFormat()
    fmt.encoding = .dsdNative
    fmt.dsdMultiple = 64
    let bytes = dsdChain.encode(hi, format: fmt, volume: 1.0)
    check(bytes.count == (hi.count / 2 / 32) * 2 * 4,
          "native DSD packs 32 bits per word (\(bytes.count) bytes)")
    check(bytes.contains { $0 != 0 }, "DSD output is not all zeros")

    var pcm = OutputFormat()
    pcm.encoding = .pcm24
    let p24 = dsdChain.encode(hi, format: pcm, volume: 1.0)
    check(p24.count == (hi.count / 2) * 2 * 3, "24-bit PCM packing is correct")

    // The local sink takes float32. Handing CoreAudio the quantised wire layout
    // instead plays NaNs at ~1e38, which is total static.
    let floatChain = ProcessingChain()
    floatChain.outRate = 48000
    floatChain.configure(sourceRate: inRate)
    let tone = floatChain.process(input, frames: frames)
    let floats = floatChain.encodeFloat(tone, volume: 1.0)
    check(floats.count == tone.count, "local payload is float32, one value per sample")
    check(floats.allSatisfy { $0.isFinite }, "local payload is finite")
    check(floats.allSatisfy { abs($0) <= 1.0 }, "local payload stays within full scale")
    let halved = floatChain.encodeFloat(tone, volume: 0.5)
    let volRatio = peak(halved) / max(peak(floats), 1e-9)
    check(abs(volRatio - 0.5) < 0.01,
          "local payload applies output volume (ratio \(String(format: "%.3f", volRatio)))")
}

// MARK: - engine tests

@MainActor
func testEngine(root: URL) {
    section("engine: local playback, pause, seek, queue, stop")

    let engine = PlayerEngine()
    engine.transport = .local
    engine.outputFormat = OutputFormat()
    engine.outputFormat.encoding = .pcm32
    engine.outputFormat.rate = 48000

    let files = ["Album/01-first.wav", "Album/02-second.wav", "Loose/04-loose.wav"]
        .map { root.appendingPathComponent($0) }
    let items = files.map { QueueItem(url: $0, title: $0.lastPathComponent, duration: 3) }
    check(items.count == 3, "built a 3-item queue")

    engine.load(items, startAt: 0, autoplay: true)
    let began = waitUntil(6) { engine.state == .playing && engine.elapsed > 0.2 }
    check(began, "local playback starts and position advances (elapsed \(String(format: "%.2f", engine.elapsed)))")
    check(engine.current?.title == "01-first.wav", "the first queue item is current")
    // What reaches CoreAudio must be finite float32 at a sane level: the wire
    // PCM encoding would show up here as NaN and peaks around 1e38.
    check(engine.outputFinite, "the local sink receives finite samples")
    check(engine.outputPeak > 0 && engine.outputPeak <= 1.0,
          "the local sink receives in-range levels (peak \(String(format: "%.3f", engine.outputPeak)))")

    let before = engine.elapsed
    engine.togglePlayPause()
    check(engine.state == .paused, "pause changes state")
    drainMain(0.6)
    let afterPause = engine.elapsed
    check(abs(afterPause - before) < 1.2, "position barely moves while paused")

    engine.togglePlayPause()
    check(engine.state == .playing, "resume changes state back")

    engine.seek(to: 2.0)
    let seeked = waitUntil(4) { engine.elapsed > 1.8 }
    check(seeked, "seek moves the position (elapsed \(String(format: "%.2f", engine.elapsed)))")

    engine.next()
    let advanced = waitUntil(6) { engine.current?.title == "02-second.wav" }
    check(advanced, "next advances to the second track")

    engine.queueIndex >= 1 ? () : ()
    engine.setVolume(0.5)
    check(abs(engine.volume - 0.5) < 0.001, "volume can be set")
    engine.toggleMute()
    check(engine.muted, "mute toggles")
    engine.toggleMute()

    engine.stop()
    check(engine.state == .stopped, "stop halts playback")
    check(engine.elapsed == 0, "stop resets the position")

    // Enqueue while stopped keeps the item list.
    let count = engine.queue.count
    engine.enqueue([QueueItem(url: files[0], title: "extra")])
    check(engine.queue.count == count + 1, "enqueue appends to the queue")
}

// MARK: - audio-thread lifecycle

@MainActor
func testSingleAudioThread(root: URL) {
    section("engine: one audio thread per track change")

    let engine = PlayerEngine()
    engine.transport = .local
    engine.outputFormat = OutputFormat()
    engine.outputFormat.encoding = .pcm16
    engine.outputFormat.rate = 48000
    engine.repeatMode = .all

    let files = ["Album/01-first.wav", "Album/02-second.wav", "Loose/04-loose.wav"]
        .map { root.appendingPathComponent($0) }
    let items = files.map { QueueItem(url: $0, title: $0.lastPathComponent, duration: 3) }
    engine.load(items, startAt: 0, autoplay: true)
    _ = waitUntil(6) { engine.state == .playing && engine.activeAudioThreads == 1 }
    check(engine.activeAudioThreads == 1, "playing runs exactly one audio thread")

    // Three quick track changes used to pile up sink threads.
    engine.next()
    engine.next()
    engine.jump(to: 0)
    let settled = waitUntil(6) { engine.activeAudioThreads == 1 && engine.state == .playing }
    check(settled, "after rapid next/jump only one audio thread is alive (\(engine.activeAudioThreads))")
    check(engine.current?.title == "01-first.wav", "the last jump wins: \(engine.current?.title ?? "nil")")

    let advanced = waitUntil(6) { engine.elapsed > 0.2 }
    check(advanced, "playback still advances after the track changes (elapsed \(String(format: "%.2f", engine.elapsed)))")

    engine.stop()
    let stopped = waitUntil(5) { engine.activeAudioThreads == 0 }
    check(stopped, "stop retires the audio thread (\(engine.activeAudioThreads) left)")
}

// MARK: - shuffle

@MainActor
func testShuffle(root: URL) {
    section("engine: shuffle reorders the queue and restores it")

    let engine = PlayerEngine()
    let files = ["Album/01-first.wav", "Album/02-second.wav", "Album/Disc2/03-deep.wav",
                 "Loose/04-loose.wav", "Album/01-first.wav"]
        .map { root.appendingPathComponent($0) }
    let items = files.enumerated().map { i, u in
        QueueItem(url: u, title: "t\(i)", duration: 2)
    }
    let originalOrder = items.map(\.id)
    engine.load(items, startAt: 2, autoplay: false)
    check(engine.queueIndex == 2 && engine.queue[2].id == originalOrder[2],
          "the queue starts in library order at the chosen track")

    engine.shuffle = true
    check(engine.queue.count == items.count, "shuffle keeps every track")
    check(engine.queueIndex == 0 && engine.queue[0].id == originalOrder[2],
          "the current track stays current and leads the queue")
    check(Set(engine.queue.map(\.id)) == Set(originalOrder), "shuffle is a permutation, nothing lost")

    engine.shuffle = false
    check(engine.queue.map(\.id) == originalOrder, "turning shuffle off restores the original order")
    check(engine.queue[engine.queueIndex].id == originalOrder[2],
          "the same track is still selected after unshuffling")

    // Appending while shuffled still reaches the queue.
    engine.shuffle = true
    let extra = QueueItem(url: files[0], title: "extra", duration: 2)
    engine.enqueue([extra])
    check(engine.queue.contains { $0.id == extra.id }, "enqueue works while shuffled")
    engine.shuffle = false
    check(engine.queue.last?.id == extra.id, "the restored order ends with the appended track")
}

// MARK: - settings persistence

@MainActor
func testSettingsPersist(root: URL) {
    section("settings: output and DSP survive a relaunch")

    let lib = LibraryModel()
    let engine = PlayerEngine()
    engine.outputFormat.encoding = .pcm24
    engine.outputFormat.rate = 96000
    engine.transport = .local
    engine.setVolume(0.42)
    engine.dsp.eqEnabled = true
    engine.dsp.eqBands[0] = EQBand(type: 1, freq: 90, gain: 4.5, q: 0.8, enabled: true)
    engine.dsp.applyEQ()
    engine.dsp.bypassDSP = false
    engine.dsp.limiterCeiling = -1.5
    engine.repeatMode = .all
    engine.dsp.eqBands[1] = EQBand(type: 0, freq: 250, gain: -2, q: 1.4, enabled: true)
    engine.dsp.applyEQ()
    lib.save(engine: engine)

    // A content-only save must not wipe the settings it just wrote.
    lib.save()

    let reloaded = LibraryModel()
    let restored = PlayerEngine()
    reloaded.restoreSettings(into: restored)

    check(restored.outputFormat.encoding == .pcm24, "output encoding is restored")
    check(restored.outputFormat.rate == 96000, "output sample rate is restored")
    check(restored.transport == .local, "transport is restored")
    check(abs(restored.volume - 0.42) < 0.01, "volume is restored (\(restored.volume))")
    check(restored.repeatMode == .all, "repeat mode is restored")
    check(abs(restored.dsp.limiterCeiling - (-1.5)) < 0.01, "limiter ceiling is restored")
    check(restored.dsp.eqEnabled, "EQ stays enabled")
    check(abs(restored.dsp.eqBands[0].gain - 4.5) < 0.01, "EQ band gain is restored")
    check(abs(restored.dsp.eqBands[1].q - 1.4) < 0.01, "second EQ band is restored")

    // A library.json written before these fields existed must still decode.
    let legacyURL = root.appendingPathComponent("legacy-library.json")
    let legacy = """
    {"tracks":[],"folders":[],"playlists":[],"outputFormat":{"encoding":"pcm16","rate":44100,"dsdMultiple":64},
     "transport":"local","networkHost":"h","networkUser":"u","networkDevice":"d","volume":0.5,
     "filterID":1,"eqEnabled":false,"eqBands":[],"convolutionEnabled":false,"matrixEnabled":false,
     "matrix":{"gLL":1,"gLR":0,"gRL":0,"gRR":1},"limiterEnabled":true,"limiterCeiling":-0.3,
     "bypass":false,"presets":[]}
    """
    try? legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
    let saved = ProcessInfo.processInfo.environment["CANTUS_LIBRARY_PATH"]
    setenv("CANTUS_LIBRARY_PATH", legacyURL.path, 1)
    let legacyLib = LibraryModel()
    let legacyEngine = PlayerEngine()
    legacyLib.restoreSettings(into: legacyEngine)
    check(legacyEngine.outputFormat.encoding == .pcm16 && abs(legacyEngine.volume - 0.5) < 0.01,
          "an older library.json still loads its settings")
    if let s = saved { setenv("CANTUS_LIBRARY_PATH", s, 1) } else { unsetenv("CANTUS_LIBRARY_PATH") }

    // Leave the temp library clean for the next run.
    let cleanup = LibraryModel()
    cleanup.tracks.removeAll()
    cleanup.folders.removeAll()
    cleanup.playlists.removeAll()
    cleanup.save()
}

@MainActor
func testErrors() {
    section("errors: missing file and unreachable Pi")

    let engine = PlayerEngine()
    engine.transport = .local
    let missing = QueueItem(url: URL(fileURLWithPath: "/nonexistent/nope.wav"), title: "nope")
    engine.load([missing], startAt: 0, autoplay: true)
    let reported = waitUntil(5) {
        engine.statusMessage.lowercased().contains("cannot open")
            || engine.statusMessage.lowercased().contains("could not")
            || engine.state == .stopped
    }
    check(reported, "a missing file surfaces a status message: \"\(engine.statusMessage)\"")
    engine.stop()

    // Unreachable host: the probe must fail with a useful message.
    var cfg = NetworkSink.Config()
    cfg.host = "192.0.2.123"          // TEST-NET-1, guaranteed unroutable
    cfg.user = PiRig.user
    cfg.sshKeyPath = nil
    var threw = false
    var msg = ""
    do { _ = try NetworkSink.probe(cfg, timeout: 3) }
    catch {
        threw = true
        msg = (error as NSError).localizedDescription
    }
    check(threw, "unreachable Pi raises an error")
    check(msg.lowercased().contains("unreachable") || msg.lowercased().contains("ssh")
          || msg.lowercased().contains("timeout"),
          "the unreachable-Pi error is descriptive: \"\(msg)\"")
}

/// The live tests need a real Pi. They are skipped, not failed, when none is
/// configured: the suite must pass on a machine with no DAC attached.
func piTarget() -> NetworkSink.Config? {
    guard let host = ProcessInfo.processInfo.environment["PIBRIDGE_HOST"], !host.isEmpty else {
        return nil
    }
    var cfg = NetworkSink.Config()
    cfg.host = host
    cfg.user = PiRig.user
    cfg.device = PiRig.device
    cfg.sshKeyPath = PiRig.sshKeyPath
    return cfg
}

@MainActor
func testPiProbe() {
    section("network: live Pi + DAC probe")
    guard let cfg = piTarget() else {
        print("  skip no Pi configured; set PIBRIDGE_HOST to test against one")
        return
    }
    do {
        let text = try NetworkSink.probe(cfg, timeout: 8)
        let card = NetworkSink.firstCardName(text)
        check(card != nil, "Pi reachable and a sound card is reported (\(card ?? "none"))")
        check(text.contains("Playback:"), "the card reports a playback stream")
    } catch {
        check(false, "Pi probe failed: \((error as NSError).localizedDescription)")
    }
}

// MARK: - network playback through the engine

@MainActor
func testEngineNetwork(root: URL, seconds: Double) {
    section("engine: network playback to the Pi via the app's own sink")

    guard let cfg = piTarget() else {
        print("  skip no Pi configured; set PIBRIDGE_HOST to test against one")
        return
    }
    let engine = PlayerEngine()
    engine.transport = .network
    engine.network = cfg
    engine.outputFormat = OutputFormat()
    engine.outputFormat.encoding = .pcm32
    engine.outputFormat.rate = 384000
    engine.outputFormat.rateMode = .fixed      // the upsample-everything path

    let item = QueueItem(url: root.appendingPathComponent("Album/01-first.wav"),
                         title: "network-test", duration: 3)
    engine.load([item], startAt: 0, autoplay: true)

    let started = waitUntil(10) {
        engine.state == .playing && engine.elapsed > 0.2
    }
    check(started, "engine connected over the network and position advances (elapsed \(String(format: "%.2f", engine.elapsed)))")
    check(engine.outputDescription.contains("PCM"), "output description reports the wire format: \(engine.outputDescription)")
    let bad = engine.statusMessage.lowercased().contains("fail")
        || engine.statusMessage.lowercased().contains("unreachable")
        || engine.statusMessage.lowercased().contains("denied")
    check(!bad, "no connection errors reported: \(engine.statusMessage)")

    // Hold the stream so the DAC side can be observed externally.
    drainMain(seconds)
    engine.stop()

    // Native rate through the same sink: an 88.2 kHz file must reach the Pi at
    // 88.2 kHz. `aplay -r` is the only thing that sets it.
    let nativeURL = root.appendingPathComponent("native-88200.wav")
    writeTone(nativeURL, rate: 88200, seconds: 4, freq: 700)
    let native = PlayerEngine()
    native.transport = .network
    native.network = engine.network
    native.outputFormat = OutputFormat()
    native.outputFormat.rateMode = .matchTrack    // follow the file's own rate
    let nativeItem = QueueItem(url: nativeURL, title: "native-88k", duration: 4)
    native.load([nativeItem], startAt: 0, autoplay: true)

    let nativeStarted = waitUntil(10) {
        native.state == .playing && native.elapsed > 0.2
    }
    check(nativeStarted, "engine plays an 88.2 kHz track in match-track mode")
    check(native.outputDescription.contains("88.2"),
          "output description reports the track's own rate: \(native.outputDescription)")
    check(native.statusMessage.lowercased().contains("fail") == false,
          "no stream error at the native rate: \(native.statusMessage)")
    drainMain(seconds)
    native.stop()

    // The restructured sink must still carry native DSD: DSD64 words at 88.2 kHz.
    let dsdEngine = PlayerEngine()
    dsdEngine.transport = .network
    dsdEngine.network = engine.network
    dsdEngine.outputFormat = OutputFormat()
    dsdEngine.outputFormat.encoding = .dsdNative
    dsdEngine.outputFormat.dsdMultiple = 64
    dsdEngine.load([QueueItem(url: root.appendingPathComponent("Album/01-first.wav"),
                              title: "native-dsd64", duration: 3)],
                   startAt: 0, autoplay: true)
    let dsdStarted = waitUntil(10) { dsdEngine.state == .playing && dsdEngine.elapsed > 0.2 }
    check(dsdStarted, "DSD64 still streams through the restructured sink")
    check(dsdEngine.outputDescription.contains("DSD64"),
          "DSD output description is unchanged: \(dsdEngine.outputDescription)")
    check(dsdEngine.outputFinite, "DSD payload is finite")
    drainMain(seconds / 2)
    dsdEngine.stop()

    // Switching output format mid-stream must reopen the sink. Otherwise the
    // running thread keeps the old format while the chain moves to the new
    // rate, and a PCM-rate stream ends up in a DSD device: noise until the next
    // track. A local sink cannot catch this — it ignores the DSD rate — so this
    // has to run against the Pi.
    let sw = PlayerEngine()
    sw.transport = .network
    sw.network = engine.network
    sw.outputFormat = OutputFormat()
    sw.outputFormat.encoding = .pcm32
    sw.outputFormat.rate = 48000
    sw.load([QueueItem(url: root.appendingPathComponent("Album/01-first.wav"),
                       title: "switch", duration: 3)], startAt: 0, autoplay: true)
    let pcmUp = waitUntil(10) { sw.state == .playing && sw.elapsed > 0.2 }
    check(pcmUp, "a PCM stream is running before the format change")
    let beforeChange = sw.elapsed

    sw.outputFormat.encoding = .dsdNative
    sw.outputFormat.dsdMultiple = 256      // the rate the UI defaults to

    let reopened = waitUntil(12) { sw.outputDescription.contains("DSD256") }
    check(reopened,
          "changing to DSD mid-stream reopens the sink: \(sw.outputDescription)")
    check(sw.state == .playing, "playback continues after the format change")
    // The seek that restores the position is applied by the new audio thread on
    // its first block, so it lands a moment after the sink reopens.
    let restored = waitUntil(6) { sw.elapsed >= beforeChange - 0.5 }
    check(restored,
          "the position is preserved across the change (\(String(format: "%.2f", sw.elapsed)) vs \(String(format: "%.2f", beforeChange)))")
    check(sw.activeAudioThreads == 1,
          "exactly one audio thread survives the change (\(sw.activeAudioThreads))")

    let advancing = waitUntil(6) { sw.elapsed > beforeChange }
    check(advancing, "the restarted stream keeps advancing (\(sw.elapsed))")
    check(sw.outputFinite, "the restarted stream produces finite samples")
    // The DSD modulator runs at 32x the word rate the sink uses, so accounting
    // the position in transport frames made it run 32x fast.
    check(sw.elapsed < 8.0,
          "the position tracks real time on DSD (elapsed \(String(format: "%.2f", sw.elapsed)) after ~3 s)")
    drainMain(seconds / 2)
    sw.stop()
}

// MARK: - native rate (follow each track)

@MainActor
func testNativeRate() {
    section("rate: follow each track, no resampler at 1:1")

    var fmt = OutputFormat()
    check(fmt.rateMode == .fixed, "fixed-rate upsampling is the default output mode")
    check(fmt.transportRate(sourceRate: 88200) == 384000,
          "by default an 88.2 kHz track is upsampled to the chosen rate")
    fmt.rateMode = .matchTrack
    check(fmt.transportRate(sourceRate: 88200) == 88200,
          "match-track sends an 88.2 kHz track at 88.2 kHz when selected")
    check(fmt.transportRate(sourceRate: 88200) == 88200,
          "an 88.2 kHz track is sent at 88.2 kHz, not the fixed rate")
    check(fmt.transportRate(sourceRate: 44100) == 44100, "44.1 kHz stays 44.1 kHz")
    check(fmt.transportRate(sourceRate: 192000) == 192000, "192 kHz stays 192 kHz")
    check(fmt.transportRate(sourceRate: 45000) == 384000,
          "a rate the K11 does not list falls back to the fixed rate")

    fmt.rateMode = .fixed
    fmt.rate = 384000
    check(fmt.transportRate(sourceRate: 88200) == 384000,
          "fixed mode upsamples everything to the chosen rate")

    fmt.rateMode = .matchTrack
    fmt.encoding = .dsdNative
    fmt.dsdMultiple = 256
    check(fmt.transportRate(sourceRate: 44100) == 352800,
          "DSD256 still runs the modulator (transport \(fmt.transportRate(sourceRate: 44100) / 1000) kHz words)")
    fmt.encoding = .pcm32

    // The chain must copy rather than resample when the rates match: a ratio-1
    // sinc still low-passes at 0.46·fs and delays by half its kernel.
    let rate = 88200
    let frames = 4096
    var input = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let v = Float(0.5 * sin(2 * .pi * 1000.0 * Double(i) / Double(rate)))
        input[i * 2] = v
        input[i * 2 + 1] = v
    }

    let chain = ProcessingChain()
    chain.bypassDSP = true
    chain.outRate = rate
    chain.configure(sourceRate: rate)
    check(chain.passthrough, "the chain reports passthrough at matching rates")
    let out = chain.process(input, frames: frames)
    check(out.count == input.count, "passthrough keeps the frame count (\(out.count / 2))")
    check(out == input, "passthrough is bit-identical to the input")

    chain.outRate = 176400
    chain.configure(sourceRate: rate)
    check(!chain.passthrough, "a rate change still engages the resampler")
    // The converter holds back half its kernel, so one block comes up short by
    // the filter latency; the two-block total is the ratio.
    let upA = chain.process(input, frames: frames)
    let upB = chain.process(input, frames: frames)
    let upFrames = (upA.count + upB.count) / 2
    check(abs(upFrames - frames * 4) < 300,
          "88.2 -> 176.4 kHz doubles the frame count (\(upFrames) vs ~\(frames * 4))")

    // Match-track mode must survive a relaunch like every other setting.
    let engine = PlayerEngine()
    engine.outputFormat.rateMode = .fixed
    engine.outputFormat.rate = 96000
    engine.outputFormat.rateMode = .matchTrack
    let st = engine.captureSettings()
    check(st.outputFormat.rateMode == .matchTrack, "the rate mode is captured for persistence")
}

// MARK: - main

@main
struct AppTestRunner {
    @MainActor
    static func main() {
        // Hermetic: the suite must never read or rewrite the real library.
        let libPath = NSTemporaryDirectory() + "cantus-apptests-library-\(UUID().uuidString).json"
        setenv("CANTUS_LIBRARY_PATH", libPath, 1)

        DiagnosticsLine("Cantus application self-tests\n")
        let root = makeFixtures()
        testLibrary(root: root)
        testDSP()
        testNativeRate()
        testEngine(root: root)
        testSingleAudioThread(root: root)
        testShuffle(root: root)
        testSettingsPersist(root: root)
        testErrors()
        testPiProbe()
        if ProcessInfo.processInfo.arguments.contains("--net") {
            testEngineNetwork(root: root, seconds: 12)
        }

        print("\n\(gChecks - gFailures)/\(gChecks) checks passed, \(gFailures) failure(s)")
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(atPath: libPath)
        exit(gFailures == 0 ? 0 : 1)
    }
}

func DiagnosticsLine(_ s: String) { print(s, terminator: "") }
