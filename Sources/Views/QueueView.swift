import SwiftUI

/// What's playing and what's coming, with reordering and removal.
///
/// Edits go through `PlayerCoordinator`, which applies them to the published
/// queue and then to whichever engine is live — so the same gestures work
/// whether the sound is coming out of the phone or a speaker across the house.
struct QueueView: View {
    @ObservedObject var player: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var editMode: EditMode = .inactive
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if player.queue.isEmpty {
                    EmptyStateView(
                        icon: "list.bullet",
                        title: "Nothing queued",
                        message: "Play an album, or long-press anything in your library and choose “Add to queue”."
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        } label: {
                            Label(
                                editMode.isEditing ? "Done reordering" : "Reorder",
                                systemImage: "arrow.up.arrow.down"
                            )
                        }
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Clear queue", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(player.queue.isEmpty)
                }
            }
            .confirmationDialog(
                "Clear the whole queue?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear queue", role: .destructive) {
                    player.clearQueue()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Playback stops and every track is removed.")
            }
        }
    }

    private var list: some View {
        List {
            modeRow
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)

            // Enumerated rather than keyed on the track: the same song can sit
            // in a queue more than once, so only its position identifies a row.
            ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, track in
                Button {
                    player.jumpToQueueItem(at: offset)
                } label: {
                    row(for: track, at: offset)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                // Highest first, so earlier removals don't shift later indices.
                for offset in offsets.sorted(by: >) {
                    player.removeFromQueue(at: offset)
                }
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                // SwiftUI's destination is an insertion point, not a final index.
                player.moveInQueue(from: from, to: from < destination ? destination - 1 : destination)
            }
        }
        .listStyle(.plain)
    }

    private var modeRow: some View {
        HStack(spacing: 12) {
            Button { player.toggleShuffle() } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .tint(player.isShuffled ? .accentColor : .secondary)

            Button { player.cycleRepeatMode() } label: {
                Label(repeatTitle, systemImage: player.repeatMode.symbolName)
                    .frame(maxWidth: .infinity)
            }
            .tint(player.repeatMode != .off ? .accentColor : .secondary)
        }
        .buttonStyle(.bordered)
        .font(.subheadline.weight(.medium))
    }

    private var repeatTitle: String {
        switch player.repeatMode {
        case .off: return "Repeat"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    private func row(for track: PlaybackTrack, at offset: Int) -> some View {
        let isCurrent = offset == player.index

        return HStack(spacing: 12) {
            ArtworkView(url: track.artworkURL, cornerRadius: 4)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(track.duration.clockString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
