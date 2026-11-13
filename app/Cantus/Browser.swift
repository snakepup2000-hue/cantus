import SwiftUI

// MARK: - Browser header

struct BrowserHeader: View {
    @Environment(LibraryModel.self) private var lib
    let target: SidebarTarget

    var body: some View {
        @Bindable var lib = lib
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text("\(rows.count) track(s)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search", text: $lib.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Picker("Sort", selection: $lib.sortKey) {
                ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 140)
            Button { lib.sortAscending.toggle() } label: {
                Image(systemName: lib.sortAscending ? "arrow.up" : "arrow.down")
            }
            .help("Toggle sort direction")
        }
        .padding(12)
    }

    private var title: String {
        switch target {
        case .all: return "All Tracks"
        case .folder(let id): return lib.folders.first { $0.id == id }?.name ?? "Folder"
        case .playlist(let id): return lib.playlists.first { $0.id == id }?.name ?? "Playlist"
        }
    }

    private var rows: [LibraryTrack] {
        switch target {
        case .all:
            return lib.tracks(in: nil, search: lib.searchText, sort: lib.sortKey,
                              ascending: lib.sortAscending)
        case .folder(let id):
            return lib.tracks(in: id, search: lib.searchText, sort: lib.sortKey,
                              ascending: lib.sortAscending)
        case .playlist(let id):
            return lib.playlistTracks(id)
        }
    }
}

// MARK: - Track table

struct TrackTable: View {
    @Environment(LibraryModel.self) private var lib
    @Environment(PlayerEngine.self) private var engine
    let target: SidebarTarget
    @Binding var selection: Set<LibraryTrack.ID>

    private var rows: [LibraryTrack] {
        switch target {
        case .all:
            return lib.tracks(in: nil, search: lib.searchText, sort: lib.sortKey,
                              ascending: lib.sortAscending)
        case .folder(let id):
            return lib.tracks(in: id, search: lib.searchText, sort: lib.sortKey,
                              ascending: lib.sortAscending)
        case .playlist(let id):
            return lib.playlistTracks(id)
        }
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("#") { t in
                Text(t.trackNumber == 0 ? "" : "\(t.trackNumber)")
                    .foregroundStyle(.secondary)
            }.width(34)
            TableColumn("File name") { t in
                Text(URL(fileURLWithPath: t.path).lastPathComponent).lineLimit(1)
            }
            TableColumn("Title") { t in Text(t.title).lineLimit(1) }
            TableColumn("Artist") { t in Text(t.artist).lineLimit(1) }
            TableColumn("Album") { t in Text(t.album).lineLimit(1) }
            TableColumn("Time") { t in Text(timeString(t.duration)).monospacedDigit() }
                .width(64)
            TableColumn("Format") { t in
                Text(t.isDSD ? "DSD" : "\(OutputFormat.kHzLabel(t.sampleRate))k/\(t.channels)")
                    .font(.caption).foregroundStyle(.secondary)
            }.width(76)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: LibraryTrack.ID.self) { ids in
            if !ids.isEmpty {
                Button("Play Now") { play(ids) }
                Button("Add to Queue") { engine.enqueue(picked(ids)) }
                Button("Add to Playlist") { addToPlaylist(ids) }
                Divider()
                Button("Remove from Library", role: .destructive) { lib.removeTracks(ids) }
            }
        } primaryAction: { ids in
            play(ids)
        }
        .onDeleteCommand { lib.removeTracks(selection) }
    }

    private func picked(_ ids: Set<LibraryTrack.ID>) -> [QueueItem] {
        rows.filter { ids.contains($0.id) }.map { $0.queueItem() }
    }

    private func play(_ ids: Set<LibraryTrack.ID>) {
        let chosen = rows.filter { ids.contains($0.id) }
        guard let first = chosen.first else { return }
        let start = rows.firstIndex(where: { $0.id == first.id }) ?? 0
        engine.load(rows.map { $0.queueItem() }, startAt: start, autoplay: true)
    }

    private func addToPlaylist(_ ids: Set<LibraryTrack.ID>) {
        let paths = rows.filter { ids.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        let id = lib.playlists.first?.id ?? lib.createPlaylist(name: "New Playlist").id
        lib.addToPlaylist(id, paths: paths)
    }
}

// MARK: - Queue panel

struct QueuePanel: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queue").font(.headline)
                Text("\(engine.queue.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { engine.clearQueue() }.buttonStyle(.link)
            }
            .padding(10)
            Divider()
            List {
                ForEach(Array(engine.queue.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 8) {
                        Image(systemName: i == engine.queueIndex
                              ? "speaker.wave.2.fill" : "music.note")
                            .foregroundStyle(i == engine.queueIndex
                                             ? Color.accentColor : Color.secondary)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1).font(.callout)
                            Text(item.artist.isEmpty ? item.url.lastPathComponent : item.artist)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(timeString(item.duration))
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { engine.jump(to: i) }
                    .listRowBackground(i == engine.queueIndex
                                       ? Color.accentColor.opacity(0.12) : Color.clear)
                }
                .onDelete { engine.removeQueue(at: $0) }
            }
            .listStyle(.plain)
        }
    }
}
