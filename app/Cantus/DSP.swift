import Foundation
import CantusCore

// MARK: - Output format description

enum OutputTransport: String, Codable, CaseIterable, Identifiable {
    case local
    case network
    var id: String { rawValue }
    var label: String { self == .local ? "This Mac" : PiRig.label }
}

enum OutputEncoding: String, Codable, CaseIterable, Identifiable {
    case pcm16, pcm24, pcm32, dsdDoP, dsdNative
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pcm16: return "PCM 16-bit"
        case .pcm24: return "PCM 24-bit"
        case .pcm32: return "PCM 32-bit"
        case .dsdDoP: return "DSD over PCM (DoP)"
        case .dsdNative: return "DSD native (DSD_U32_BE)"
        }
    }
    var isDSD: Bool { self == .dsdDoP || self == .dsdNative }
    var bits: Int32 { self == .pcm16 ? 16 : (self == .pcm24 ? 24 : 32) }
}

struct OutputFormat: Codable, Equatable {
    /// Whether PCM output follows each track's own rate or one fixed rate.
    enum RateMode: String, Codable, CaseIterable, Identifiable {
        case matchTrack, fixed
        var id: String { rawValue }
        var label: String {
            self == .matchTrack ? "Match each track (no resampling)" : "Fixed rate"
        }
    }

    var encoding: OutputEncoding = .pcm32
    var rate: Int = 384000          // PCM sample rate, or DSD *word* rate for native DSD
    var dsdMultiple: Int = 256      // 64 / 128 / 256 for DoP and native modes
    var rateMode: RateMode = .fixed

    /// Rates the K11 R2R advertises in `stream0`. A track at any other rate —
    /// and DSD output, which always runs through a modulator — uses `rate`.
    static let dacRates = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]

    // Decoded field by field so a library.json written before `rateMode`
    // existed still loads: a missing non-optional key would throw and the app
    // would start with an empty library.
    private enum CodingKeys: String, CodingKey {
        case encoding, rate, dsdMultiple, rateMode
    }

    init() {}

    init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        encoding = try c.decodeIfPresent(OutputEncoding.self, forKey: .encoding) ?? .pcm32
        rate = try c.decodeIfPresent(Int.self, forKey: .rate) ?? 384000
        dsdMultiple = try c.decodeIfPresent(Int.self, forKey: .dsdMultiple) ?? 256
        rateMode = try c.decodeIfPresent(RateMode.self, forKey: .rateMode) ?? .fixed
    }

    var isDSD: Bool { encoding.isDSD }
    /// Bit rate the modulators run at.
    var dsdBitRate: Int { 2822400 * dsdMultiple / 64 }
    /// True when PCM playback is meant to keep the source rate untouched.
    var followsSource: Bool { rateMode == .matchTrack && !encoding.isDSD }

    /// PCM rate for a track decoded at `sourceRate`.
    func pcmRate(sourceRate: Int) -> Int {
        if rateMode == .matchTrack, OutputFormat.dacRates.contains(sourceRate) {
            return sourceRate
        }
        return rate
    }

    /// Rate the transport must produce samples at for a track decoded at
    /// `sourceRate`.
    func transportRate(sourceRate: Int) -> Int {
        switch encoding {
        case .dsdNative: return dsdBitRate / 32    // words per second == frames
        case .dsdDoP: return dsdBitRate / 16
        default: return pcmRate(sourceRate: sourceRate)
        }
    }

    /// "88.2" for 88200, "384" for 384000 — the odd 44.1-family rates must not
    /// be truncated to "88 kHz", which is a different rate the DAC never runs.
    static func kHzLabel(_ rate: Int) -> String {
        let whole = rate / 1000, tenths = (rate % 1000) / 100
        return tenths == 0 ? "\(whole)" : "\(whole).\(tenths)"
    }

    func describe(sourceRate: Int) -> String {
        let r = transportRate(sourceRate: sourceRate)
        switch encoding {
        case .dsdNative: return "DSD\(dsdMultiple) native \(r) Hz words"
        case .dsdDoP: return "DoP DSD\(dsdMultiple) @ \(r) Hz"
        default:
            let native = followsSource && r == sourceRate ? " · native" : ""
            return "\(encoding.label) \(OutputFormat.kHzLabel(r)) kHz\(native)"
        }
    }
}

// MARK: - Filter / modulator catalogue

struct FilterOption: Identifiable, Hashable {
    let id: Int
    let name: String
    let taps: Int32
    let family: Int32     // 0 linear, 1 minimum, 2 closed-form
    let window: Int32
    let rolloff: Double
    let note: String
}

enum Catalog {
    static let windows: [(String, Int32)] = [
        ("Gaussian", Int32(CWIN_GAUSS)), ("Kaiser", Int32(CWIN_KAISER)),
        ("Blackman-Harris", Int32(CWIN_BLACKMAN_HARRIS)), ("Lanczos", Int32(CWIN_LANCZOS)),
        ("Rectangular", Int32(CWIN_RECT))
    ]

    static let filters: [FilterOption] = [
        FilterOption(id: 0, name: "poly-sinc-gauss-long", taps: 512, family: 0, window: Int32(CWIN_GAUSS), rolloff: 0.94, note: "Long Gaussian, steep, linear phase"),
        FilterOption(id: 1, name: "poly-sinc-gauss", taps: 256, family: 0, window: Int32(CWIN_GAUSS), rolloff: 0.92, note: "Balanced Gaussian"),
        FilterOption(id: 2, name: "poly-sinc-gauss-short", taps: 128, family: 0, window: Int32(CWIN_GAUSS), rolloff: 0.90, note: "Short, low latency"),
        FilterOption(id: 3, name: "poly-sinc-hires", taps: 384, family: 0, window: Int32(CWIN_KAISER), rolloff: 0.97, note: "Wide passband for high-rate sources"),
        FilterOption(id: 4, name: "poly-sinc-ext", taps: 768, family: 0, window: Int32(CWIN_BLACKMAN_HARRIS), rolloff: 0.95, note: "Very steep, highest cost"),
        FilterOption(id: 5, name: "minringFIR", taps: 256, family: 0, window: Int32(CWIN_RECT), rolloff: 0.88, note: "Narrow transition, ringing"),
        FilterOption(id: 6, name: "poly-sinc-mp", taps: 320, family: 1, window: Int32(CWIN_KAISER), rolloff: 0.92, note: "Minimum phase, no pre-ringing"),
        FilterOption(id: 7, name: "poly-sinc-mp-short", taps: 128, family: 1, window: Int32(CWIN_KAISER), rolloff: 0.90, note: "Short minimum phase"),
        FilterOption(id: 8, name: "sinc-M", taps: 1024, family: 0, window: Int32(CWIN_BLACKMAN_HARRIS), rolloff: 0.96, note: "Long sinc, reference quality"),
        FilterOption(id: 9, name: "closed-form", taps: 64, family: 2, window: Int32(CWIN_RECT), rolloff: 0.499, note: "Closed-form, no window, fast")
    ]

    static let modulators: [(name: String, order: Int32)] = [
        ("4th order 1-bit", 4),
        ("2nd order 1-bit", 2)
    ]
}

// MARK: - Processing chain

final class ProcessingChain {
    /// The audio thread calls process/encode while the UI edits coefficients and
    /// reads meters, so every entry point takes this lock.
    private let lock = NSRecursiveLock()
    private var src: OpaquePointer?
    private var eq: OpaquePointer?
    private var conv: OpaquePointer?
    private var meter: OpaquePointer?
    private var limiter = CLimiter()
    private var sdm = CSdm()

    private(set) var inRate: Int = 44100
    var outRate: Int = 384000
    private(set) var channels: Int = 2
    /// True when the track's rate equals the output rate, so the chain copies
    /// instead of running a 1:1 sinc — a ratio-1 resampler still filters at
    /// 0.46·fs and delays by half its kernel, which is not native playback.
    private(set) var passthrough = false
    private var convIR: [Float]?

    var filter: FilterOption = Catalog.filters[1]
    var eqEnabled = false
    var eqBands: [EQBand] = EQBand.defaults
    var convolutionEnabled = false
    var matrixEnabled = false
    var matrix = Matrix(gLL: 1, gLR: 0, gRL: 0, gRR: 1)
    var limiterEnabled = true
    var limiterCeiling: Double = -0.3
    var bypassDSP = false
    var dither = true
    var noiseShaping: Int32 = 2
    var dsdGain: Double = 2.0

    private var outBuf: [Float] = []
    private var lastPeakL = 0.0, lastPeakR = 0.0, lastRmsL = 0.0, lastRmsR = 0.0

    init() {
        meter = meter_new()
        lim_init(&limiter, 2)
    }
    deinit {
        src_free(src)
        eq_free(eq)
        conv_free(conv)
        meter_free(meter)
    }

    func meters() -> (peakL: Double, peakR: Double, rmsL: Double, rmsR: Double) {
        lock.lock(); defer { lock.unlock() }
        return (lastPeakL, lastPeakR, lastRmsL, lastRmsR)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        src_reset(src)
        eq_reset(eq)
        conv_reset(conv)
        lim_reset(&limiter)
        sdm_reset(&sdm)
        meter_reset(meter)
    }

    /// Configures the resampler for a new source rate. Returns false if the core
    /// could not build a converter.
    func configure(sourceRate: Int) {
        lock.lock(); defer { lock.unlock() }
        inRate = sourceRate
        passthrough = sourceRate == outRate
        src_free(src)
        src = passthrough
            ? nil
            : src_new(Double(sourceRate), Double(outRate), filter.taps, filter.window,
                      filter.family, filter.rolloff, Int32(channels))

        eq_free(eq)
        eq = eq_new(Int32(channels), Int32(eqBands.count))
        applyEQ()

        if convolutionEnabled, let ir = convIR {
            conv_free(conv)
            conv = conv_new(Int32(channels), ir, Int32(ir.count), 1)
        }
        lim_init(&limiter, Int32(channels))
        limiter.ceiling_db = limiterCeiling
        sdm_reset(&sdm)
        meter_reset(meter)
    }

    func setConvolutionIR(_ ir: [Float]?) {
        lock.lock(); defer { lock.unlock() }
        convIR = ir
        conv_free(conv)
        conv = nil
        if let ir = ir, convolutionEnabled {
            conv = conv_new(Int32(channels), ir, Int32(ir.count), 1)
        }
    }

    func applyEQ() {
        lock.lock(); defer { lock.unlock() }
        guard let eq = eq else { return }
        eq_set_eq_enabled(eq, eqEnabled ? 1 : 0)
        for (i, b) in eqBands.enumerated() {
            eq_set_band(eq, Int32(i), b.type, b.freq, b.gain, b.q, b.enabled ? 1 : 0)
        }
    }

    var dspActive: Bool {
        !bypassDSP && (eqEnabled || convolutionEnabled || matrixEnabled || limiterEnabled)
    }

    /// Runs the chain on interleaved float32 frames and returns processed frames.
    func process(_ input: [Float], frames: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let produced: Int
        if passthrough {
            let need = frames * channels
            guard input.count >= need else { return [] }
            if outBuf.count < need { outBuf = [Float](repeating: 0, count: need) }
            for i in 0..<need { outBuf[i] = input[i] }
            produced = frames
        } else {
            guard let src = src else { return [] }
            let cap = Int(src_max_out(src, Int32(frames))) * channels
            if outBuf.count < cap { outBuf = [Float](repeating: 0, count: cap) }
            produced = Int(input.withUnsafeBufferPointer { ip in
                outBuf.withUnsafeMutableBufferPointer { op in
                    src_process(src, ip.baseAddress!, Int32(frames), op.baseAddress,
                                Int32(cap / channels))
                }
            })
            guard produced > 0 else { return [] }
        }

        outBuf.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            if bypassDSP {
                meter_process(meter, base, Int32(produced), Int32(channels))
                return
            }
            if let eq = eq, eqEnabled {
                eq_process(eq, base, Int32(produced), Int32(outRate))
            }
            if let conv = conv, convolutionEnabled {
                _ = conv_process(conv, base, Int32(produced))
            }
            if matrixEnabled {
                for i in 0..<produced {
                    let l = base[i * 2], r = base[i * 2 + 1]
                    base[i * 2] = Float(Double(l) * matrix.gLL + Double(r) * matrix.gRL)
                    base[i * 2 + 1] = Float(Double(l) * matrix.gLR + Double(r) * matrix.gRR)
                }
            }
            if limiterEnabled {
                limiter.ceiling_db = limiterCeiling
                lim_process(&limiter, base, Int32(produced), Int32(outRate))
            }
            meter_process(meter, base, Int32(produced), Int32(channels))
        }

        var pl = 0.0, pr = 0.0, rl = 0.0, rr = 0.0
        meter_get(meter, &pl, &pr, &rl, &rr)
        lastPeakL = pl; lastPeakR = pr; lastRmsL = rl; lastRmsR = rr
        meter_reset(meter)
        return Array(outBuf[0..<(produced * 2)])
    }

    /// Applies output gain and returns interleaved float32 frames.
    ///
    /// CoreAudio takes floats directly, so the local sink must never be handed
    /// the quantised byte layout: 32-bit PCM reinterpreted as float32 is a
    /// stream of NaNs and values around 1e38.
    func encodeFloat(_ frames: [Float], volume: Float) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard !frames.isEmpty else { return [] }
        guard volume != 1.0 else { return frames }
        var scaled = frames
        for i in 0..<scaled.count { scaled[i] *= volume }
        return scaled
    }

    /// Encodes processed frames into the wire layout the Pi's aplay expects.
    func encode(_ frames: [Float], format: OutputFormat, volume: Float) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let count = frames.count / 2
        guard count > 0 else { return [] }
        var scaled = frames
        if volume != 1.0 {
            for i in 0..<scaled.count { scaled[i] *= volume }
        }

        switch format.encoding {
        case .dsdNative:
            let words = (count + 31) / 32
            let bytes = words * 2 * 4
            var out = [UInt8](repeating: 0, count: bytes)
            scaled.withUnsafeBufferPointer { sp in
                out.withUnsafeMutableBytes { raw in
                    let w = raw.bindMemory(to: UInt32.self)
                    sdm_words(&sdm, sp.baseAddress!, Int32(count), 2, w.baseAddress, dsdGain)
                }
            }
            return out
        case .dsdDoP:
            let groups = (count + 15) / 16
            let bytes = groups * 2 * 3
            var out = [UInt8](repeating: 0, count: bytes)
            scaled.withUnsafeBufferPointer { sp in
                out.withUnsafeMutableBytes { raw in
                    sdm_pack_dop(&sdm, sp.baseAddress!, Int32(count), 2,
                                 raw.bindMemory(to: UInt8.self).baseAddress!, dsdGain)
                }
            }
            return out
        default:
            let bytes = count * 2 * Int(format.encoding.bits / 8)
            var out = [UInt8](repeating: 0, count: bytes)
            scaled.withUnsafeBufferPointer { sp in
                out.withUnsafeMutableBytes { raw in
                    _ = pcm_format(sp.baseAddress!, Int32(count), 2, format.encoding.bits,
                                   dither ? 1 : 0, noiseShaping,
                                   raw.bindMemory(to: UInt8.self).baseAddress!)
                }
            }
            return out
        }
    }
}

// MARK: - Value types for EQ / matrix

struct EQBand: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: Int32 = 0
    var freq: Double = 1000
    var gain: Double = 0
    var q: Double = 1.0
    var enabled = false

    static let defaults: [EQBand] = [
        EQBand(type: 1, freq: 80, gain: 0, q: 0.7, enabled: false),
        EQBand(type: 0, freq: 200, gain: 0, q: 1.0, enabled: false),
        EQBand(type: 0, freq: 500, gain: 0, q: 1.0, enabled: false),
        EQBand(type: 0, freq: 1000, gain: 0, q: 1.0, enabled: false),
        EQBand(type: 0, freq: 2000, gain: 0, q: 1.0, enabled: false),
        EQBand(type: 0, freq: 5000, gain: 0, q: 1.0, enabled: false),
        EQBand(type: 2, freq: 12000, gain: 0, q: 0.7, enabled: false)
    ]

    var typeName: String {
        switch type {
        case 0: return "Peak"
        case 1: return "Low shelf"
        case 2: return "High shelf"
        case 3: return "Low pass"
        case 4: return "High pass"
        case 5: return "Notch"
        case 6: return "All pass"
        default: return "Tilt"
        }
    }
}

struct Matrix: Codable, Equatable {
    var gLL: Double, gLR: Double, gRL: Double, gRR: Double
}

// MARK: - Presets

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var filterID: Int = 1
    var eqEnabled = false
    var eqBands: [EQBand] = EQBand.defaults
    var convolutionEnabled = false
    var irPath: String?
    var matrixEnabled = false
    var matrix = Matrix(gLL: 1, gLR: 0, gRL: 0, gRR: 1)
    var limiterEnabled = true
    var limiterCeiling: Double = -0.3
    var dither = true
    var noiseShaping: Int32 = 2
    var encoding: OutputEncoding = .pcm32
    var rate: Int = 384000
    var dsdMultiple = 256
    /// Optional so presets saved before rate modes existed still decode.
    var rateMode: OutputFormat.RateMode?
}
