// probe_render — render a file through the app's own ProcessingChain exactly as
// Engine.audioMain does, write the wire payload, and measure it.
//
// This is how "is the app producing rubbish, or is it leaving the machine
// corrupted?" gets answered without ears: a clean render shows a plausible
// peak/rms, zero non-finite samples and a sane zero-crossing rate; a broken one
// shows full-scale runs or NaNs.
//
//   probe <in> <out.raw> <sourceRate> <outRate> <16|24|32|dsd>
import Foundation
import AVFoundation

@main
struct ProbeMain {
    static func main() throws {

        let a = CommandLine.arguments
        guard a.count >= 6 else { print("usage: probe in out srcRate outRate enc"); exit(2) }
        let inURL = URL(fileURLWithPath: a[1])
        let outURL = URL(fileURLWithPath: a[2])
        let srcRate = Int(a[3])!
        let outRate = Int(a[4])!
        let enc = a[5]

        var fmt = OutputFormat()
        switch enc {
        case "16": fmt.encoding = .pcm16
        case "24": fmt.encoding = .pcm24
        case "32": fmt.encoding = .pcm32
        case "dsd": fmt.encoding = .dsdNative; fmt.dsdMultiple = 256
        default: fmt.encoding = .pcm32
        }

        let dec = try! Decoder(url: inURL)
        precondition(dec.sourceRate == srcRate, "fixture rate \(dec.sourceRate) != \(srcRate)")

        let chain = ProcessingChain()
        chain.outRate = fmt.isDSD ? fmt.dsdBitRate : outRate
        chain.configure(sourceRate: dec.sourceRate)
        print("chain inRate=\(chain.inRate) outRate=\(chain.outRate) passthrough=\(chain.passthrough)")

        var readBuf = [Float](repeating: 0, count: 16384 * 2)
        var bytes = Data()
        var inPeak: Float = 0
        while true {
        let n = dec.read(into: &readBuf, frames: 4096)
        if n <= 0 { break }
        for i in 0..<(n * 2) { inPeak = max(inPeak, abs(readBuf[i])) }
        let processed = chain.process(readBuf, frames: n)
        if processed.isEmpty { continue }
        let enc2 = chain.encode(processed, format: fmt, volume: 1.0)
        bytes.append(contentsOf: enc2)
        }
        try bytes.write(to: outURL)
        print("inPeak=\(inPeak) bytes=\(bytes.count)")

        // Decode the payload back and measure it: a clean tone has a high crest factor
        // and leaves most samples below full scale; noise or garbage does not.
        if enc != "dsd" {
        let width = Int(fmt.encoding.bits) / 8
        var vals: [Double] = []
        var i = 0
        while i + width <= bytes.count {
        var v: Int64 = 0
        for b in 0..<width { v |= Int64(bytes[i + b]) << (8 * b) }
        if width == 4, v & 0x80000000 != 0 { v -= 0x1_0000_0000 }
        if width == 3, v & 0x800000 != 0 { v -= 0x1_000_000 }
        if width == 2, v & 0x8000 != 0 { v -= 0x1_0000 }
        let scale = pow(2.0, Double(8 * width - 1)) - 1
        vals.append(Double(v) / scale)
        i += width
        }
        let peak = vals.map { abs($0) }.max() ?? 0
        let ms = vals.reduce(0.0) { $0 + $1 * $1 } / Double(vals.count)
        let rms = ms.squareRoot()
        let nonFinite = vals.filter { !$0.isFinite }.count
        // Zero-crossing rate is a cheap discriminator: a 1 kHz tone at 88.2 kHz
        // crosses ~2000 times a second; full-scale noise crosses far more.
        var zc = 0
        for k in 1..<vals.count where (vals[k - 1] < 0) != (vals[k] < 0) { zc += 1 }
        let frames = Double(vals.count) / 2
        let zcPerSec = frames > 0 ? Double(zc) / 2 / (frames / Double(outRate)) : 0
        print(String(format: "payload peak=%.4f rms=%.4f nonFinite=%d zc/s=%.0f (expect ~2000 for a 1 kHz tone)",
        peak, rms, nonFinite, zcPerSec))
        }

    }
}
