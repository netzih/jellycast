import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0
    @State private var showQueue = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 8)

                ArtworkView(url: player.currentTrack?.artworkURL, cornerRadius: 12)
                    .frame(maxWidth: 320)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                    .padding(.horizontal, 28)

                Spacer(minLength: 16)

                VStack(spacing: 4) {
                    Text(player.currentTrack?.title ?? "Nothing playing")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(player.currentTrack?.artist ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)

                scrubber
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

                transportControls
                    .padding(.top, 8)

                if player.route.isCast {
                    castVolume
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                }

                if player.queue.count > 1 {
                    upNextSummary
                        .padding(.top, 16)
                }

                routeBadge
                    .padding(.top, 20)

                Spacer(minLength: 12)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CastButton().frame(width: 28, height: 28)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Up next")
                }
            }
            .sheet(isPresented: $showQueue) { QueueView(player: player) }
        }
    }

    // MARK: - Pieces

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : player.position },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { player.seek(to: scrubPosition) }
                }
            )
            HStack {
                Text((isScrubbing ? scrubPosition : player.position).clockString)
                Spacer()
                Text(player.duration.clockString)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 36) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }

            Button { player.togglePlayPause() } label: {
                ZStack {
                    if player.state == .buffering {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                }
                .frame(width: 64, height: 64)
            }

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    private var castVolume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { player.volume },
                    set: { player.setVolume($0) }
                ),
                in: 0...1
            )
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    /// A peek at what follows, so the queue sheet isn't the only way to know.
    @ViewBuilder
    private var upNextSummary: some View {
        let nextIndex = player.index + 1
        Button { showQueue = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                if player.queue.indices.contains(nextIndex) {
                    Text("Up next: \(player.queue[nextIndex].title)").lineLimit(1)
                } else {
                    Text("Last track in the queue")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
    }

    private var routeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: player.route.isCast ? "hifispeaker.fill" : "iphone")
            Text(player.route.displayName)
        }
        .font(.footnote)
        .foregroundStyle(player.route.isCast ? Color.accentColor : .secondary)
    }
}
