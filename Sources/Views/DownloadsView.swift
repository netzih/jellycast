import SwiftUI

/// Everything kept on the phone — playable with no connection at all.
struct DownloadsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var confirmRemoveAll = false

    var body: some View {
        List {
            if !downloads.active.isEmpty {
                Section("Downloading") {
                    HStack(spacing: 12) {
                        ProgressView(value: overallProgress)
                        Text("\(downloads.active.count) left")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if downloads.downloaded.isEmpty {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "No downloads",
                    message: "Long-press an album, artist or song and choose “Download” to keep it on this iPhone for when there's no signal."
                )
                .listRowSeparator(.hidden)
            } else {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            appState.player.play(items: allTracks, shuffle: false)
                        } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            appState.player.play(items: allTracks, shuffle: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .listRowSeparator(.hidden)
                } footer: {
                    Text("\(downloads.downloaded.count) songs · \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))")
                }

                ForEach(downloads.albums) { album in
                    Section {
                        ForEach(Array(album.tracks.enumerated()), id: \.element.id) { offset, track in
                            Button {
                                appState.player.play(items: album.tracks, startAt: offset)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.name).lineLimit(1)
                                        Text(downloads.downloaded[track.id]?.formatLabel ?? "")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(track.duration.clockString)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            downloads.remove(offsets.map { album.tracks[$0].id })
                        }
                    } header: {
                        albumHeader(album)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Downloads")
        .toolbar {
            if !downloads.downloaded.isEmpty || !downloads.active.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { confirmRemoveAll = true } label: {
                            Label("Remove all downloads", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { downloads.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)). Your music stays on the server.")
        }
    }

    private var allTracks: [JFItem] { downloads.albums.flatMap(\.tracks) }

    /// Transcoded downloads report no size, so they count as half done until they land.
    private var overallProgress: Double {
        guard !downloads.active.isEmpty else { return 1 }
        return downloads.active.values.reduce(0, +) / Double(downloads.active.count)
    }

    private func albumHeader(_ album: DownloadedAlbum) -> some View {
        HStack(spacing: 10) {
            ArtworkView(
                url: album.tracks.first.flatMap { downloads.localArtworkURL(for: $0.id) },
                cornerRadius: 4
            )
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if !album.artist.isEmpty {
                    Text(album.artist).font(.caption)
                }
            }
            .textCase(nil)
            Spacer()
            Menu {
                Button {
                    appState.player.play(items: album.tracks, shuffle: false)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button(role: .destructive) {
                    downloads.remove(album.tracks.map(\.id))
                } label: {
                    Label("Remove download", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.body)
            }
        }
    }
}

/// The small status mark on a song row: a progress ring or a "downloaded" arrow.
struct DownloadBadge: View {
    let itemId: String
    @ObservedObject private var downloads = DownloadStore.shared

    var body: some View {
        switch downloads.state(for: itemId) {
        case .none:
            EmptyView()
        case .downloading(let progress):
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(progress, 0.05))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            .accessibilityLabel("Downloading")
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
        }
    }
}
