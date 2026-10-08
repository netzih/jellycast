import SwiftUI

/// Anything in the library that can become a list of tracks. Albums and artists
/// only know their track lists after a round trip, so every action that needs
/// them — queue, playlist — goes through here rather than fetching at each menu.
enum TrackSource {
    case tracks([JFItem])
    case album(JFItem)
    case artist(JFItem)

    /// The one library item this stands for, when there is one — what a heart
    /// or an Instant Mix acts on. A batch of tracks has no single identity.
    var item: JFItem? {
        switch self {
        case .album(let album): return album
        case .artist(let artist): return artist
        case .tracks(let items): return items.count == 1 ? items[0] : nil
        }
    }

    func resolve(using client: JellyfinClient) async -> [JFItem] {
        switch self {
        case .tracks(let items):
            return items
        case .album(let album):
            return (try? await client.tracks(inParent: album.id)) ?? []
        case .artist(let artist):
            return (try? await client.tracks(byArtist: artist.id)) ?? []
        }
    }
}

/// A pending "add to playlist", held by whichever screen presents the sheet.
/// `id` is fresh each time so tapping the same album twice re-opens the sheet.
struct PlaylistTarget: Identifiable {
    let id = UUID()
    let source: TrackSource
    let title: String
}

// MARK: - The shared long-press menu

private struct TrackActionsModifier: ViewModifier {
    let source: TrackSource
    let title: String
    @Binding var target: PlaylistTarget?

    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                withTracks { appState.player.playNext(items: $0) }
            } label: {
                Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                withTracks { appState.player.addToQueue(items: $0) }
            } label: {
                Label("Add to queue", systemImage: "text.append")
            }
            if let item = source.item {
                Button {
                    Task { await appState.player.playInstantMix(from: item) }
                } label: {
                    Label("Start Instant Mix", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            Divider()
            if let item = source.item {
                let favorite = appState.isFavorite(item)
                Button {
                    appState.toggleFavorite(item)
                } label: {
                    Label(favorite ? "Remove from favorites" : "Favorite",
                          systemImage: favorite ? "heart.slash" : "heart")
                }
            }
            Button {
                target = PlaylistTarget(source: source, title: title)
            } label: {
                Label("Add to playlist…", systemImage: "music.note.list")
            }
            Divider()
            if let item = source.item, item.type == "Audio",
               DownloadStore.shared.state(for: item.id) == .downloaded {
                Button(role: .destructive) {
                    DownloadStore.shared.remove([item.id])
                } label: {
                    Label("Remove download", systemImage: "trash")
                }
            } else {
                Button {
                    withTracks { DownloadStore.shared.download($0) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private func withTracks(_ apply: @escaping ([JFItem]) -> Void) {
        guard let client = appState.client else { return }
        Task {
            let tracks = await source.resolve(using: client)
            guard !tracks.isEmpty else { return }
            await MainActor.run { apply(tracks) }
        }
    }
}

extension View {
    /// Long-press actions: play next, add to queue, Instant Mix, favorite, add to playlist.
    func trackActions(
        _ source: TrackSource,
        title: String,
        addingTo target: Binding<PlaylistTarget?>
    ) -> some View {
        modifier(TrackActionsModifier(source: source, title: title, target: target))
    }

    /// Presents the playlist picker for whatever `target` holds.
    func addToPlaylistSheet(_ target: Binding<PlaylistTarget?>) -> some View {
        sheet(item: target) { pending in
            AddToPlaylistSheet(target: pending)
        }
    }
}

// MARK: - Picking (or creating) the destination playlist

struct AddToPlaylistSheet: View {
    let target: PlaylistTarget

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [JFItem] = []
    @State private var trackIds: [String] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = suggestedName
                        isNaming = true
                    } label: {
                        Label("New playlist…", systemImage: "plus.circle.fill")
                    }
                    .disabled(isLoading || isSaving)
                }

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                } else if playlists.isEmpty {
                    EmptyStateView(
                        icon: "music.note.list",
                        title: "No playlists yet",
                        message: "Create one above and “\(target.title)” goes straight into it."
                    )
                    .listRowSeparator(.hidden)
                } else {
                    Section("Add to") {
                        ForEach(playlists) { playlist in
                            Button {
                                Task { await add(to: playlist.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(url: appState.client?.artworkURL(for: playlist), cornerRadius: 4)
                                        .frame(width: 38, height: 38)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name).lineLimit(1).foregroundStyle(.primary)
                                        if let count = playlist.childCount {
                                            Text("\(count) tracks")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .disabled(isSaving)
                        }
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(trackIds.isEmpty ? target.title : "\(trackIds.count) track\(trackIds.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                if isSaving {
                    ToolbarItem(placement: .topBarTrailing) { ProgressView() }
                }
            }
            .alert("New playlist", isPresented: $isNaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await createAndAdd() } }
            } message: {
                Text("“\(target.title)” will be added to it.")
            }
        }
        .task { await load() }
    }

    /// Falls back to the source's own name, which is usually what you want for
    /// "make a playlist out of this album".
    private var suggestedName: String { target.title }

    private func load() async {
        guard let client = appState.client else { return }
        async let lists = try? await client.playlists()
        async let resolved = target.source.resolve(using: client)

        let loadedPlaylists = await lists
        let loadedTracks = await resolved
        playlists = loadedPlaylists ?? []
        trackIds = loadedTracks.map(\.id)
        isLoading = false
    }

    private func add(to playlistId: String) async {
        guard let client = appState.client, !trackIds.isEmpty else { return }
        isSaving = true
        errorText = nil
        do {
            try await client.addToPlaylist(playlistId: playlistId, itemIds: trackIds)
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isSaving = false
    }

    private func createAndAdd() async {
        guard let client = appState.client else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        isSaving = true
        errorText = nil
        do {
            // Jellyfin can seed a new playlist in the same call as creating it.
            _ = try await client.createPlaylist(name: name, itemIds: trackIds)
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isSaving = false
    }
}
