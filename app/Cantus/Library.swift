import Foundation
import Observation

struct LibraryTrack: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    var title: String
    var artist: String
    var album: String
    var trackNumber: Int
    var duration: Double
    var sampleRate: Int
    var channels: Int
    var isDSD: Bool
    var codec: String
    var folderID: UUID?

    var url: URL { URL(fileURLWithPath: path) }
    func queueItem() -> QueueItem {
        QueueItem(url: url, title: title, artist: artist, album: album, duration: duration,
                 sourceRate: sampleRate, channels: channels, isDSD: isDSD, codec: codec)
    }
}

struct LibraryFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    var name: String
    var parentID: UUID?
    var isExpanded: Bool = true
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var paths: [String] = []
}

struct PersistedState: Codable {
    var tracks: [LibraryTrack] = []
    var folders: [LibraryFolder] = []
    var playlists: [Playlist] = []
    var outputFormat = OutputFormat()
    var transport = OutputTransport.network
    var networkHost = PiRig.host
    var networkUser = PiRig.user
    var networkDevice = PiRig.device
    var volume = 0.8
    var filterID = 1
    var eqEnabled = false
    var eqBands = EQBand.defaults
    var convolutionEnabled = false
    var irPath: String?
    var matrixEnabled = false
    var matrix = Matrix(gLL: 1, gLR: 0, gRL: 0, gRR: 1)
    var limiterEnabled = true
    var limiterCeiling = -0.3
    var bypass = false
    var presets: [Preset] = []

    // Optional so a library.json written by an older build still decodes —
    // a missing non-optional key throws and would empty the whole library.
    var shuffle: Bool?
    var repeatMode: String?
    var muted: Bool?
    var dither: Bool?
    var noiseShaping: Int32?
    var networkKeyPath: String?
    var networkBufferMs: Int?
}

enum SortKey: String, CaseIterable, Identifiable {
    case filename = "File name"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case trackNumber = "Track #"
    case duration = "Duration"
    var id: String { rawValue }
}

@MainActor
@Observable
final class LibraryModel {
    var tracks: [LibraryTrack] = []
    var folders: [LibraryFolder] = []
    var playlists: [Playlist] = []
    var presets: [Preset] = []
    var searchText = ""
    var sortKey: SortKey = .filename
    var sortAscending = true
    var selectedFolderID: UUID?
    var selectedTrackIDs: Set<UUID> = []
    var isLoading = false
    var progress = ""

    /// The state last read from (or written to) disk. Content edits merge into
    /// it so audio settings survive a rescan.
    private var stored = PersistedState()

    private let stateURL: URL = {
        // Tests point this at a temp file so they never touch the real library.
        if let override = ProcessInfo.processInfo.environment["CANTUS_LIBRARY_PATH"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return url
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Cantus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    init() { load() }

    // MARK: persistence

    func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let st = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        stored = st
        tracks = st.tracks
        folders = st.folders
        playlists = st.playlists
        presets = st.presets
        // prune entries whose files disappeared
        tracks.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Writing content must not discard the saved output/DSP settings, so a
    /// plain `save()` merges into the last state read from disk.
    func save(state: PersistedState? = nil) {
        var st = state ?? stored
        st.tracks = tracks
        st.folders = folders
        st.playlists = playlists
        st.presets = presets
        stored = st
        if let data = try? JSONEncoder().encode(st) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// Applies the persisted audio settings to a freshly created engine.
    func restoreSettings(into engine: PlayerEngine) {
        engine.applySettings(stored)
    }

    /// Snapshot of the engine's settings, stored alongside the library.
    func save(engine: PlayerEngine) {
        save(state: engine.captureSettings(into: stored))
    }

    // MARK: adding content

    static let audioExtensions: Set<String> = [
        "wav","wave","aif","aiff","flac","mp3","m4a","aac","alac","ogg","opus","dsf","dff","wv","ape"
    ]

    func addFiles(_ urls: [URL]) {
        isLoading = true
        let list = urls.filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
        scan(urls: list, into: nil)
        isLoading = false
    }

    func addFolder(_ url: URL) {
        isLoading = true
        progress = "Scanning \(url.lastPathComponent)…"
        let folder = LibraryFolder(path: url.path, name: url.lastPathComponent, parentID: nil)
        if !folders.contains(where: { $0.path == url.path }) {
            folders.append(folder)
        }
        let fid = folders.first(where: { $0.path == url.path })?.id
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [URL] = []
            let fm = FileManager.default
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let f as URL in e {
                    if Self.audioExtensions.contains(f.pathExtension.lowercased()) {
                        found.append(f)
                    }
                }
            }
            let metas = found.map { ($0, MetadataReader.info(for: $0)) }
            Task { @MainActor in
                self.ingest(metas: metas, folderID: fid)
                self.progress = "Added \(found.count) track(s) from \(url.lastPathComponent)"
                self.isLoading = false
                self.save()
            }
        }
    }

    private func scan(urls: [URL], into folderID: UUID?) {
        let metas = urls.map { ($0, MetadataReader.info(for: $0)) }
        ingest(metas: metas, folderID: folderID)
        save()
    }

    private func ingest(metas: [(URL, TrackInfo)], folderID: UUID?) {
        let existing = Set(tracks.map(\.path))
        var added = 0
        for (url, info) in metas where !existing.contains(url.path) {
            var t = LibraryTrack(path: url.path, title: info.title, artist: info.artist,
                                 album: info.album, trackNumber: 0, duration: info.duration,
                                 sampleRate: info.sampleRate, channels: info.channels,
                                 isDSD: info.isDSD, codec: info.codec, folderID: folderID)
            t.trackNumber = Self.trackNumber(from: url.lastPathComponent)
            tracks.append(t)
            added += 1
        }
        if added > 0 { progress = "Added \(added) track(s)" }
    }

    static func trackNumber(from name: String) -> Int {
        let digits = name.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    func removeTracks(_ ids: Set<UUID>) {
        tracks.removeAll { ids.contains($0.id) }
        save()
    }

    func removeFolder(_ id: UUID) {
        let paths = folders.filter { $0.id == id }.map(\.path)
        folders.removeAll { $0.id == id }
        tracks.removeAll { t in paths.contains { t.path.hasPrefix($0) } }
        save()
    }

    // MARK: playlists

    @discardableResult
    func createPlaylist(name: String, paths: [String] = []) -> Playlist {
        let p = Playlist(name: name, paths: paths)
        playlists.append(p)
        save()
        return p
    }

    func addToPlaylist(_ id: UUID, paths: [String]) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        for p in paths where !playlists[i].paths.contains(p) { playlists[i].paths.append(p) }
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    // MARK: browsing

    func tracks(in folderID: UUID?, search: String, sort: SortKey, ascending: Bool) -> [LibraryTrack] {
        var list: [LibraryTrack]
        if let fid = folderID, let f = folders.first(where: { $0.id == fid }) {
            list = tracks.filter { t in
                if t.folderID == fid { return true }
                return t.path.hasPrefix(f.path + "/")
            }
        } else {
            list = tracks
        }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) ||
                $0.album.lowercased().contains(q) ||
                URL(fileURLWithPath: $0.path).lastPathComponent.lowercased().contains(q)
            }
        }
        list.sort { a, b in
            let r: Bool
            switch sort {
            case .filename:
                r = URL(fileURLWithPath: a.path).lastPathComponent.localizedStandardCompare(
                    URL(fileURLWithPath: b.path).lastPathComponent) == .orderedAscending
            case .title: r = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .artist: r = a.artist.localizedStandardCompare(b.artist) == .orderedAscending
            case .album: r = a.album.localizedStandardCompare(b.album) == .orderedAscending
            case .trackNumber: r = a.trackNumber < b.trackNumber
            case .duration: r = a.duration < b.duration
            }
            return ascending ? r : !r
        }
        return list
    }

    func playlistTracks(_ id: UUID) -> [LibraryTrack] {
        guard let p = playlists.first(where: { $0.id == id }) else { return [] }
        let byPath = Dictionary(uniqueKeysWithValues: tracks.map { ($0.path, $0) })
        return p.paths.compactMap { byPath[$0] }
    }
}
