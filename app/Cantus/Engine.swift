import Foundation
import AVFoundation
import Observation

// MARK: - Queue item

struct QueueItem: Identifiable, Equatable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var sourceRate: Int
    var channels: Int
    var isDSD: Bool
    var codec: String

    init(id: UUID = UUID(), url: URL, title: String, artist: String = "", album: String = "",
         duration: Double = 0, sourceRate: Int = 0, channels: Int = 1,
         isDSD: Bool = false, codec: String = "") {
        self.id = id; self.url = url; self.title = title; self.artist = artist
        self.album = album; self.duration = duration; self.sourceRate = sourceRate
        self.channels = channels; self.isDSD = isDSD; self.codec = codec
    }

    init(info: TrackInfo, url: URL) {
        self.init(url: url, title: info.title, artist: info.artist, album: info.album,
                  duration: info.duration, sourceRate: info.sampleRate,
                  channels: max(1, info.channels), isDSD: info.isDSD, codec: info.codec)
    }
}

enum PlayState { case stopped, playing, paused }

// MARK: - Thread-safe state shared with the audio thread

/// Everything the audio thread needs, guarded by one lock. The audio thread
/// takes a copy at the start of each track; commands are polled per block.
final class AudioState {
    private let lock = NSLock()

    private var _playing = false
    private var _volume: Float = 0.8
    private var _seek: Double? = nil
    private var _skip = 0
    /// Bumped by every `start()` and `stop()`. An audio thread only keeps going
    /// while its own epoch is still current, so changing track can never leave
    /// the previous thread alive writing to a second sink.
    private var _epoch = 0
    private var _activeThreads = 0
    private var _queue: [QueueItem] = []
    private var _index = 0
    private var _format = OutputFormat()
    private var _network = NetworkSink.Config()
    private var _networkTransport = false
    private var _repeatAll = false
    private var _repeatOne = false
    /// Peak and finiteness of the last block handed to the sink, so the UI and
    /// tests can see what actually left the engine rather than what went in.
    private var _outPeak: Float = 0
    private var _outFinite = true

    // commands
    func setPlaying(_ v: Bool) { lock.lock(); _playing = v; lock.unlock() }
    var playing: Bool { lock.lock(); defer { lock.unlock() }; return _playing }
    func setVolume(_ v: Float) { lock.lock(); _volume = v; lock.unlock() }
    var volume: Float { lock.lock(); defer { lock.unlock() }; return _volume }
    func requestSeek(_ t: Double) { lock.lock(); _seek = t; lock.unlock() }
    func takeSeek() -> Double? { lock.lock(); defer { lock.unlock() }; let s = _seek; _seek = nil; return s }
    func requestSkip(_ d: Int) { lock.lock(); _skip = d; lock.unlock() }
    func takeSkip() -> Int { lock.lock(); defer { lock.unlock() }; let d = _skip; _skip = 0; return d }

    /// Starts a new audio-thread generation, returning its epoch. Any thread
    /// holding an older epoch exits at its next block boundary.
    func beginEpoch() -> Int { lock.lock(); defer { lock.unlock() }; _epoch += 1; return _epoch }
    var epoch: Int { lock.lock(); defer { lock.unlock() }; return _epoch }
    func threadStarted() { lock.lock(); _activeThreads += 1; lock.unlock() }
    func threadEnded() { lock.lock(); _activeThreads -= 1; lock.unlock() }
    /// Diagnostic: audio threads currently alive. 0 or 1 in a healthy player.
    var activeThreads: Int { lock.lock(); defer { lock.unlock() }; return _activeThreads }

    // configuration
    func configure(queue: [QueueItem], index: Int, format: OutputFormat,
                   network: NetworkSink.Config, networkTransport: Bool,
                   repeatAll: Bool, repeatOne: Bool) {
        lock.lock()
        _queue = queue; _index = index; _format = format
        _network = network; _networkTransport = networkTransport
        _repeatAll = repeatAll; _repeatOne = repeatOne
        _seek = nil; _skip = 0
        lock.unlock()
    }

    var queue: [QueueItem] { lock.lock(); defer { lock.unlock() }; return _queue }
    var index: Int { lock.lock(); defer { lock.unlock() }; return _index }
    func setIndex(_ i: Int) { lock.lock(); _index = i; lock.unlock() }
    var format: OutputFormat { lock.lock(); defer { lock.unlock() }; return _format }
    var network: NetworkSink.Config { lock.lock(); defer { lock.unlock() }; return _network }
    var isNetwork: Bool { lock.lock(); defer { lock.unlock() }; return _networkTransport }
    func setTransport(network: Bool) { lock.lock(); _networkTransport = network; lock.unlock() }
    var repeatAll: Bool { lock.lock(); defer { lock.unlock() }; return _repeatAll }
    var repeatOne: Bool { lock.lock(); defer { lock.unlock() }; return _repeatOne }

    func noteOutput(peak: Float, finite: Bool) {
        lock.lock(); _outPeak = peak; _outFinite = finite; lock.unlock()
    }
    var outputPeak: Float { lock.lock(); defer { lock.unlock() }; return _outPeak }
    var outputFinite: Bool { lock.lock(); defer { lock.unlock() }; return _outFinite }
}

// MARK: - Engine

@MainActor
@Observable
final class PlayerEngine {
    // Transport
    private(set) var state: PlayState = .stopped
    private(set) var current: QueueItem?
    private(set) var elapsed: Double = 0
    private(set) var currentDuration: Double = 0
    private(set) var peakL: Double = 0
    private(set) var peakR: Double = 0
    private(set) var rmsL: Double = 0
    private(set) var rmsR: Double = 0
    private(set) var statusMessage = "Ready"
    private(set) var outputDescription = "Not started"
    private(set) var activeProcessing = "Bypass (unprocessed)"
    private(set) var clipped = false
    /// Peak of the last block actually handed to the sink, and whether it was
    /// finite. Local output is float32; a non-finite or enormous reading here
    /// means the wrong payload encoding reached the device.
    private(set) var outputPeak: Float = 0
    private(set) var outputFinite = true

    // Queue
    private(set) var queue: [QueueItem] = []
    private(set) var queueIndex = -1
    /// Turning shuffle on shuffles everything after the current track; turning
    /// it off restores the order the queue had before.
    var shuffle = false { didSet { if shuffle != oldValue { applyShuffleOrder() } } }
    var repeatMode: RepeatMode = .off { didSet { pushConfig() } }
    private var unshuffledQueue: [QueueItem]?
    private(set) var volume: Double = 0.8
    private(set) var muted = false

    enum RepeatMode: String, CaseIterable, Identifiable {
        case off, all, one
        var id: String { rawValue }
        var label: String { self == .off ? "Repeat off" : (self == .all ? "Repeat all" : "Repeat one") }
        var symbol: String { self == .one ? "repeat.1" : "repeat" }
    }

    // Output config
    var outputFormat = OutputFormat() { didSet { pushConfig() } }
    var transport: OutputTransport = .network { didSet { pushConfig() } }
    var network = NetworkSink.Config() { didSet { pushConfig() } }
    var selectedFilter: FilterOption = Catalog.filters[1] {
        didSet { dsp.filter = selectedFilter; updateProcessingText() }
    }

    nonisolated(unsafe) let dsp = ProcessingChain()
    nonisolated(unsafe) private let shared = AudioState()
    private var thread: Thread?
    private var timer: Timer?
    /// Identity of the sink currently open. If it changes while a stream is
    /// live, the running thread and the chain no longer agree, so it restarts.
    private var openStreamKey = ""
    /// Path of the loaded impulse response, kept so it can be persisted and
    /// restored with the rest of the settings.
    private(set) var irPath: String?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        dsp.filter = selectedFilter
    }

    // MARK: Volume

    func setVolume(_ v: Double) {
        volume = max(0, min(1, v))
        shared.setVolume(Float(muted ? 0 : volume))
    }
    func toggleMute() {
        muted.toggle()
        shared.setVolume(Float(muted ? 0 : volume))
    }

    // MARK: Queue

    func load(_ items: [QueueItem], startAt index: Int, autoplay: Bool) {
        guard !items.isEmpty else { return }
        queue = items
        queueIndex = max(0, min(index, items.count - 1))
        unshuffledQueue = nil
        if shuffle { applyShuffleOrder() }
        if autoplay { start() } else { statusMessage = "Loaded \(items.count) item(s)" }
    }

    func start() {
        guard queueIndex >= 0, queueIndex < queue.count else { return }
        dsp.filter = selectedFilter
        pushConfig()
        shared.setVolume(Float(muted ? 0 : volume))
        shared.setPlaying(true)
        // Retire any thread from a previous track before this one starts.
        let epoch = shared.beginEpoch()
        state = .playing
        statusMessage = "Starting…"
        let t = Thread { [weak self] in self?.audioMain(epoch: epoch) }
        t.qualityOfService = .userInitiated
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            state = .paused; shared.setPlaying(false); statusMessage = "Paused"
        case .paused:
            state = .playing; shared.setPlaying(true); statusMessage = "Playing"
        case .stopped:
            if queueIndex >= 0 { start() }
        }
    }

    func stop() {
        shared.setPlaying(false)
        // Retire the running audio thread; it stops its own sink on the way out.
        _ = shared.beginEpoch()
        thread = nil
        state = .stopped
        elapsed = 0
        peakL = 0; peakR = 0; rmsL = 0; rmsR = 0
        statusMessage = "Stopped"
    }

    /// How many audio threads are alive. Healthy playback is exactly one.
    var activeAudioThreads: Int { shared.activeThreads }

    func seek(to t: Double) { shared.requestSeek(max(0, t)) }

    func next() {
        guard !queue.isEmpty else { return }
        if queueIndex + 1 < queue.count {
            queueIndex += 1
        } else if repeatMode != .off {
            queueIndex = 0
        } else {
            stop()
            statusMessage = "End of queue"
            return
        }
        start()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if elapsed > 3 { seek(to: 0); return }
        queueIndex = max(0, queueIndex - 1)
        start()
    }

    func jump(to i: Int) {
        guard i >= 0 && i < queue.count else { return }
        queueIndex = i
        start()
    }

    func enqueue(_ items: [QueueItem]) {
        guard !items.isEmpty else { return }
        let wasEmpty = queue.isEmpty
        queue.append(contentsOf: shuffle ? items.shuffled() : items)
        if let original = unshuffledQueue { unshuffledQueue = original + items }
        if wasEmpty { queueIndex = 0; start() }
        else { pushConfig() }
    }

    func removeQueue(at offsets: IndexSet) {
        let removed = offsets.sorted(by: >).compactMap { $0 < queue.count ? queue[$0].id : nil }
        for i in offsets.sorted(by: >) where i < queue.count {
            queue.remove(at: i)
            if i < queueIndex { queueIndex -= 1 }
        }
        if let original = unshuffledQueue {
            let back = original.filter { !removed.contains($0.id) }
            unshuffledQueue = back.isEmpty ? nil : back
        }
        if queue.isEmpty { stop(); queueIndex = -1 }
        else { queueIndex = min(queueIndex, queue.count - 1); pushConfig() }
    }

    func clearQueue() {
        stop()
        queue.removeAll()
        unshuffledQueue = nil
        queueIndex = -1
        pushConfig()
    }

    // MARK: Shuffle

    /// Keeps the current track where it is and shuffles the rest, or restores
    /// the pre-shuffle order. Playback continues from the same position.
    private func applyShuffleOrder() {
        guard !queue.isEmpty else { return }
        let keepIndex = max(0, min(queueIndex, queue.count - 1))
        let keep = queue[keepIndex]

        if shuffle {
            if unshuffledQueue == nil { unshuffledQueue = queue }
            var rest = queue
            rest.remove(at: keepIndex)
            queue = [keep] + rest.shuffled()
            queueIndex = 0
        } else if let original = unshuffledQueue {
            queue = original
            unshuffledQueue = nil
            queueIndex = queue.firstIndex { $0.id == keep.id } ?? max(0, min(queueIndex, queue.count - 1))
        }

        if state == .stopped {
            pushConfig()
        } else {
            // Restart on the same track and pick the position back up, keeping
            // a paused player paused.
            let resumeAt = elapsed
            let wasPaused = state == .paused
            start()
            if resumeAt > 0.25 { seek(to: resumeAt) }
            if wasPaused {
                state = .paused
                shared.setPlaying(false)
                statusMessage = "Paused"
            }
        }
    }

    // MARK: DSP config

    func updateProcessingText() {
        if dsp.bypassDSP {
            activeProcessing = "Bypass · resampling only"
            return
        }
        var parts: [String] = []
        if dsp.eqEnabled { parts.append("EQ") }
        if dsp.convolutionEnabled { parts.append("Convolution") }
        if dsp.matrixEnabled { parts.append("Routing") }
        parts.append(dsp.filter.name)
        if dsp.limiterEnabled { parts.append(String(format: "Clip guard %.1f dB", dsp.limiterCeiling)) }
        if transport == .network && outputFormat.isDSD {
            parts.append("DSD\(outputFormat.dsdMultiple) ΣΔ")
        }
        activeProcessing = parts.joined(separator: " · ")
    }

    func applyEQ() { dsp.applyEQ(); updateProcessingText() }
    func applyMatrix() { dsp.matrixEnabled = true; updateProcessingText() }

    func setIR(path: String?) {
        if let p = path, let ir = AudioFileLoader.loadIR(path: p) {
            dsp.setConvolutionIR(ir)
            dsp.convolutionEnabled = true
            irPath = p
            statusMessage = "Loaded IR: \((p as NSString).lastPathComponent)"
        } else {
            dsp.convolutionEnabled = false
            dsp.setConvolutionIR(nil)
            irPath = nil
        }
        updateProcessingText()
    }

    // MARK: Settings persistence

    /// Copies the live output/DSP settings into a persisted state.
    func captureSettings(into base: PersistedState = PersistedState()) -> PersistedState {
        var st = base
        st.outputFormat = outputFormat
        st.transport = transport
        st.networkHost = network.host
        st.networkUser = network.user
        st.networkDevice = network.device
        st.networkKeyPath = network.sshKeyPath
        st.networkBufferMs = network.bufferMs
        st.volume = volume
        st.muted = muted
        st.filterID = selectedFilter.id
        st.eqEnabled = dsp.eqEnabled
        st.eqBands = dsp.eqBands
        st.convolutionEnabled = dsp.convolutionEnabled
        st.irPath = irPath
        st.matrixEnabled = dsp.matrixEnabled
        st.matrix = dsp.matrix
        st.limiterEnabled = dsp.limiterEnabled
        st.limiterCeiling = dsp.limiterCeiling
        st.bypass = dsp.bypassDSP
        st.dither = dsp.dither
        st.noiseShaping = dsp.noiseShaping
        st.shuffle = shuffle
        st.repeatMode = repeatMode.rawValue
        return st
    }

    /// Restores settings saved by `captureSettings`.
    func applySettings(_ st: PersistedState) {
        if let f = Catalog.filters.first(where: { $0.id == st.filterID }) {
            selectedFilter = f
        }
        dsp.eqEnabled = st.eqEnabled
        if !st.eqBands.isEmpty { dsp.eqBands = st.eqBands }
        dsp.matrixEnabled = st.matrixEnabled
        dsp.matrix = st.matrix
        dsp.limiterEnabled = st.limiterEnabled
        dsp.limiterCeiling = st.limiterCeiling
        dsp.bypassDSP = st.bypass
        if let d = st.dither { dsp.dither = d }
        if let ns = st.noiseShaping { dsp.noiseShaping = ns }
        dsp.applyEQ()

        if st.convolutionEnabled, let p = st.irPath,
           FileManager.default.fileExists(atPath: p) {
            setIR(path: p)
        } else {
            dsp.convolutionEnabled = false
            irPath = nil
        }

        transport = st.transport
        network.host = st.networkHost
        network.user = st.networkUser
        network.device = st.networkDevice
        if let k = st.networkKeyPath { network.sshKeyPath = k }
        if let b = st.networkBufferMs { network.bufferMs = b }
        outputFormat = st.outputFormat
        setVolume(st.volume)
        if (st.muted ?? false) != muted { toggleMute() }
        if let r = st.repeatMode, let mode = RepeatMode(rawValue: r) { repeatMode = mode }
        if let s = st.shuffle { shuffle = s }
        updateProcessingText()
    }

    func testConnection() {
        statusMessage = "Testing \(network.host)…"
        var cfg = network
        if cfg.user.isEmpty { cfg.user = PiRig.user }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let text = try NetworkSink.probe(cfg)
                // Name the card the Pi actually reports rather than assuming a model.
                let card = NetworkSink.firstCardName(text)
                Task { @MainActor in
                    self.statusMessage = card.map { "Pi reachable · \($0)" } ?? "Pi reachable · no sound card"
                }
            } catch {
                let msg = (error as NSError).localizedDescription
                Task { @MainActor in self.statusMessage = msg }
            }
        }
    }

    private func pushConfig() {
        // What the open sink was configured with. Encoding and rate decide both
        // the aplay flags and the rate the chain resamples to, so a change has
        // to reopen the sink: otherwise the chain runs at the new rate while
        // aplay still holds the old one, which plays noise. Network settings are
        // deliberately not part of the key — the running sink keeps using the
        // config it started with, consistently, until the next play.
        let key = "\(transport == .network ? "net" : "local")|\(outputFormat.encoding.rawValue)"
            + "|\(outputFormat.rate)|\(outputFormat.rateMode.rawValue)|\(outputFormat.dsdMultiple)"
        let formatChanged = key != openStreamKey
        let wasLive = (state == .playing || state == .paused) && thread != nil
        openStreamKey = key

        shared.configure(queue: queue, index: queueIndex, format: outputFormat,
                         network: network, networkTransport: transport == .network,
                         repeatAll: repeatMode == .all, repeatOne: repeatMode == .one)
        // DSD is only produced for the Pi. Playing locally always runs the chain
        // at the PCM rate, so selecting DSD256 and then switching to this Mac
        // cannot leave the resampler targeting a multi-megahertz word rate.
        dsp.outRate = (transport == .network && outputFormat.isDSD)
            ? outputFormat.dsdBitRate
            : outputFormat.rate
        updateProcessingText()

        if formatChanged && wasLive {
            restartStream()
        }
    }

    /// Reopens the sink with the current format, keeping the position.
    private func restartStream() {
        let resumeAt = elapsed
        let wasPaused = state == .paused
        start()                       // retires the old thread and opens a new sink
        if resumeAt > 0.25 { seek(to: resumeAt) }
        if wasPaused {
            state = .paused
            shared.setPlaying(false)
            statusMessage = "Paused"
        }
    }

    private func poll() {
        let m = dsp.meters()
        peakL = m.peakL; peakR = m.peakR; rmsL = m.rmsL; rmsR = m.rmsR
        clipped = m.peakL >= 0.999 || m.peakR >= 0.999
        outputPeak = shared.outputPeak
        outputFinite = shared.outputFinite
    }

    // MARK: Audio thread

    private nonisolated func audioMain(epoch: Int) {
        // Registered so tests can assert that only one audio thread is ever
        // alive; a stale generation exits at its next block boundary.
        shared.threadStarted()
        defer { shared.threadEnded() }

        func stillCurrent() -> Bool { shared.epoch == epoch }

        let fmt = shared.format
        let isNetwork = shared.isNetwork
        let netCfg = shared.network

        let sink: AudioSink
        if isNetwork {
            let s = NetworkSink()
            var c = netCfg
            if c.user.isEmpty { c.user = "up" }
            s.configure(c)
            sink = s
        } else {
            sink = LocalSink()
        }

        // Local output always plays PCM at the chosen rate: DSD is a wire
        // format for the Pi's aplay, and feeding a modulator's word rate to
        // CoreAudio would be several megahertz of nonsense.

        let chain = dsp
        let queue = shared.queue
        var index = shared.index
        /// Rate the sink is currently open at. A folder at one rate streams
        /// continuously; a rate change between tracks reopens the sink, which
        /// is what makes the DAC follow the track.
        var openRate = 0

        var readBuf = [Float](repeating: 0, count: 16384 * 2)

        outer: while stillCurrent() {
            guard index >= 0 && index < queue.count else { break }
            let item = queue[index]
            guard let dec = try? Decoder(url: item.url) else {
                Task { @MainActor in
                    guard self.shared.epoch == epoch else { return }
                    self.statusMessage = "Cannot open \(item.url.lastPathComponent)"
                }
                break
            }

            let trackRate = isNetwork ? fmt.transportRate(sourceRate: dec.sourceRate)
                                      : fmt.pcmRate(sourceRate: dec.sourceRate)
            if trackRate != openRate {
                do {
                    try sink.start(rate: trackRate, channels: 2, format: fmt)
                } catch {
                    let msg = (error as NSError).localizedDescription
                    Task { @MainActor in
                        guard self.shared.epoch == epoch else { return }
                        self.statusMessage = msg
                        self.state = .stopped
                        self.shared.setPlaying(false)
                    }
                    return
                }
                openRate = trackRate
            }

            chain.outRate = (isNetwork && fmt.isDSD) ? fmt.dsdBitRate : trackRate
            chain.configure(sourceRate: dec.sourceRate)
            // The chain produces samples at its own rate, which for DSD is the
            // modulator's bit rate — 32x the word rate the sink runs at. Using
            // the transport rate here made the position run 32x fast on DSD.
            let chainRate = Int(chain.outRate)

            Task { @MainActor in
                guard self.shared.epoch == epoch else { return }
                self.current = item
                self.currentDuration = item.duration
                self.elapsed = 0
                self.outputDescription = isNetwork
                    ? fmt.describe(sourceRate: dec.sourceRate)
                    : "PCM \(OutputFormat.kHzLabel(trackRate)) kHz · This Mac"
                self.statusMessage = isNetwork ? "Streaming to \(netCfg.host)" : "Local output running"
                self.updateProcessingText()
            }
            var framesOut: Int64 = 0

            while stillCurrent() {
                if let t = shared.takeSeek() {
                    dec.seek(toFrame: Int64(t * Double(dec.sourceRate)))
                    framesOut = Int64(t * Double(chainRate))
                    Task { @MainActor in
                        guard self.shared.epoch == epoch else { return }
                        self.elapsed = t
                    }
                }
                if !shared.playing {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                let n = dec.read(into: &readBuf, frames: 4096)
                if n <= 0 { break }
                let processed = chain.process(readBuf, frames: n)
                if processed.isEmpty { continue }
                let vol = shared.volume
                if isNetwork {
                    let bytes = chain.encode(processed, format: fmt, volume: vol)
                    if !bytes.isEmpty {
                        bytes.withUnsafeBytes { raw in
                            if let base = raw.baseAddress {
                                sink.write(UnsafeRawBufferPointer(start: base, count: raw.count))
                            }
                        }
                    }
                } else {
                    // CoreAudio wants float32, not the quantised wire layout.
                    let floats = chain.encodeFloat(processed, volume: vol)
                    if !floats.isEmpty {
                        floats.withUnsafeBytes { raw in
                            if let base = raw.baseAddress {
                                sink.write(UnsafeRawBufferPointer(start: base, count: raw.count))
                            }
                        }
                    }
                }
                framesOut += Int64(processed.count / 2)
                shared.noteOutput(peak: sink.lastPayloadPeak, finite: sink.lastPayloadFinite)
                let secs = Double(framesOut) / Double(chainRate)
                Task { @MainActor in
                    guard self.shared.epoch == epoch else { return }
                    self.elapsed = secs
                }
                if let st = sink.pollStatus(), !st.isEmpty {
                    let clean = st.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor in
                        guard self.shared.epoch == epoch else { return }
                        self.statusMessage = clean
                    }
                }
                if !sink.isRunning {
                    Task { @MainActor in
                        guard self.shared.epoch == epoch else { return }
                        self.statusMessage = "Output closed — stream stopped"
                        self.state = .stopped
                    }
                    break outer
                }
            }

            if !stillCurrent() { break }
            if !sink.isRunning { break }
            if shared.repeatOne { continue }
            index += 1
            if index >= queue.count {
                if shared.repeatAll { index = 0 }
                else { break }
            }
            shared.setIndex(index)
            Task { @MainActor in
                guard self.shared.epoch == epoch else { return }
                self.queueIndex = index
            }
        }

        sink.stop()
        Task { @MainActor in
            guard self.shared.epoch == epoch else { return }
            self.state = .stopped
            self.shared.setPlaying(false)
            if self.statusMessage == "Starting…" { self.statusMessage = "Finished" }
        }
    }
}

// MARK: - IR loading

enum AudioFileLoader {
    static func loadIR(path: String) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let frames = AVAudioFrameCount(min(f.length, 1 << 21))
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: frames),
              (try? f.read(into: buf)) != nil,
              let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        var ir = [Float](repeating: 0, count: n)
        for i in 0..<n { ir[i] = ch[0][i] }
        return ir
    }
}
