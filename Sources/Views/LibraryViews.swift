import SwiftUI

enum LibraryKind {
    case albums, artists, playlists

    var title: String {
        switch self {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        }
    }
}

struct LibraryTab: View {
    let kind: LibraryKind
    @EnvironmentObject var appState: AppState

    @State private var items: [JFItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var playlistTarget: PlaylistTarget?
    @State private var isNamingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var pendingDelete: JFItem?
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't load your library",
                        message: loadError
                    )
                } else if items.isEmpty {
                    EmptyStateView(
                        icon: "music.note.list",
                        title: "Nothing here yet",
                        message: "No \(kind.title.lowercased()) found on your Jellyfin server. Check that your music library has finished scanning."
                    )
                } else {
                    content
                }
            }
            .navigationTitle(kind.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if kind == .playlists {
                        // Playlists live outside any library, so they get a
                        // "new playlist" button where the picker would be.
                        Button {
                            newPlaylistName = ""
                            isNamingPlaylist = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New playlist")
                    } else {
                        LibraryMenu()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { CastButton().frame(width: 28, height: 28) }
            }
            .refreshable { await load() }
            .addToPlaylistSheet($playlistTarget)
            .alert("New playlist", isPresented: $isNamingPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await createPlaylist() } }
            } message: {
                Text("An empty playlist you can add songs to from anywhere in the app.")
            }
            .confirmationDialog(
                "Delete “\(pendingDelete?.name ?? "")”?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete playlist", role: .destructive) {
                    if let target = pendingDelete { Task { await delete(playlist: target) } }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This removes the playlist from your Jellyfin server. The songs themselves are untouched.")
            }
            .alert("Couldn't do that", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        }
        // Re-runs when the chosen library changes, so the list follows the picker.
        .task(id: appState.selectedLibraryId) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .albums:
            ScrollView {
                // Two columns at 375pt; grows to three on wider phones.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
                    spacing: 18
                ) {
                    ForEach(items) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(url: appState.client?.artworkURL(for: album))
                                Text(album.name)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                Text(album.displayArtist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .trackActions(.album(album), title: album.name, addingTo: $playlistTarget)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationDestination(for: JFItem.self) { destination(for: $0) }

        case .artists:
            List(items) { artist in
                NavigationLink(value: artist) {
                    HStack(spacing: 12) {
                        ArtworkView(url: appState.client?.artworkURL(for: artist), cornerRadius: 22)
                            .frame(width: 44, height: 44)
                        Text(artist.name).lineLimit(1)
                    }
                }
                .trackActions(.artist(artist), title: artist.name, addingTo: $playlistTarget)
            }
            .listStyle(.plain)
            .navigationDestination(for: JFItem.self) { destination(for: $0) }

        case .playlists:
            List(items) { playlist in
                NavigationLink(value: playlist) {
                    HStack(spacing: 12) {
                        ArtworkView(url: appState.client?.artworkURL(for: playlist), cornerRadius: 4)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name).lineLimit(1)
                            if let count = playlist.childCount {
                                Text("\(count) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { pendingDelete = playlist } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: JFItem.self) { destination(for: $0) }
        }
    }

    @ViewBuilder
    private func destination(for item: JFItem) -> some View {
        if kind == .artists {
            ArtistDetailView(artist: item)
        } else {
            TrackListView(container: item)
        }
    }

    private func createPlaylist() async {
        guard let client = appState.client else { return }
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try await client.createPlaylist(name: name)
            await load()
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(playlist: JFItem) async {
        guard let client = appState.client else { return }
        pendingDelete = nil
        do {
            try await client.deletePlaylist(playlistId: playlist.id)
            await load()
        } catch {
            // Jellyfin refuses unless the account is allowed to delete media.
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func load() async {
        guard let client = appState.client else { return }
        loadError = nil
        do {
            switch kind {
            case .albums: items = try await client.albums()
            case .artists: items = try await client.artists()
            case .playlists: items = try await client.playlists()
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

/// Track listing for an album or a playlist.
///
/// Playlists are editable here: their tracks come from `/Playlists/{id}/Items`,
/// the only endpoint that returns the `PlaylistItemId` that removing and
/// reordering need.
struct TrackListView: View {
    let container: JFItem
    @EnvironmentObject var appState: AppState

    @State private var tracks: [JFItem] = []
    @State private var isLoading = true
    @State private var playlistTarget: PlaylistTarget?
    @State private var editMode: EditMode = .inactive
    @State private var actionError: String?

    private var isPlaylist: Bool { container.type == "Playlist" }

    var body: some View {
        List {
            header

            if isLoading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            } else if tracks.isEmpty {
                EmptyStateView(
                    icon: "music.note",
                    title: "No tracks",
                    message: isPlaylist
                        ? "This playlist is empty. Long-press an album or song anywhere in the app and choose “Add to playlist”."
                        : "This album is empty on the server."
                )
                .listRowSeparator(.hidden)
            } else {
                Section { trackRows }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isPlaylist && !tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            ToolbarItem(placement: .topBarTrailing) { CastButton().frame(width: 28, height: 28) }
        }
        .addToPlaylistSheet($playlistTarget)
        .alert("Couldn't update the playlist", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
    }

    // MARK: - Pieces

    private var header: some View {
        Section {
            VStack(spacing: 14) {
                ArtworkView(url: appState.client?.artworkURL(for: container, maxHeight: 900), cornerRadius: 10)
                    .frame(maxWidth: 240)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

                VStack(spacing: 3) {
                    Text(container.name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if !container.displayArtist.isEmpty {
                        Text(container.displayArtist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        appState.player.play(items: tracks, shuffle: false)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        appState.player.play(items: tracks, shuffle: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Menu {
                        Button {
                            appState.player.playNext(items: tracks)
                        } label: {
                            Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button {
                            appState.player.addToQueue(items: tracks)
                        } label: {
                            Label("Add to queue", systemImage: "text.append")
                        }
                        Divider()
                        Button {
                            playlistTarget = PlaylistTarget(source: .tracks(tracks), title: container.name)
                        } label: {
                            Label("Add to playlist…", systemImage: "music.note.list")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(height: 30)
                    }
                }
                .disabled(tracks.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    @ViewBuilder
    private var trackRows: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.rowId) { offset, track in
            Button {
                appState.player.play(items: tracks, startAt: offset)
            } label: {
                HStack(spacing: 12) {
                    Text("\(isPlaylist ? offset + 1 : (track.indexNumber ?? offset + 1))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if isPlaylist, !track.displayArtist.isEmpty {
                            Text(track.displayArtist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if appState.isFavorite(track) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                            .accessibilityLabel("Favorite")
                    }
                    Text(track.duration.clockString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .trackActions(.tracks([track]), title: track.name, addingTo: $playlistTarget)
        }
        .onDelete(perform: isPlaylist ? removeFromPlaylist : nil)
        .onMove(perform: isPlaylist ? moveWithinPlaylist : nil)
    }

    // MARK: - Server round trips

    private func load() async {
        guard let client = appState.client else { return }
        if isPlaylist {
            tracks = (try? await client.playlistTracks(playlistId: container.id)) ?? []
        } else {
            tracks = (try? await client.tracks(inParent: container.id)) ?? []
        }
        isLoading = false
    }

    /// Optimistic: the row disappears immediately and comes back if the server
    /// refuses, which beats staring at a spinner for a one-row edit.
    private func removeFromPlaylist(_ offsets: IndexSet) {
        guard let client = appState.client else { return }
        let entryIds = offsets.compactMap { tracks[$0].playlistItemId }
        let previous = tracks
        tracks.remove(atOffsets: offsets)

        Task {
            do {
                try await client.removeFromPlaylist(playlistId: container.id, entryIds: entryIds)
            } catch {
                tracks = previous
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func moveWithinPlaylist(_ source: IndexSet, _ destination: Int) {
        guard let client = appState.client, let from = source.first else { return }
        let previous = tracks
        tracks.move(fromOffsets: source, toOffset: destination)

        // Jellyfin wants the final index, SwiftUI hands over an insertion point.
        let to = from < destination ? destination - 1 : destination
        guard let entryId = previous[from].playlistItemId else { return }

        Task {
            do {
                try await client.movePlaylistItem(playlistId: container.id, entryId: entryId, to: to)
            } catch {
                tracks = previous
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct ArtistDetailView: View {
    let artist: JFItem
    @EnvironmentObject var appState: AppState

    @State private var albums: [JFItem] = []
    @State private var isLoading = true
    @State private var playlistTarget: PlaylistTarget?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Button {
                        Task {
                            guard let client = appState.client else { return }
                            let tracks = (try? await client.tracks(byArtist: artist.id)) ?? []
                            appState.player.play(items: tracks, shuffle: true)
                        }
                    } label: {
                        Label("Shuffle everything", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Menu {
                        Button {
                            withArtistTracks { appState.player.playNext(items: $0) }
                        } label: {
                            Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button {
                            withArtistTracks { appState.player.addToQueue(items: $0) }
                        } label: {
                            Label("Add to queue", systemImage: "text.append")
                        }
                        Divider()
                        Button {
                            playlistTarget = PlaylistTarget(source: .artist(artist), title: artist.name)
                        } label: {
                            Label("Add to playlist…", systemImage: "music.note.list")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(height: 30)
                    }
                }
                .padding(.horizontal, 16)

                if isLoading {
                    ProgressView().padding(.top, 40)
                } else if albums.isEmpty {
                    EmptyStateView(
                        icon: "square.stack",
                        title: "No albums",
                        message: "Nothing by \(artist.name) was found on the server."
                    )
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
                        spacing: 18
                    ) {
                        ForEach(albums) { album in
                            NavigationLink { TrackListView(container: album) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ArtworkView(url: appState.client?.artworkURL(for: album))
                                    Text(album.name)
                                        .font(.footnote.weight(.medium))
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                    if let year = album.productionYear {
                                        Text(String(year))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                            .trackActions(.album(album), title: album.name, addingTo: $playlistTarget)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .addToPlaylistSheet($playlistTarget)
        .task {
            guard let client = appState.client else { return }
            albums = (try? await client.albums(forArtist: artist.id)) ?? []
            isLoading = false
        }
    }

    private func withArtistTracks(_ apply: @escaping ([JFItem]) -> Void) {
        guard let client = appState.client else { return }
        Task {
            let tracks = (try? await client.tracks(byArtist: artist.id)) ?? []
            guard !tracks.isEmpty else { return }
            apply(tracks)
        }
    }
}

struct SearchTab: View {
    @EnvironmentObject var appState: AppState

    @State private var term = ""
    @State private var artists: [JFItem] = []
    @State private var albums: [JFItem] = []
    @State private var tracks: [JFItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var playlistTarget: PlaylistTarget?

    private var hasResults: Bool { !artists.isEmpty || !albums.isEmpty || !tracks.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                artistSection
                albumSection
                trackSection

                if !term.isEmpty && !hasResults {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No matches",
                        message: "Nothing in your library matches \u{201C}\(term)\u{201D}."
                    )
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { LibraryMenu() }
                ToolbarItem(placement: .topBarTrailing) { CastButton().frame(width: 28, height: 28) }
            }
            .addToPlaylistSheet($playlistTarget)
            .searchable(text: $term, prompt: "Artists, albums, songs")
            .onChange(of: term) { _, _ in runSearch() }
            // Switching library from the toolbar re-scopes what's on screen now.
            .onChange(of: appState.selectedLibraryId) { _, _ in runSearch() }
        }
    }

    @ViewBuilder
    private var artistSection: some View {
        if !artists.isEmpty {
            Section("Artists") {
                ForEach(artists) { artist in
                    NavigationLink(artist.name) { ArtistDetailView(artist: artist) }
                        .trackActions(.artist(artist), title: artist.name, addingTo: $playlistTarget)
                }
            }
        }
    }

    @ViewBuilder
    private var albumSection: some View {
        if !albums.isEmpty {
            Section("Albums") {
                ForEach(albums) { album in
                    NavigationLink {
                        TrackListView(container: album)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.name).lineLimit(1)
                            Text(album.displayArtist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .trackActions(.album(album), title: album.name, addingTo: $playlistTarget)
                }
            }
        }
    }

    @ViewBuilder
    private var trackSection: some View {
        if !tracks.isEmpty {
            Section("Tracks") {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                    Button {
                        appState.player.play(items: tracks, startAt: offset)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.name).lineLimit(1).foregroundStyle(.primary)
                            Text(track.displayArtist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .trackActions(.tracks([track]), title: track.name, addingTo: $playlistTarget)
                }
            }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        guard term.count >= 2, let client = appState.client else {
            artists = []
            albums = []
            tracks = []
            return
        }
        let query = term
        // Debounce so a fast typist doesn't hammer the server.
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if let results = try? await client.search(query), !Task.isCancelled {
                artists = results.artists
                albums = results.albums
                tracks = results.tracks
            }
        }
    }
}
