import Foundation

/// One track, resolved to everything needed to play it on either output.
struct PlaybackTrack: Identifiable, Equatable {
    let item: JFItem
    let streamURL: URL
    let contentType: String
    let artworkURL: URL?
    /// "Downloaded · FLAC", "Streaming · MP3 192" — for the quality badge.
    let sourceLabel: String
    /// Identifies this queue entry, not the song — the same song can be queued
    /// twice, and shuffle has to put each copy back where it came from. A
    /// `var` so a track rebuilt for another output keeps its identity.
    var entryId = UUID()

    var id: String { item.id }
    var title: String { item.name }
    var artist: String { item.displayArtist }
    var album: String { item.album ?? "" }
    var duration: TimeInterval { item.duration }

    /// Volume multiplier that brings this track to the server's loudness
    /// target. Turn-down only: AVPlayer and Cast both cap volume at 1.0, so a
    /// quiet track simply plays at full volume.
    var levellingVolume: Float {
        guard let gain = item.normalizationGain, gain.isFinite else { return 1 }
        return Float(min(1, pow(10, gain / 20)))
    }

    static func == (lhs: PlaybackTrack, rhs: PlaybackTrack) -> Bool { lhs.id == rhs.id }
}

enum PlayerState: Equatable {
    case idle
    case buffering
    case playing
    case paused

    var isActive: Bool { self != .idle }
}

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one

    /// The order the repeat button steps through.
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbolName: String { self == .one ? "repeat.1" : "repeat" }
}

/// Where audio comes out.
enum OutputRoute: Equatable {
    /// This iPhone — speaker, headphones, Bluetooth, or CarPlay.
    case thisDevice
    /// A Google Home / Nest / Chromecast device on the network.
    case cast(deviceName: String)

    var displayName: String {
        switch self {
        case .thisDevice: return "This iPhone"
        case .cast(let name): return name
        }
    }

    var isCast: Bool {
        if case .cast = self { return true }
        return false
    }
}

/// Events an engine pushes back up to the coordinator.
protocol PlaybackEngineDelegate: AnyObject {
    func engine(_ engine: PlaybackEngine, didChangeState state: PlayerState)
    func engine(_ engine: PlaybackEngine, didChangeIndex index: Int)
    func engine(_ engine: PlaybackEngine, didChangePosition position: TimeInterval, duration: TimeInterval)
    func engineDidFinishQueue(_ engine: PlaybackEngine)
    func engine(_ engine: PlaybackEngine, didFail message: String)
}

/// Cast and local playback present the same surface so the UI never branches.
protocol PlaybackEngine: AnyObject {
    var delegate: PlaybackEngineDelegate? { get set }

    func load(queue: [PlaybackTrack], startIndex: Int)
    func play()
    func pause()
    func next()
    func previous()
    func seek(to position: TimeInterval)
    func setVolume(_ volume: Float)
    func stop()
    /// Applies from the next track change on; the coordinator owns the mode.
    func setRepeatMode(_ mode: RepeatMode)
    /// Volume levelling on or off; takes effect on the playing track at once.
    func setLevelling(_ enabled: Bool)

    // MARK: Queue editing
    //
    // Indices are positions in the queue the coordinator published. The
    // coordinator applies its own change first, so an engine only has to make
    // the playing audio agree with it — it never reports the edit back.

    /// Inserts before `index`; `index == count` appends.
    func insert(_ tracks: [PlaybackTrack], at index: Int)
    func remove(at index: Int)
    func move(from oldIndex: Int, to newIndex: Int)
    /// Starts the track at `index` from the beginning.
    func jump(to index: Int)
    /// Swaps in a reordered copy of the same queue (shuffle on or off). The
    /// track at `index` is the one already playing, and it keeps playing.
    func reorder(_ queue: [PlaybackTrack], index: Int)
}
