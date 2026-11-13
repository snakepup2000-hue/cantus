import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Shared helpers

func timeString(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let total = Int(t.rounded())
    let m = total / 60, s = total % 60
    return String(format: "%d:%02d", m, s)
}

enum SidebarTarget: Hashable {
    case all
    case folder(UUID)
    case playlist(UUID)
}

// MARK: - Root

struct ContentView: View {
    @Environment(LibraryModel.self) private var lib
    @Environment(PlayerEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var showQueue = true
    @State private var selection: Set<LibraryTrack.ID> = []
    @State private var browsing: SidebarTarget = .all
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar(target: $browsing)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                BrowserHeader(target: browsing)
                Divider()
                TrackTable(target: browsing, selection: $selection)
                Divider()
                TransportBar(showSettings: $showSettings)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(8)
                        .allowsHitTesting(false)
                        .overlay(
                            Text("Drop audio files or folders")
                                .font(.title3.weight(.semibold))
                                .padding(18)
                                .background(.regularMaterial,
                                            in: RoundedRectangle(cornerRadius: 12))
                        )
                }
            }
        }
        .inspector(isPresented: $showQueue) {
            QueuePanel()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onChange(of: showSettings) { _, showing in
            if !showing { lib.save(engine: engine) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { lib.save(engine: engine) }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { handleDrop($0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Audio settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showQueue.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
                    .help("Show or hide the queue")
            }
        }
        .onAppear {
            // Restore the saved output/DSP settings before anything can play.
            lib.restoreSettings(into: engine)
            EngineLocator.shared.engine = engine
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }
        group.notify(queue: .main) {
            let folders = urls.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            let files = urls.filter { !folders.contains($0) }
            if !files.isEmpty { lib.addFiles(files) }
            for f in folders { lib.addFolder(f) }
        }
        return true
    }
}

/// Deeply nested rows need the engine outside the view environment.
final class EngineLocator {
    static let shared = EngineLocator()
    weak var engine: PlayerEngine?
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(LibraryModel.self) private var lib
    @Binding var target: SidebarTarget
    @State private var newPlaylistName = ""
    @State private var showNewPlaylist = false

    var body: some View {
        List(selection: Binding(get: { target }, set: { if let t = $0 { target = t } })) {
            Section("Library") {
                Label("All Tracks", systemImage: "music.note.list")
                    .tag(SidebarTarget.all)
            }
            Section("Folders") {
                if lib.folders.isEmpty {
                    Text("Add a folder with the + button, or drag one into the window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(lib.folders) { folder in
                    FolderRow(folder: folder)
                        .tag(SidebarTarget.folder(folder.id))
                }
            }
            Section("Playlists") {
                ForEach(lib.playlists) { p in
                    Label(p.name, systemImage: "music.note.list")
                        .tag(SidebarTarget.playlist(p.id))
                        .contextMenu {
                            Button("Delete", role: .destructive) { lib.deletePlaylist(p.id) }
                        }
                }
                Button { showNewPlaylist = true } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { pickFiles() } label: { Image(systemName: "doc.badge.plus") }
                    .help("Add audio files")
            }
            ToolbarItem {
                Button { pickFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help("Add a folder, including subfolders")
            }
        }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                if !newPlaylistName.isEmpty {
                    _ = lib.createPlaylist(name: newPlaylistName)
                    newPlaylistName = ""
                }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        if panel.runModal() == .OK { lib.addFiles(panel.urls) }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for u in panel.urls { lib.addFolder(u) } }
    }
}

/// A folder that expands to reveal the real files inside it.
struct FolderRow: View {
    @Environment(LibraryModel.self) private var lib
    let folder: LibraryFolder
    @State private var expanded = true

    private var children: [LibraryTrack] {
        lib.tracks
            .filter { $0.path.hasPrefix(folder.path + "/") }
            .sorted {
                URL(fileURLWithPath: $0.path).lastPathComponent
                    .localizedStandardCompare(URL(fileURLWithPath: $1.path).lastPathComponent)
                    == .orderedAscending
            }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(children) { t in
                HStack(spacing: 6) {
                    Image(systemName: t.isDSD ? "waveform.path" : "music.note")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: t.path).lastPathComponent)
                        .font(.caption).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { play([t]) }
                .contextMenu {
                    Button("Play Now") { play([t]) }
                    Button("Add to Queue") { enqueue([t]) }
                }
            }
        } label: {
            Label(folder.name, systemImage: "folder").lineLimit(1)
        }
        .contextMenu {
            Button("Remove folder", role: .destructive) { lib.removeFolder(folder.id) }
        }
    }

    private func play(_ tracks: [LibraryTrack]) {
        EngineLocator.shared.engine?.load(tracks.map { $0.queueItem() }, startAt: 0, autoplay: true)
    }
    private func enqueue(_ tracks: [LibraryTrack]) {
        EngineLocator.shared.engine?.enqueue(tracks.map { $0.queueItem() })
    }
}
