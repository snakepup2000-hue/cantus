import Foundation
import AVFoundation
import CantusCore

// MARK: - Track metadata

struct TrackInfo: Codable, Equatable, Hashable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var trackNumber: Int = 0
    var duration: Double = 0
    var sampleRate: Int = 0
    var channels: Int = 1
    var bitDepth: Int = 0
    var isDSD = false
    var codec: String = ""
}

// MARK: - Streaming decoder

/// Pulls interleaved float32 frames from a file at its native rate.
/// CoreAudio handles FLAC/WAV/AIFF/ALAC/MP3/AAC/M4A; DSF/DFF are decoded here.
final class Decoder {
    enum Kind { case coreAudio, dsd }

    let url: URL
    let kind: Kind
    let sourceRate: Int
    let channels: Int
    private(set) var totalFrames: Int64 = 0
    private(set) var framesRead: Int64 = 0

    // CoreAudio path
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?

    // DSD path
    private var dsdData: Data?
    private var dsdOffset: Int = 0
    private var dsdWordCursor: Int = 0
    private var decim: OpaquePointer?
    private var dsdFifo: [Float] = []
    private var dsdFifoPos = 0
    private var dsdBytesPerSample = 1
    private var dsdChunk = 0

    init(url: URL) throws {
        self.url = url
        let ext = url.pathExtension.lowercased()
        if ext == "dsf" || ext == "dff" {
            let header = DSDHeader.parse(url: url, ext: ext)
            guard header.bitRate > 0 else {
                throw NSError(domain: "Cantus", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Unsupported DSD header"])
            }
            self.kind = .dsd
            self.channels = 2
            self.file = nil
            self.sourceRate = header.bitRate / 16
            self.totalFrames = Int64(header.sampleBytes) / 4
            self.dsdData = try Data(contentsOf: url, options: .mappedIfSafe)
            self.dsdOffset = header.dataOffset
            self.decim = dsdin_new(2, 4, 1.0)
            dsdin_reset(self.decim)
        } else {
            let f = try AVAudioFile(forReading: url)
            self.file = f
            self.kind = .coreAudio
            self.channels = Int(f.processingFormat.channelCount)
            self.sourceRate = Int(f.processingFormat.sampleRate)
            self.totalFrames = f.length
            self.buffer = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                           frameCapacity: 16384)
        }
    }

    var isFinished: Bool { framesRead >= totalFrames && totalFrames > 0 }

    func seek(toFrame frame: Int64) {
        if kind == .coreAudio {
            file?.framePosition = AVAudioFramePosition(max(0, frame))
            framesRead = max(0, frame)
        } else {
            let header = DSDHeader.parse(url: url, ext: url.pathExtension.lowercased())
            // Each "PCM frame" at bitRate/16 corresponds to 4 bytes of DSD words.
            let byte = header.dataOffset + Int(frame) * 4
            dsdOffset = min(max(header.dataOffset, byte), max(header.dataOffset, dsdData?.count ?? 0))
            dsdin_reset(decim)
            dsdFifo.removeAll()
            dsdFifoPos = 0
            dsdWordCursor = 0
            framesRead = frame
        }
    }

    /// Reads up to `frames` interleaved float32 frames. Returns count, 0 at EOF.
    func read(into out: inout [Float], frames: Int) -> Int {
        switch kind {
        case .coreAudio: return readCoreAudio(into: &out, frames: frames)
        case .dsd:       return readDSD(into: &out, frames: frames)
        }
    }

    private func readCoreAudio(into out: inout [Float], frames: Int) -> Int {
        guard let f = file, let buf = buffer else { return 0 }
        buf.frameLength = 0
        do { try f.read(into: buf, frameCount: AVAudioFrameCount(frames)) }
        catch { return 0 }
        let n = Int(buf.frameLength)
        if n == 0 { return 0 }
        let ch = Int(buf.format.channelCount)
        let need = n * 2
        if out.count < need { out = [Float](repeating: 0, count: max(need, 4096)) }
        if let fd = buf.floatChannelData {
            for i in 0..<n {
                out[i * 2] = fd[0][i]
                out[i * 2 + 1] = ch > 1 ? fd[1][i] : fd[0][i]
            }
        } else if let id = buf.int32ChannelData {
            for i in 0..<n {
                out[i * 2] = Float(id[0][i]) / 2147483648.0
                out[i * 2 + 1] = ch > 1 ? Float(id[1][i]) / 2147483648.0 : out[i * 2]
            }
        } else {
            return 0
        }
        framesRead += Int64(n)
        return n
    }

    private func readDSD(into out: inout [Float], frames: Int) -> Int {
        guard let d = dsdData, let decim = decim else { return 0 }
        let target = frames
        if out.count < target * 2 { out = [Float](repeating: 0, count: target * 2) }
        var produced = 0

        while produced < target {
            if dsdFifoPos + 2 <= dsdFifo.count {
                out[produced * 2] = dsdFifo[dsdFifoPos]
                out[produced * 2 + 1] = dsdFifo[dsdFifoPos + 1]
                dsdFifoPos += 2
                produced += 1
                continue
            }
            dsdFifo.removeAll(keepingCapacity: true)
            dsdFifoPos = 0
            // Feed a block of DSD_U32_BE words: 4096 words per channel.
            let wordsPerCh = 4096
            let bytesNeeded = wordsPerCh * 8
            let avail = d.count - dsdOffset
            if avail < 8 { break }
            let take = min(bytesNeeded, avail)
            let aligned = take - (take % 8)
            if aligned <= 0 { break }
            var tmp = [Float](repeating: 0, count: wordsPerCh * 2 + 64)
            let got = d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return 0 }
                let p = base.advanced(by: dsdOffset).assumingMemoryBound(to: UInt8.self)
                return Int(dsdin_process(decim, p, Int32(aligned / 8), 2, &tmp,
                                         Int32(tmp.count / 2)))
            }
            dsdOffset += aligned
            dsdFifo.reserveCapacity(got * 2)
            for i in 0..<got { dsdFifo.append(tmp[i * 2]); dsdFifo.append(tmp[i * 2 + 1]) }
            if got == 0 { break }
        }
        framesRead += Int64(produced)
        return produced
    }
}

// MARK: - DSD container headers

struct DSDHeader {
    var bitRate = 0
    var channels = 2
    var dataOffset = 0
    var sampleBytes = 0

    static func parse(url: URL, ext: String) -> DSDHeader {
        var h = DSDHeader()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return h }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4096), head.count >= 28 else { return h }
        if ext == "dsf" {
            // "DSD " chunk, then 28-byte "fmt " chunk.
            guard head[0] == 0x44, head[1] == 0x53, head[2] == 0x44, head[3] == 0x20 else { return h }
            let streamSize = le32(head, 12) ?? 0
            _ = streamSize
            let fmtSampleRate = le32(head, 28) ?? 0
            let chans = le32(head, 32) ?? 0
            h.channels = Int(chans)
            h.bitRate = Int(fmtSampleRate) * 8
            // Find "data" chunk size + offset.
            h.sampleBytes = 0
            h.dataOffset = Int(le64(head, 20) ?? 28) + 12
            if let total = try? fh.seekToEnd() {
                let end = Int(total)
                h.sampleBytes = max(0, end - h.dataOffset)
            }
        } else {
            // DFF: "FRM8" ... "DSD " ... "PROP"/"FS  " ... "DATA"
            guard String(data: head.prefix(4), encoding: .ascii) == "FRM8" else { return h }
            if let r = head.range(of: Data("FS  ".utf8)) {
                let i = r.lowerBound
                if i + 12 <= head.count { h.bitRate = Int(be32(head, i + 8) ?? 0) }
            }
            if let r = head.range(of: Data("DATA".utf8)) {
                let i = r.lowerBound
                h.dataOffset = i + 12
                h.sampleBytes = Int(be64(head, i + 4) ?? 0)
            }
            if h.bitRate == 0 { h.bitRate = 2822400 }
            h.channels = 2
        }
        return h
    }

    private static func le32(_ d: Data, _ o: Int) -> UInt32? {
        guard o + 4 <= d.count else { return nil }
        return UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }
    private static func le64(_ d: Data, _ o: Int) -> UInt64? {
        guard o + 8 <= d.count else { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(d[o + i]) }
        return v
    }
    private static func be32(_ d: Data, _ o: Int) -> UInt32? {
        guard o + 4 <= d.count else { return nil }
        return (UInt32(d[o]) << 24) | (UInt32(d[o + 1]) << 16) | (UInt32(d[o + 2]) << 8) | UInt32(d[o + 3])
    }
    private static func be64(_ d: Data, _ o: Int) -> UInt64? {
        guard o + 8 <= d.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(d[o + i]) }
        return v
    }
}

// MARK: - Metadata extraction

enum MetadataReader {
    static func info(for url: URL) -> TrackInfo {
        var t = TrackInfo()
        t.title = url.deletingPathExtension().lastPathComponent
        do {
            let f = try AVAudioFile(forReading: url)
            t.sampleRate = Int(f.processingFormat.sampleRate)
            t.channels = Int(f.processingFormat.channelCount)
            t.duration = f.length > 0 ? Double(f.length) / f.processingFormat.sampleRate : 0
            t.codec = url.pathExtension.uppercased()
            t.bitDepth = Int(f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0)
            let items = f.url.pathExtension.lowercased() == "mp3" ? AVAsset(url: url).commonMetadata : []
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:  t.title = item.stringValue ?? t.title
                case .commonKeyArtist: t.artist = item.stringValue ?? ""
                case .commonKeyAlbumName: t.album = item.stringValue ?? ""
                default: break
                }
            }
            if let n = f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int { t.bitDepth = n }
        } catch {
            let ext = url.pathExtension.lowercased()
            if ext == "dsf" || ext == "dff" {
                let h = DSDHeader.parse(url: url, ext: ext)
                t.isDSD = true
                t.sampleRate = h.bitRate
                t.bitDepth = 1
                t.codec = ext.uppercased()
                t.duration = h.bitRate > 0 ? Double(h.sampleBytes * 8) / Double(h.bitRate) / 2.0 : 0
            }
        }
        return t
    }
}
