import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player: PlayerCoordinator
    @EnvironmentObject private var appState: AppState
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

                modeControls
                    .padding(.horizontal, 24)
                    .padding(.top, 6)

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

                if player.sleepTimer != .off {
                    sleepBadge.padding(.top, 8)
                }

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
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
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
        HStack(spacing: 0) {
            transportButton("gobackward.15", label: "Back 15 seconds", font: .title2) {
                player.skip(by: -15)
            }
            transportButton("backward.fill", label: "Previous", font: .title) { player.previous() }

            Button { player.togglePlayPause() } label: {
                ZStack {
                    if player.state == .buffering {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                }
                .frame(width: 72, height: 72)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            transportButton("forward.fill", label: "Next", font: .title) { player.next() }
            transportButton("goforward.15", label: "Forward 15 seconds", font: .title2) {
                player.skip(by: 15)
            }
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private func transportButton(
        _ symbol: String, label: String, font: Font, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// Shuffle, queue and repeat — the modes, as opposed to the moment-to-moment transport.
    private var modeControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                modeIcon("shuffle", active: player.isShuffled)
            }
            .accessibilityLabel(player.isShuffled ? "Shuffle on" : "Shuffle off")

            Spacer()

            if let track = player.currentTrack {
                let favorite = appState.isFavorite(track.item)
                Button { appState.toggleFavorite(track.item) } label: {
                    Image(systemName: favorite ? "heart.fill" : "heart")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(favorite ? Color.pink : .secondary)
                        .frame(width: 40, height: 32)
                }
                .accessibilityLabel(favorite ? "Remove from favorites" : "Favorite")

                Spacer()
            }

            Button { showQueue = true } label: {
                modeIcon("list.bullet", active: false)
            }
            .accessibilityLabel("Up next")

            Spacer()

            Button { player.cycleRepeatMode() } label: {
                modeIcon(player.repeatMode.symbolName, active: player.repeatMode != .off)
            }
            .accessibilityLabel(repeatLabel)
        }
        .buttonStyle(.plain)
    }

    private func modeIcon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .frame(width: 40, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.accentColor.opacity(0.15) : .clear)
            )
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    private var moreMenu: some View {
        Menu {
            if let track = player.currentTrack {
                Button {
                    Task { await player.playInstantMix(from: track.item) }
                } label: {
                    Label("Instant Mix from this song", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            Menu {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                }
                Button("End of this track") { player.sleepAtEndOfTrack() }
                if player.sleepTimer != .off {
                    Divider()
                    Button("Turn off timer", role: .destructive) { player.cancelSleepTimer() }
                }
            } label: {
                Label("Sleep timer", systemImage: "moon.zzz")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    /// Ticks once a second while a countdown is running.
    private var sleepBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                switch player.sleepTimer {
                case .at(let deadline):
                    Text("Stopping in \(max(0, deadline.timeIntervalSince(context.date)).clockString)")
                        .monospacedDigit()
                case .endOfTrack:
                    Text("Stopping after this track")
                case .off:
                    EmptyView()
                }
                Button { player.cancelSleepTimer() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Turn off sleep timer")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
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
