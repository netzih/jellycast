import Foundation
import Combine
import GoogleCast

/// Owns the Jellyfin session and is the single source of truth the UI —
/// both the iPhone app and the CarPlay scene — reads from.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var client: JellyfinClient?
    @Published var streamQuality: StreamQuality {
        didSet { UserDefaults.standard.set(streamQuality.rawValue, forKey: Self.qualityKey) }
    }

    /// The music folders the server offers — "Music" and "Story tapes" are two
    /// libraries, and mixing them into one list makes both harder to browse.
    @Published private(set) var libraries: [JFItem] = []
    /// `nil` means "everything"; otherwise the id of the chosen media folder.
    @Published var selectedLibraryId: String? {
        didSet {
            guard selectedLibraryId != oldValue else { return }
            UserDefaults.standard.set(selectedLibraryId, forKey: Self.libraryKey)
            client?.libraryId = selectedLibraryId
        }
    }

    let player = PlayerCoordinator()

    private static let sessionKey = "jellyfinSession"
    private static let qualityKey = "JellyCast.streamQuality"
    private static let libraryKey = "JellyCast.selectedLibraryId"

    /// Name of the current library, for the picker and the browse screens' titles.
    var selectedLibraryName: String? {
        guard let selectedLibraryId else { return nil }
        return libraries.first { $0.id == selectedLibraryId }?.name
    }

    var isSignedIn: Bool { client != nil }
    var userName: String { client?.session.userName ?? "" }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.qualityKey) ?? StreamQuality.original.rawValue
        streamQuality = StreamQuality(rawValue: raw) ?? .original

        selectedLibraryId = UserDefaults.standard.string(forKey: Self.libraryKey)

        if let data = Keychain.load(account: Self.sessionKey),
           let session = try? JSONDecoder().decode(JellyfinSession.self, from: data) {
            let client = JellyfinClient(session: session)
            client.libraryId = selectedLibraryId
            self.client = client
            player.attach(client: client, appState: self)
            Task { await loadLibraries() }
        }
    }

    /// Refreshes the library list and drops a stale selection — a folder can be
    /// renamed or removed on the server between launches.
    func loadLibraries() async {
        guard let client else { return }
        guard let found = try? await client.musicLibraries() else { return }
        libraries = found
        if let selectedLibraryId, !found.contains(where: { $0.id == selectedLibraryId }) {
            self.selectedLibraryId = nil
        }
    }

    func signIn(server: String, username: String, password: String) async throws {
        let session = try await JellyfinClient.logIn(server: server, username: username, password: password)
        if let data = try? JSONEncoder().encode(session) {
            Keychain.save(data, account: Self.sessionKey)
        }
        let client = JellyfinClient(session: session)
        client.libraryId = selectedLibraryId
        self.client = client
        player.attach(client: client, appState: self)
        await loadLibraries()
    }

    func signOut() {
        player.shutdown()
        Keychain.delete(account: Self.sessionKey)
        client = nil
        libraries = []
    }
}

/// Drives whichever engine is currently selected and mirrors its state for SwiftUI.
@MainActor
final class PlayerCoordinator: NSObject, ObservableObject {
    @Published private(set) var route: OutputRoute = .thisDevice
    @Published private(set) var state: PlayerState = .idle
    @Published private(set) var queue: [PlaybackTrack] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var volume: Float = 0.5
    @Published var errorMessage: String?

    /// Set when a Cast session is live, regardless of which route is selected.
    @Published private(set) var availableCastDevice: String?

    private let localPlayer = LocalPlayer()
    private let castEngine = CastEngine()

    private weak var client: JellyfinClient?
    private weak var appState: AppState?

    private var playSessionId = UUID().uuidString
    private var reportedItemId: String?
    private var lastProgressReport = Date.distantPast

    var currentTrack: PlaybackTrack? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var isPlaying: Bool { state == .playing }

    private var engine: PlaybackEngine {
        route.isCast ? castEngine : localPlayer
    }

    override init() {
        super.init()
        localPlayer.delegate = self
        castEngine.delegate = self

        castEngine.onConnectionChange = { [weak self] deviceName in
            Task { @MainActor in self?.castConnectionChanged(to: deviceName) }
        }
    }

    func attach(client: JellyfinClient, appState: AppState) {
        self.client = client
        self.appState = appState
    }

    // MARK: - Route

    /// A speaker appearing (or vanishing) moves playback automatically —
    /// connecting to a speaker is an unambiguous "play it over there".
    private func castConnectionChanged(to deviceName: String?) {
        availableCastDevice = deviceName
        if let deviceName {
            switchTo(.cast(deviceName: deviceName))
        } else if route.isCast {
            switchTo(.thisDevice, autoPlay: false)
        }
    }

    /// - Parameter autoPlay: pass `false` to hand the queue over without
    ///   starting it. Used when a speaker drops off, so audio never suddenly
    ///   bursts out of the phone.
    func switchTo(_ newRoute: OutputRoute, autoPlay: Bool = true) {
        guard newRoute != route else { return }

        let resumeQueue = queue
        let resumeIndex = index
        let resumePosition = position
        let wasPlaying = isPlaying

        engine.stop()
        route = newRoute

        guard !resumeQueue.isEmpty else { return }

        // Hand the queue over and land back on the same spot.
        engine.load(queue: resumeQueue, startIndex: resumeIndex)
        queue = resumeQueue
        index = resumeIndex
        if resumePosition > 2 {
            let target = resumePosition
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.engine.seek(to: target)
            }
        }
        if !wasPlaying || !autoPlay { engine.pause() }
    }

    // MARK: - Transport

    /// Resolves library items into everything an engine needs to play them.
    private func makeTracks(_ items: [JFItem]) -> [PlaybackTrack] {
        guard let client, let appState else { return [] }
        let quality = appState.streamQuality
        return items.map { item in
            let stream = client.streamInfo(for: item, quality: quality)
            return PlaybackTrack(
                item: item,
                streamURL: stream.url,
                contentType: stream.contentType,
                artworkURL: client.artworkURL(for: item)
            )
        }
    }

    func play(items: [JFItem], startAt startIndex: Int = 0) {
        let tracks = makeTracks(items)
        guard !tracks.isEmpty else { return }

        playSessionId = UUID().uuidString
        queue = tracks
        index = max(0, min(startIndex, tracks.count - 1))
        position = 0
        duration = tracks[index].duration
        engine.load(queue: tracks, startIndex: index)
    }

    // MARK: - Queue editing
    //
    // The published queue is the source of truth the UI renders, so it changes
    // first; the engine is then told to make the audio agree. Engines apply the
    // same index arithmetic, which keeps the two arrays aligned.

    /// Drops the given items in right after whatever is playing.
    func playNext(items: [JFItem]) {
        insert(items, at: queue.isEmpty ? 0 : index + 1)
    }

    func addToQueue(items: [JFItem]) {
        insert(items, at: queue.count)
    }

    private func insert(_ items: [JFItem], at insertIndex: Int) {
        let tracks = makeTracks(items)
        guard !tracks.isEmpty else { return }

        // Nothing playing yet, so there's no queue to add to — just start.
        guard !queue.isEmpty else {
            play(items: items)
            return
        }

        let target = max(0, min(insertIndex, queue.count))
        queue.insert(contentsOf: tracks, at: target)
        if target <= index { index += tracks.count }
        engine.insert(tracks, at: target)
    }

    func removeFromQueue(at removeIndex: Int) {
        guard queue.indices.contains(removeIndex) else { return }
        let wasCurrent = removeIndex == index

        queue.remove(at: removeIndex)
        engine.remove(at: removeIndex)

        if queue.isEmpty {
            index = 0
            position = 0
            duration = 0
            return
        }
        if removeIndex < index {
            index -= 1
        } else if wasCurrent {
            // The next track slid into this slot and is now playing — unless
            // the removed one was last, in which case playback just ends and
            // the remaining queue stays put for the play button to resume.
            index = min(index, queue.count - 1)
            position = 0
            duration = currentTrack?.duration ?? 0
        }
    }

    func moveInQueue(from oldIndex: Int, to newIndex: Int) {
        guard queue.indices.contains(oldIndex) else { return }
        let target = max(0, min(newIndex, queue.count - 1))
        guard target != oldIndex else { return }

        let track = queue.remove(at: oldIndex)
        queue.insert(track, at: target)

        if oldIndex == index {
            index = target
        } else if oldIndex < index && target >= index {
            index -= 1
        } else if oldIndex > index && target <= index {
            index += 1
        }
        engine.move(from: oldIndex, to: target)
    }

    /// Tapping a row in the queue plays that track.
    func jumpToQueueItem(at newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        position = 0
        duration = currentTrack?.duration ?? 0
        if state == .idle {
            reloadEngineQueue()
        } else {
            engine.jump(to: newIndex)
        }
    }

    /// Hands the published queue back to the engine. Needed because an engine
    /// lets go of its copy when playback ends, so nothing is left to resume.
    private func reloadEngineQueue() {
        guard !queue.isEmpty else { return }
        playSessionId = UUID().uuidString
        engine.load(queue: queue, startIndex: index)
    }

    func clearQueue() {
        engine.stop()
        queue = []
        index = 0
        position = 0
        duration = 0
        state = .idle
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying {
            engine.pause()
        } else if state == .idle {
            reloadEngineQueue()
        } else {
            engine.play()
        }
    }

    func next() { engine.next() }
    func previous() { engine.previous() }

    func seek(to newPosition: TimeInterval) {
        position = newPosition
        engine.seek(to: newPosition)
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        engine.setVolume(newVolume)
    }

    func disconnectCast() {
        castEngine.disconnect()
    }

    func shutdown() {
        engine.stop()
        queue = []
        index = 0
        state = .idle
    }

    // MARK: - Jellyfin playback reporting

    private func reportStartIfNeeded() {
        guard let client, let track = currentTrack else { return }
        if reportedItemId == track.id { return }

        if let previous = reportedItemId {
            let stoppedAt = position
            Task { await client.reportPlaybackStopped(itemId: previous, sessionId: playSessionId, position: stoppedAt) }
        }
        reportedItemId = track.id
        let sessionId = playSessionId
        Task { await client.reportPlaybackStart(itemId: track.id, sessionId: sessionId) }
    }

    private func reportProgressIfDue() {
        guard let client, let itemId = reportedItemId else { return }
        guard Date().timeIntervalSince(lastProgressReport) >= 10 else { return }
        lastProgressReport = Date()
        let snapshot = (position: position, paused: !isPlaying, sessionId: playSessionId)
        Task {
            await client.reportPlaybackProgress(
                itemId: itemId, sessionId: snapshot.sessionId,
                position: snapshot.position, isPaused: snapshot.paused
            )
        }
    }

    private func reportStopped() {
        guard let client, let itemId = reportedItemId else { return }
        let stoppedAt = position
        let sessionId = playSessionId
        reportedItemId = nil
        Task { await client.reportPlaybackStopped(itemId: itemId, sessionId: sessionId, position: stoppedAt) }
    }
}

// MARK: - Engine callbacks

extension PlayerCoordinator: PlaybackEngineDelegate {
    nonisolated func engine(_ engine: PlaybackEngine, didChangeState state: PlayerState) {
        Task { @MainActor in
            self.state = state
            if state == .idle { self.reportStopped() } else { self.reportStartIfNeeded() }
        }
    }

    nonisolated func engine(_ engine: PlaybackEngine, didChangeIndex index: Int) {
        Task { @MainActor in
            self.index = index
            self.position = 0
            self.duration = self.currentTrack?.duration ?? 0
            self.reportStartIfNeeded()
        }
    }

    nonisolated func engine(_ engine: PlaybackEngine, didChangePosition position: TimeInterval, duration: TimeInterval) {
        Task { @MainActor in
            self.position = position
            if duration > 0 { self.duration = duration }
            self.reportProgressIfDue()
        }
    }

    nonisolated func engineDidFinishQueue(_ engine: PlaybackEngine) {
        Task { @MainActor in
            self.reportStopped()
            self.state = .idle
        }
    }

    nonisolated func engine(_ engine: PlaybackEngine, didFail message: String) {
        Task { @MainActor in self.errorMessage = message }
    }
}
