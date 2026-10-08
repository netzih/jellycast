import SwiftUI

/// What a swipe on a song row does. Chosen per direction in Settings.
enum SwipeAction: String, CaseIterable, Identifiable {
    case none, playNext, addToQueue, favorite, download

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Nothing"
        case .playNext: return "Play next"
        case .addToQueue: return "Add to queue"
        case .favorite: return "Favorite"
        case .download: return "Download"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "nosign"
        case .playNext: return "text.line.first.and.arrowtriangle.forward"
        case .addToQueue: return "text.append"
        case .favorite: return "heart"
        case .download: return "arrow.down.circle"
        }
    }
}

private struct SongSwipeActions: ViewModifier {
    let track: JFItem
    /// Playlists add "Remove" to the left swipe — which replaces the plain
    /// swipe-to-delete `onDelete` would otherwise give.
    let onRemove: (() -> Void)?

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloads = DownloadStore.shared

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                button(for: appState.swipeRight)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: onRemove == nil) {
                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove", systemImage: "trash")
                    }
                }
                button(for: appState.swipeLeft)
            }
    }

    @ViewBuilder
    private func button(for action: SwipeAction) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .playNext:
            Button { appState.player.playNext(items: [track]) } label: {
                Label(action.label, systemImage: action.systemImage)
            }
            .tint(.indigo)
        case .addToQueue:
            Button { appState.player.addToQueue(items: [track]) } label: {
                Label(action.label, systemImage: action.systemImage)
            }
            .tint(.orange)
        case .favorite:
            let favorite = appState.isFavorite(track)
            Button { appState.toggleFavorite(track) } label: {
                Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.slash" : "heart.fill")
            }
            .tint(.pink)
        case .download:
            if downloads.state(for: track.id) == .downloaded {
                Button { downloads.remove([track.id]) } label: {
                    Label("Remove download", systemImage: "trash")
                }
                .tint(.gray)
            } else {
                Button { downloads.download([track]) } label: {
                    Label(action.label, systemImage: action.systemImage)
                }
                .tint(.blue)
            }
        }
    }
}

extension View {
    /// The swipe actions chosen in Settings, for a song row inside a `List`.
    func songSwipeActions(_ track: JFItem, onRemove: (() -> Void)? = nil) -> some View {
        modifier(SongSwipeActions(track: track, onRemove: onRemove))
    }
}
