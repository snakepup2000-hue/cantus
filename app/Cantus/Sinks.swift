import Foundation
import AVFoundation

// MARK: - Sink protocol

protocol AudioSink: AnyObject {
    /// Opens the device / connection. Throws with a user-facing message on failure.
    func start(rate: Int, channels: Int, format: OutputFormat) throws
    /// Blocks until the transport can accept more data (this is the clock).
    func write(_ bytes: UnsafeRawBufferPointer)
    /// Non-blocking progress/diagnostic text from the receiver.
    func pollStatus() -> String?
    func stop()
    var isRunning: Bool { get }
    /// Peak magnitude and finiteness of the last payload received. Local output
    /// is float32 end to end, so these stay small and true; a sink fed quantised
    /// PCM bytes instead reports NaN and peaks around 1e38.
    var lastPayloadPeak: Float { get }
    var lastPayloadFinite: Bool { get }
}

extension AudioSink {
    var lastPayloadPeak: Float { 0 }
    var lastPayloadFinite: Bool { true }
}

// MARK: - Local output (this Mac)

/// Local playback through AVAudioEngine. The engine converts to the hardware
/// format itself, so the processing chain always writes at one rate.
final class LocalSink: AudioSink {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var pcmFormat: AVAudioFormat?
    private var queued = 0
    private var lastPeak: Float = 0
    private var lastFinite = true
    private let lock = NSLock()

    var isRunning: Bool { engine?.isRunning ?? false }
    var lastPayloadPeak: Float { lock.lock(); defer { lock.unlock() }; return lastPeak }
    var lastPayloadFinite: Bool { lock.lock(); defer { lock.unlock() }; return lastFinite }

    func start(rate: Int, channels: Int, format: OutputFormat) throws {
        stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // AVAudioEngine requires non-interleaved float; deinterleaving happens
        // when the buffer is filled below.
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(rate),
                                      channels: 2) else {
            throw NSError(domain: "Cantus", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create a \(rate) Hz output format"])
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        do { try engine.start() } catch {
            throw NSError(domain: "Cantus", code: 11,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Local output failed to start: \(error.localizedDescription)"])
        }
        player.play()
        self.engine = engine
        self.player = player
        self.pcmFormat = fmt
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let player = player, let fmt = pcmFormat, let engine = engine else { return }
        let frameBytes = MemoryLayout<Float>.size * 2
        let frames = bytes.count / frameBytes
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        var peak: Float = 0
        var finite = true
        if let dst = buf.floatChannelData {
            // interleaved source -> deinterleaved buffers AVAudioPCMBuffer expects
            let src = bytes.bindMemory(to: Float.self)
            for i in 0..<frames {
                let l = src[i * 2]
                let r = fmt.channelCount > 1 ? src[i * 2 + 1] : l
                if !l.isFinite || !r.isFinite {
                    finite = false
                } else {
                    peak = max(peak, max(abs(l), abs(r)))
                }
                dst[0][i] = l
                if fmt.channelCount > 1 { dst[1][i] = r }
            }
            lock.lock()
            self.lastPeak = peak
            self.lastFinite = finite
            lock.unlock()
        } else if let dst = buf.int32ChannelData {
            let src = bytes.bindMemory(to: Float.self)
            for i in 0..<frames {
                dst[0][i] = Int32(max(-1, min(1, src[i * 2])) * 2147483647.0)
                if fmt.channelCount > 1 {
                    dst[1][i] = Int32(max(-1, min(1, src[i * 2 + 1])) * 2147483647.0)
                }
            }
        }
        lock.lock()
        queued += frames
        lock.unlock()
        player.scheduleBuffer(buf, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.queued -= frames; self.lock.unlock()
        })
        // Keep roughly a quarter second in flight, then wait.
        while true {
            lock.lock()
            let q = queued
            lock.unlock()
            if q < rateFrames { break }
            Thread.sleep(forTimeInterval: 0.005)
            if !engine.isRunning { break }
        }
    }

    private var rateFrames: Int {
        guard let f = pcmFormat else { return 8192 }
        return Int(f.sampleRate / 4)
    }

    func pollStatus() -> String? { nil }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        pcmFormat = nil
        lock.lock(); queued = 0; lastPeak = 0; lastFinite = true; lock.unlock()
    }
}

// MARK: - Rig defaults

/// Defaults for the rig this was built against, in one place.
///
/// These make the app play with no configuration on the machine it was
/// developed on. Every one is overridable in Settings. If you are pointing
/// Cantus at your own Pi and DAC, edit these four values — nothing else in the
/// app hardcodes an address.
enum PiRig {
    static let host = "192.168.86.20"
    static let user = "up"
    static let device = "hw:CARD=R2R,DEV=0"
    static let sshKeyPath = "~/.ssh/hermes_pi"
    /// Shown in the UI where the destination is named.
    static let label = "Raspberry Pi (\(host))"
}

// MARK: - Network sink (Raspberry Pi + USB DAC)

/// Streams raw PCM (or DSD words) to `aplay` on the Pi over SSH.
///
/// Nothing needs installing on the Pi: it already runs OpenSSH and `aplay`.
/// The DAC clock paces us because `aplay` blocks when its ALSA buffer is full,
/// which is what makes this glitch-free without a separate timing protocol.
final class NetworkSink: AudioSink {
    struct Config {
        var host = PiRig.host
        var user = PiRig.user
        var device = PiRig.device
        var bufferMs = 80
        var sshKeyPath: String? = PiRig.sshKeyPath
    }

    /// ssh wants an absolute path; the settings field stores a tilde form.
    static func expandedKey(_ path: String?) -> String? {
        guard var p = path, !p.isEmpty else { return nil }
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        return p
    }

    private var process: Process?
    private var stdin: FileHandle?
    private var stderrPipe: Pipe?
    private var config = Config()
    private var collected = ""
    private let lock = NSLock()
    private(set) var lastError: String?

    var isRunning: Bool { process?.isRunning ?? false }

    func configure(_ c: Config) { config = c }

    /// A quick reachability + DAC probe, run before the stream starts.
    static func probe(_ c: Config, timeout: Int = 8) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=10"
        ]
        if let k = expandedKey(c.sshKeyPath) { args += ["-i", k, "-o", "IdentitiesOnly=yes"] }
        args += ["\(c.user)@\(c.host)",
                 "echo '===PLAYBACK==='; aplay -l 2>&1; echo '===DAC==='; cat /proc/asound/card0/stream0 2>/dev/null"]
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch {
            throw NSError(domain: "Cantus", code: 20,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Could not run ssh: \(error.localizedDescription)"])
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw NSError(domain: "Cantus", code: 21,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Pi unreachable at \(c.host): \(text.isEmpty ? "ssh exited \(p.terminationStatus)" : text)"])
        }
        if !text.lowercased().contains("r2r") {
            throw NSError(domain: "Cantus", code: 22,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Reached the Pi but no FiiO K11 R2R DAC was reported. Check USB power and cabling."])
        }
        return text
    }

    private var deviceAvailable = false

    func start(rate: Int, channels: Int, format: OutputFormat) throws {
        stop()
        let aplayFormat: String
        switch format.encoding {
        case .pcm16: aplayFormat = "S16_LE"
        case .pcm24: aplayFormat = "S24_3LE"
        case .pcm32: aplayFormat = "S32_LE"
        case .dsdNative: aplayFormat = "DSD_U32_BE"
        case .dsdDoP: aplayFormat = "S32_LE"
        }
        let bufUs = config.bufferMs * 1000
        let periodUs = max(1000, bufUs / 4)
        let remote = "aplay -D \(config.device) -t raw -f \(aplayFormat) -r \(rate) -c \(channels) " +
                     "--buffer-time=\(bufUs) --period-time=\(periodUs) -"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15", "-o", "Compression=no"
        ]
        if let k = NetworkSink.expandedKey(config.sshKeyPath) {
            args += ["-i", k, "-o", "IdentitiesOnly=yes"]
        }
        args += ["\(config.user)@\(config.host)", remote]
        p.arguments = args

        let inPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardError = errPipe
        p.standardOutput = errPipe

        do { try p.run() } catch {
            throw NSError(domain: "Cantus", code: 23,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Could not start ssh: \(error.localizedDescription)"])
        }

        // Give aplay a moment; if ssh or aplay failed immediately we want the
        // real message rather than a silent stream.
        Thread.sleep(forTimeInterval: 0.35)
        if !p.isRunning {
            let d = errPipe.fileHandleForReading.availableData
            let msg = String(data: d, encoding: .utf8) ?? ""
            throw NSError(domain: "Cantus", code: 24,
                          userInfo: [NSLocalizedDescriptionKey:
                            msg.isEmpty
                            ? "Pi receiver exited immediately. Is '\(config.device)' present?"
                            : "Pi receiver failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self?.lock.lock()
            self?.collected += s
            if (self?.collected.count ?? 0) > 4000 {
                self?.collected = String(self!.collected.suffix(2000))
            }
            self?.lock.unlock()
        }

        self.process = p
        self.stdin = inPipe.fileHandleForWriting
        self.stderrPipe = errPipe
        self.deviceAvailable = true
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let h = stdin, bytes.count > 0 else { return }
        do {
            // A throw here means the pipe closed: ssh or aplay on the Pi exited.
            try h.write(contentsOf: Data(bytes))
        } catch {
            lock.lock()
            lastError = "Network stream ended: \(error.localizedDescription)"
            lock.unlock()
        }
    }

    func pollStatus() -> String? {
        lock.lock(); let s = collected; collected = ""; lock.unlock()
        if let e = lastError { lock.lock(); lastError = nil; lock.unlock(); return e }
        return s.isEmpty ? nil : s
    }

    func stop() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdin?.close()
        stdin = nil
        if let p = process, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        process = nil
        stderrPipe = nil
        lock.lock(); collected = ""; lock.unlock()
    }
}
