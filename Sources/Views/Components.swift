import SwiftUI
import GoogleCast

/// Album art with a graceful placeholder — a lot of libraries have gaps.
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 6

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Google's own Cast button — device discovery, the picker and the
/// connect/disconnect flow all come from the SDK.
struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = .label
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {}
}

/// Switches which media folder the browse tabs show — a server that keeps
/// music and story tapes apart shouldn't have them shuffled together here.
/// Hidden when there's only one library, since then there's nothing to pick.
struct LibraryMenu: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.libraries.count > 1 {
            Menu {
                Picker("Library", selection: $appState.selectedLibraryId) {
                    Text("All libraries").tag(String?.none)
                    ForEach(appState.libraries) { library in
                        Text(library.name).tag(String?.some(library.id))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "books.vertical")
                    Text(appState.selectedLibraryName ?? "All")
                        .lineLimit(1)
                }
                .font(.subheadline)
            }
        }
    }
}

/// Persistent bar above the tab bar. Tapping opens the full player.
struct MiniPlayer: View {
    @ObservedObject var player: PlayerCoordinator
    @State private var showFullPlayer = false

    var body: some View {
        if let track = player.currentTrack {
            Button {
                showFullPlayer = true
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(url: track.artworkURL, cornerRadius: 4)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                        Text(routeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .sheet(isPresented: $showFullPlayer) {
                NowPlayingView(player: player)
                    .environmentObject(AppState.shared)
            }
        }
    }

    private var routeLabel: String {
        let artist = player.currentTrack?.artist ?? ""
        switch player.route {
        case .thisDevice:
            return artist
        case .cast(let name):
            return artist.isEmpty ? "On \(name)" : "\(artist) · on \(name)"
        }
    }
}

/// Explicit control over where audio goes, so the two use cases never fight:
/// Cast for the speaker at home, this iPhone for the car.
struct RoutePicker: View {
    @ObservedObject var player: PlayerCoordinator

    var body: some View {
        Section {
            Button {
                player.switchTo(.thisDevice)
            } label: {
                routeRow(
                    icon: "iphone",
                    title: "This iPhone",
                    subtitle: "Headphones, Bluetooth, or CarPlay in the car",
                    selected: !player.route.isCast
                )
            }

            if let device = player.availableCastDevice {
                Button {
                    player.switchTo(.cast(deviceName: device))
                } label: {
                    routeRow(
                        icon: "hifispeaker.fill",
                        title: device,
                        subtitle: "Google Cast — the speaker streams directly from Jellyfin",
                        selected: player.route.isCast
                    )
                }

                Button("Disconnect from \(device)", role: .destructive) {
                    player.disconnectCast()
                }
            }
        } header: {
            Text("Play audio on")
        } footer: {
            if player.availableCastDevice == nil {
                Text("Tap the Cast icon at the top of the screen to connect a Google Home or Chromecast speaker.")
            }
        }
    }

    private func routeRow(icon: String, title: String, subtitle: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

/// Shared empty-state treatment; every list explains what to do next.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
    }
}

extension TimeInterval {
    /// m:ss, or h:mm:ss for anything over an hour.
    var clockString: String {
        guard isFinite, self > 0 else { return "0:00" }
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
