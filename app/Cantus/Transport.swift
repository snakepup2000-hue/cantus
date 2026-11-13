import SwiftUI

// MARK: - Transport bar

struct TransportBar: View {
    @Environment(PlayerEngine.self) private var engine
    @Binding var showSettings: Bool
    @State private var seekValue: Double = 0
    @State private var scrubbing = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(engine.current?.title ?? "Nothing playing")
                    .font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Text("\(timeString(engine.elapsed)) / \(timeString(engine.currentDuration))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $seekValue, in: 0...max(0.1, engine.currentDuration)) { editing in
                scrubbing = editing
                if !editing { engine.seek(to: seekValue) }
            }
            .onChange(of: engine.elapsed) { _, v in if !scrubbing { seekValue = v } }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.outputDescription)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Text(engine.activeProcessing)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 230, alignment: .leading)

                Spacer()

                Button { engine.previous() } label: {
                    Image(systemName: "backward.fill")
                }.buttonStyle(.borderless).help("Previous")

                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                }.buttonStyle(.borderless).help("Play / Pause")

                Button { engine.stop() } label: {
                    Image(systemName: "stop.fill")
                }.buttonStyle(.borderless).help("Stop")

                Button { engine.next() } label: {
                    Image(systemName: "forward.fill")
                }.buttonStyle(.borderless).help("Next")

                Spacer()

                Button { engine.shuffle.toggle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(engine.shuffle ? Color.accentColor : Color.secondary)
                }.buttonStyle(.borderless).help("Shuffle")

                Button {
                    switch engine.repeatMode {
                    case .off: engine.repeatMode = .all
                    case .all: engine.repeatMode = .one
                    case .one: engine.repeatMode = .off
                    }
                } label: {
                    Image(systemName: engine.repeatMode.symbol)
                        .foregroundStyle(engine.repeatMode == .off
                                         ? Color.secondary : Color.accentColor)
                }.buttonStyle(.borderless).help(engine.repeatMode.label)

                Button { engine.toggleMute() } label: {
                    Image(systemName: engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }.buttonStyle(.borderless).help("Mute")

                Slider(value: Binding(get: { engine.volume },
                                      set: { engine.setVolume($0) }), in: 0...1)
                    .frame(width: 110)
                Text("\(Int(engine.volume * 100))")
                    .font(.caption2).monospacedDigit()
                    .frame(width: 26, alignment: .trailing)
            }

            HStack(spacing: 14) {
                MeterView(label: "L", value: engine.rmsL, peak: engine.peakL)
                MeterView(label: "R", value: engine.rmsR, peak: engine.peakR)
                if engine.clipped {
                    Text("CLIP").font(.caption2.weight(.bold)).foregroundStyle(.red)
                }
                Spacer()
                Text(engine.statusMessage)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

struct MeterView: View {
    let label: String
    let value: Double
    let peak: Double

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.green, .yellow, .red],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(level))
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * CGFloat(peakLevel))
                }
            }
            .frame(width: 80, height: 6)
        }
    }

    private var level: Double { norm(value) }
    private var peakLevel: Double { norm(peak) }

    private func norm(_ v: Double) -> Double {
        guard v > 0 else { return 0 }
        let db = 20 * log10(v)
        return max(0, min(1, (db + 60) / 60))
    }
}
