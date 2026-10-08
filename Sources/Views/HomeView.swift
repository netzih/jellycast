import SwiftUI

/// The first tab: what you've been playing, what you love, what's new.
/// Everything here is one query away, so it's built to be reloaded freely —
/// each time the tab appears, and whenever the library picker changes.
struct HomeTab: View {
    @EnvironmentObject var appState: AppState

    @State private var recent: [JFItem] = []
    @State private var mostPlayed: [JFItem] = []
    @State private var favoriteSongs: [JFItem] = []
    @State private var favoriteAlbums: [JFItem] = []
    @State private var favoriteArtists: [JFItem] = []
    @State private var justAdded: [JFItem] = []
    @State private var isLoading = true
    @State private var showSettings = false
    @State private var playlistTarget: PlaylistTarget?

    private var isEmpty: Bool {
        recent.isEmpty && mostPlayed.isEmpty && favoriteSongs.isEmpty
            && favoriteAlbums.isEmpty && favoriteArtists.isEmpty && justAdded.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isEmpty {
                    EmptyStateView(
                        icon: "house",
                        title: "Nothing here yet",
                        message: "Play some music, or tap the heart on songs and albums you love, and they'll show up here."
                    )
                } else {
                    content
                }
            }
            .navigationTitle("Home")
            .navigationDestination(for: JFItem.self) { item in
                if item.type == "MusicArtist" {
                    ArtistDetailView(artist: item)
                } else {
                    TrackListView(container: item)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { LibraryMenu() }
                ToolbarItem(placement: .topBarTrailing) { CastButton().frame(width: 28, height: 28) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .refreshable { await load() }
            .sheet(isPresented: $showSettings) { SettingsTab().environmentObject(appState) }
            .addToPlaylistSheet($playlistTarget)
        }
        .task(id: appState.selectedLibraryId) { await load() }
        // Recently played and favorites change as you use the app elsewhere.
        .onAppear { Task { await load() } }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !favoriteSongs.isEmpty { favoriteSongsCard }
                if !recent.isEmpty {
                    shelf("Recently played") {
                        ForEach(Array(recent.enumerated()), id: \.offset) { offset, track in
                            Button {
                                appState.player.play(items: recent, startAt: offset)
                            } label: {
                                card(for: track, subtitle: track.displayArtist)
                            }
                            .buttonStyle(.plain)
                            .trackActions(.tracks([track]), title: track.name, addingTo: $playlistTarget)
                        }
                    }
                }
                if !favoriteAlbums.isEmpty {
                    shelf("Favorite albums") {
                        ForEach(favoriteAlbums) { album in
                            NavigationLink(value: album) { card(for: album, subtitle: album.displayArtist) }
                                .buttonStyle(.plain)
                                .trackActions(.album(album), title: album.name, addingTo: $playlistTarget)
                        }
                    }
                }
                if !favoriteArtists.isEmpty {
                    shelf("Favorite artists") {
                        ForEach(favoriteArtists) { artist in
                            NavigationLink(value: artist) { card(for: artist, subtitle: nil, round: true) }
                                .buttonStyle(.plain)
                                .trackActions(.artist(artist), title: artist.name, addingTo: $playlistTarget)
                        }
                    }
                }
                if !mostPlayed.isEmpty { mostPlayedList }
                if !justAdded.isEmpty {
                    shelf("Just added") {
                        ForEach(justAdded) { album in
                            NavigationLink(value: album) { card(for: album, subtitle: album.displayArtist) }
                                .buttonStyle(.plain)
                                .trackActions(.album(album), title: album.name, addingTo: $playlistTarget)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Pieces

    private var favoriteSongsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .font(.title2)
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Favorite songs").font(.headline)
                    Text("\(favoriteSongs.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    appState.player.play(items: favoriteSongs, shuffle: false)
                } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    appState.player.play(items: favoriteSongs, shuffle: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var mostPlayedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Most played")
            ForEach(Array(mostPlayed.prefix(10).enumerated()), id: \.offset) { offset, track in
                Button {
                    appState.player.play(items: Array(mostPlayed.prefix(10)), startAt: offset)
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(url: appState.client?.artworkURL(for: track), cornerRadius: 4)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.name).lineLimit(1)
                            Text(track.displayArtist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let plays = track.userData?.playCount, plays > 0 {
                            Text("\(plays) plays")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .trackActions(.tracks([track]), title: track.name, addingTo: $playlistTarget)
                .padding(.horizontal, 16)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 16)
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal, 16)
            }
        }
    }

    private func card(for item: JFItem, subtitle: String?, round: Bool = false) -> some View {
        VStack(alignment: round ? .center : .leading, spacing: 5) {
            ArtworkView(url: appState.client?.artworkURL(for: item), cornerRadius: round ? 65 : 8)
                .frame(width: 130, height: 130)
            Text(item.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 130)
        .multilineTextAlignment(round ? .center : .leading)
    }

    // MARK: - Loading

    private func load() async {
        guard let client = appState.client else { return }
        // Each shelf stands alone: one failing shouldn't blank the others.
        async let recentResult = try? client.recentlyPlayedTracks()
        async let mostResult = try? client.mostPlayedTracks()
        async let songsResult = try? client.favorites(type: "Audio")
        async let albumsResult = try? client.favorites(type: "MusicAlbum", limit: 30)
        async let artistsResult = try? client.favorites(type: "MusicArtist", limit: 30)
        async let addedResult = try? client.recentlyAddedAlbums()

        recent = await recentResult ?? []
        mostPlayed = await mostResult ?? []
        favoriteSongs = await songsResult ?? []
        favoriteAlbums = await albumsResult ?? []
        favoriteArtists = await artistsResult ?? []
        justAdded = await addedResult ?? []
        isLoading = false
    }
}
