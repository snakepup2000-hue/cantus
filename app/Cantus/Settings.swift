import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Settings sheet

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Audio Settings").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            TabView {
                OutputSettings().tabItem { Label("Output", systemImage: "network") }
                DSPSettings().tabItem { Label("DSP", systemImage: "waveform") }
                EQSettings().tabItem { Label("EQ", systemImage: "slider.vertical.3") }
                PresetSettings().tabItem { Label("Presets", systemImage: "square.stack.3d.up") }
            }
            .padding(12)
        }
        .frame(width: 780, height: 580)
    }
}

// MARK: - Output

struct OutputSettings: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        @Bindable var engine = engine
        Form {
            Section("Destination") {
                Picker("Play through", selection: $engine.transport) {
                    ForEach(OutputTransport.allCases) { t in Text(t.label).tag(t) }
                }
                .pickerStyle(.radioGroup)
            }
            if engine.transport == .network {
                Section("Raspberry Pi receiver") {
                    TextField("Host", text: $engine.network.host)
                    TextField("User", text: $engine.network.user)
                    TextField("ALSA device", text: $engine.network.device)
                    Stepper("ALSA buffer: \(engine.network.bufferMs) ms",
                            value: $engine.network.bufferMs, in: 20...500, step: 10)
                    HStack {
                        Button("Test connection") { engine.testConnection() }
                        Text(engine.statusMessage)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("No software needs installing on the Pi: Cantus sends raw PCM over SSH to the stock aplay tool, and the DAC clock paces the stream.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("Output format") {
                Picker("Encoding", selection: $engine.outputFormat.encoding) {
                    ForEach(OutputEncoding.allCases) { e in Text(e.label).tag(e) }
                }
                if engine.outputFormat.isDSD {
                    Picker("DSD rate", selection: $engine.outputFormat.dsdMultiple) {
                        Text("DSD64").tag(64)
                        Text("DSD128").tag(128)
                        Text("DSD256").tag(256)
                    }
                    .pickerStyle(.segmented)
                } else {
                    Picker("Sample rate", selection: $engine.outputFormat.rate) {
                        ForEach([44100, 48000, 88200, 96000, 176400, 192000,
                                 352800, 384000], id: \.self) { r in
                            Text("\(OutputFormat.kHzLabel(r)) kHz").tag(r)
                        }
                    }
                    .disabled(engine.outputFormat.rateMode == .matchTrack)
                    Toggle("Play each track at its own rate instead", isOn: Binding(
                        get: { engine.outputFormat.rateMode == .matchTrack },
                        set: { engine.outputFormat.rateMode = $0 ? .matchTrack : .fixed }))
                    Text(rateCaption)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("The FiiO K11 R2R reports PCM 44.1-384 kHz (S16/S24/S32) and native DSD_U32_BE.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var rateCaption: String {
        let fmt = engine.outputFormat
        if fmt.encoding.isDSD {
            return "DSD always runs through the modulator, so it is resampled from the track's rate."
        }
        if fmt.rateMode == .matchTrack {
            return "Each track plays at the rate it was recorded at and the DAC re-clocks between "
                 + "tracks. Tracks at a rate the K11 does not list play at "
                 + "\(OutputFormat.kHzLabel(fmt.rate)) kHz."
        }
        return "Everything is resampled to \(OutputFormat.kHzLabel(fmt.rate)) kHz — an 88.2 kHz "
             + "track plays as \(OutputFormat.kHzLabel(fmt.rate)) kHz."
    }
}

// MARK: - DSP

struct DSPSettings: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        @Bindable var engine = engine
        Form {
            Section("Resampling filter") {
                Picker("Filter", selection: $engine.selectedFilter) {
                    ForEach(Catalog.filters) { f in Text(f.name).tag(f) }
                }
                Text(engine.selectedFilter.note)
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(engine.selectedFilter.taps) taps · " + familyName)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Processing") {
                Toggle("Bypass all DSP (resampling only)", isOn: Binding(
                    get: { engine.dsp.bypassDSP },
                    set: { engine.dsp.bypassDSP = $0; engine.updateProcessingText() }))
                Toggle("Clipping protection (brickwall limiter)", isOn: Binding(
                    get: { engine.dsp.limiterEnabled },
                    set: { engine.dsp.limiterEnabled = $0; engine.updateProcessingText() }))
                HStack {
                    Text("Ceiling")
                    Slider(value: Binding(
                        get: { engine.dsp.limiterCeiling },
                        set: { engine.dsp.limiterCeiling = $0; engine.updateProcessingText() }),
                           in: -6...0, step: 0.1)
                    Text(String(format: "%.1f dB", engine.dsp.limiterCeiling))
                        .monospacedDigit().frame(width: 58)
                }
            }
            Section("Dither and noise shaping") {
                Toggle("Dither (TPDF)", isOn: Binding(
                    get: { engine.dsp.dither }, set: { engine.dsp.dither = $0 }))
                Picker("Noise shaping", selection: Binding(
                    get: { engine.dsp.noiseShaping },
                    set: { engine.dsp.noiseShaping = $0 })) {
                    Text("None").tag(Int32(0))
                    Text("1st order").tag(Int32(1))
                    Text("2nd order").tag(Int32(2))
                    Text("3rd order").tag(Int32(3))
                }
            }
            Section("Convolution") {
                HStack {
                    Text(engine.dsp.convolutionEnabled ? "Impulse response loaded" : "No impulse response")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose IR…") { pickIR() }
                    if engine.dsp.convolutionEnabled {
                        Button("Clear") { engine.setIR(path: nil) }
                    }
                }
                Text("Mono or stereo WAV/AIFF, applied to both channels. Useful for room correction.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Channel routing") {
                Toggle("Enable matrix", isOn: Binding(
                    get: { engine.dsp.matrixEnabled },
                    set: { engine.dsp.matrixEnabled = $0; engine.updateProcessingText() }))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        Text("→ L").font(.caption)
                        Text("→ R").font(.caption)
                    }
                    GridRow {
                        Text("L →").font(.caption)
                        gainField(\.gLL)
                        gainField(\.gLR)
                    }
                    GridRow {
                        Text("R →").font(.caption)
                        gainField(\.gRL)
                        gainField(\.gRR)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var familyName: String {
        switch engine.selectedFilter.family {
        case 1: return "minimum phase"
        case 2: return "closed form"
        default: return "linear phase"
        }
    }

    private func gainField(_ kp: WritableKeyPath<Matrix, Double>) -> some View {
        TextField("", value: Binding(
            get: { engine.dsp.matrix[keyPath: kp] },
            set: { engine.dsp.matrix[keyPath: kp] = $0 }), format: .number)
            .frame(width: 70)
            .textFieldStyle(.roundedBorder)
    }

    private func pickIR() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .aiff]
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let u = panel.url { engine.setIR(path: u.path) }
    }
}

// MARK: - EQ

struct EQSettings: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable parametric EQ", isOn: Binding(
                get: { engine.dsp.eqEnabled },
                set: { engine.dsp.eqEnabled = $0; engine.applyEQ() }))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(engine.dsp.eqBands.indices, id: \.self) { i in
                        EQBandRow(index: i)
                    }
                }
            }
        }
    }
}

struct EQBandRow: View {
    @Environment(PlayerEngine.self) private var engine
    let index: Int

    var body: some View {
        let band = engine.dsp.eqBands[index]
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { engine.dsp.eqBands[index].enabled },
                set: { engine.dsp.eqBands[index].enabled = $0; engine.applyEQ() }))
                .labelsHidden().frame(width: 28)
            Picker("", selection: Binding(
                get: { engine.dsp.eqBands[index].type },
                set: { engine.dsp.eqBands[index].type = $0; engine.applyEQ() })) {
                Text("Peak").tag(Int32(0))
                Text("Low shelf").tag(Int32(1))
                Text("High shelf").tag(Int32(2))
                Text("Low pass").tag(Int32(3))
                Text("High pass").tag(Int32(4))
                Text("Notch").tag(Int32(5))
            }.labelsHidden().frame(width: 100)
            Text("\(Int(band.freq)) Hz")
                .font(.caption).monospacedDigit().frame(width: 72)
            Slider(value: Binding(
                get: { engine.dsp.eqBands[index].freq },
                set: { engine.dsp.eqBands[index].freq = $0; engine.applyEQ() }),
                   in: 20...20000).frame(width: 130)
            Text(String(format: "%+.1f dB", band.gain))
                .font(.caption).monospacedDigit().frame(width: 62)
            Slider(value: Binding(
                get: { engine.dsp.eqBands[index].gain },
                set: { engine.dsp.eqBands[index].gain = $0; engine.applyEQ() }),
                   in: -18...18).frame(width: 120)
            Text("Q \(String(format: "%.2f", band.q))")
                .font(.caption2).monospacedDigit().frame(width: 58)
            Slider(value: Binding(
                get: { engine.dsp.eqBands[index].q },
                set: { engine.dsp.eqBands[index].q = $0; engine.applyEQ() }),
                   in: 0.2...8).frame(width: 80)
        }
    }
}

// MARK: - Presets

struct PresetSettings: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(LibraryModel.self) private var lib
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Preset name", text: $newName).textFieldStyle(.roundedBorder)
                Button("Save current") {
                    let name = newName.isEmpty ? "Preset \(lib.presets.count + 1)" : newName
                    var p = Preset(name: name)
                    p.filterID = engine.selectedFilter.id
                    p.eqEnabled = engine.dsp.eqEnabled
                    p.eqBands = engine.dsp.eqBands
                    p.convolutionEnabled = engine.dsp.convolutionEnabled
                    p.irPath = engine.irPath
                    p.matrixEnabled = engine.dsp.matrixEnabled
                    p.matrix = engine.dsp.matrix
                    p.limiterEnabled = engine.dsp.limiterEnabled
                    p.limiterCeiling = engine.dsp.limiterCeiling
                    p.dither = engine.dsp.dither
                    p.noiseShaping = engine.dsp.noiseShaping
                    p.encoding = engine.outputFormat.encoding
                    p.rate = engine.outputFormat.rate
                    p.dsdMultiple = engine.outputFormat.dsdMultiple
                    p.rateMode = engine.outputFormat.rateMode
                    lib.presets.append(p)
                    lib.save()
                    newName = ""
                }
            }
            List {
                ForEach(lib.presets) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Button("Load") { apply(p) }
                        Button("Delete", role: .destructive) {
                            lib.presets.removeAll { $0.id == p.id }
                            lib.save()
                        }
                    }
                }
            }
        }
    }

    private func apply(_ p: Preset) {
        if let f = Catalog.filters.first(where: { $0.id == p.filterID }) {
            engine.selectedFilter = f
        }
        engine.dsp.eqEnabled = p.eqEnabled
        engine.dsp.eqBands = p.eqBands
        // The IR is a file path, not coefficients: reload it when the preset
        // expects convolution, and clear it when it does not.
        if p.convolutionEnabled, let path = p.irPath {
            engine.setIR(path: path)
        } else if !p.convolutionEnabled {
            engine.setIR(path: nil)
        }
        engine.dsp.matrixEnabled = p.matrixEnabled
        engine.dsp.matrix = p.matrix
        engine.dsp.limiterEnabled = p.limiterEnabled
        engine.dsp.limiterCeiling = p.limiterCeiling
        engine.dsp.dither = p.dither
        engine.dsp.noiseShaping = p.noiseShaping
        engine.outputFormat.encoding = p.encoding
        engine.outputFormat.rate = p.rate
        engine.outputFormat.dsdMultiple = p.dsdMultiple
        if let mode = p.rateMode { engine.outputFormat.rateMode = mode }
        engine.applyEQ()
        engine.updateProcessingText()
    }
}
