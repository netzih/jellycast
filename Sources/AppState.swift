import Foundation
import Combine
import GoogleCast
import MediaPlayer

/// Owns the Jellyfin session and is the single source of truth the UI —
/// both the iPhone app and the CarPlay scene — reads from.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var client: JellyfinClient?
    @Published var streamQuality: StreamQuality {
        didSet { UserDefaults.standard.set(streamQuality.rawValue, forKey: Self.qualityKey) }
    }
    /// Used instead of `streamQuality` when playing on this phone over mobile data.
    @Published var cellularQuality: StreamQuality {
        didSet { UserDefaults.standard.set(cellularQuality.rawValue, forKey: Self.cellularQualityKey) }
    }
    @Published var downloadQuality: StreamQuality {
        didSet { UserDefaults.standard.set(downloadQuality.rawValue, forKey: Self.downloadQualityKey) }
    }
    /// Evens out loudness between tracks using Jellyfin's normalization gain.
    @Published var volumeLevelling: Bool {
        didSet {
            UserDefaults.standard.set(volumeLevelling, forKey: Self.levellingKey)
            player.setLevelling(volumeLevelling)
        }
    }

    @Published var albumSort: LibrarySort {
        didSet { UserDefaults.standard.set(albumSort.rawValue, forKey: Self.albumSortKey) }
    }
    @Published var artistSort: LibrarySort {
        didSet { UserDefaults.standard.set(artistSort.rawValue, forKey: Self.artistSortKey) }
    }
    /// Albums narrowed to one genre, or `nil` for all. Not remembered across
    /// launches: a forgotten filter would look like missing music.
    @Published var albumGenreId: String?

    /// What swiping a song row does, each way.
    @Published var swipeRight: SwipeAction {
        didSet { UserDefaults.standard.set(swipeRight.rawValue, forKey: Self.swipeRightKey) }
    }
    @Published var swipeLeft: SwipeAction {
        didSet { UserDefaults.standard.set(swipeLeft.rawValue, forKey: Self.swipeLeftKey) }
    }

    /// Favorite changes made in this session, by item id. Lists fetched
    /// earlier carry stale `UserData`, so these win over what an item says.
    @Published private(set) var favoriteOverrides: [String: Bool] = [:]

    /// The music folders the server offers — "Music" and "Story tapes" are two
    /// libraries, and mixing them into one list makes both harder to browse.
    @Published private(set) var libraries: [JFItem] = []
    /// `nil` means "everything"; otherwise the id of the chosen media folder.
    @Published var selectedLibraryId: String? {
        didSet {
            guard selectedLibraryId != oldValue else { return }
            UserDefaults.standard.set(selectedLibraryId, forKey: Self.libraryKey)
            client?.libraryId = selectedLibraryId
            // Genres belong to a library; the old one's filter means nothing here.
            albumGenreId = nil
        }
    }

    let player = PlayerCoordinator()

    private static let sessionKey = "jellyfinSession"
    private static let qualityKey = "JellyCast.streamQuality"
    private static let libraryKey = "JellyCast.selectedLibraryId"
    private static let levellingKey = "JellyCast.volumeLevelling"
    private static let cellularQualityKey = "JellyCast.cellularQuality"
    private static let albumSortKey = "JellyCast.albumSort"
    private static let artistSortKey = "JellyCast.artistSort"
    private static let swipeRightKey = "JellyCast.swipeRight"
    private static let swipeLeftKey = "JellyCast.swipeLeft"
    private static let downloadQualityKey = "JellyCast.downloadQuality"

    /// Name of the current library, for the picker and the browse screens' titles.
    var selectedLibraryName: String? {
        guard let selectedLibraryId else { return nil }
        return libraries.first { $0.id == selectedLibraryId }?.name
    }

    var isSignedIn: Bool { client != nil }
    var userName: String { client?.session.userName ?? "" }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.qualityKey) ?? StreamQuality.original.rawValue
        let wifiQuality = StreamQuality(rawValue: raw) ?? .original
        streamQuality = wifiQuality
        // Mobile data defaults to whatever Wi-Fi uses, so nothing changes until asked.
        cellularQuality = UserDefaults.standard.string(forKey: Self.cellularQualityKey)
            .flatMap(StreamQuality.init(rawValue:)) ?? wifiQuality
        downloadQuality = UserDefaults.standard.string(forKey: Self.downloadQualityKey)
            .flatMap(StreamQuality.init(rawValue:)) ?? .original

        selectedLibraryId = UserDefaults.standard.string(forKey: Self.libraryKey)
        volumeLevelling = UserDefaults.standard.bool(forKey: Self.levellingKey)
        let defaults = UserDefaults.standard
        albumSort = defaults.string(forKey: Self.albumSortKey).flatMap(LibrarySort.init(rawValue:)) ?? .byName
        artistSort = defaults.string(forKey: Self.artistSortKey).flatMap(LibrarySort.init(rawValue:)) ?? .byName
        swipeRight = defaults.string(forKey: Self.swipeRightKey).flatMap(SwipeAction.init(rawValue:)) ?? .playNext
        swipeLeft = defaults.string(forKey: Self.swipeLeftKey).flatMap(SwipeAction.init(rawValue:)) ?? .addToQueue
        player.setLevelling(volumeLevelling)

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
        await signIn(with: session)
    }

    /// Finishes any sign-in — password or Quick Connect — once there's a session.
    func signIn(with session: JellyfinSession) async {
        if let data = try? JSONEncoder().encode(session) {
            Keychain.save(data, account: Self.sessionKey)
        }
        let client = JellyfinClient(session: session)
        client.libraryId = selectedLibraryId
        self.client = client
        player.attach(client: client, appState: self)
        await loadLibraries()
    }

    // MARK: - Favorites

    func isFavorite(_ item: JFItem) -> Bool {
        favoriteOverrides[item.id] ?? item.userData?.isFavorite ?? false
    }

    /// Flips the heart at once and tells the server; puts it back if the server refuses.
    func toggleFavorite(_ item: JFItem) {
        guard let client else { return }
        let newValue = !isFavorite(item)
        favoriteOverrides[item.id] = newValue
        Task {
            do {
                try await client.setFavorite(newValue, itemId: item.id)
            } catch {
                favoriteOverrides[item.id] = !newValue
                player.errorMessage = "Couldn't update favorites. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    func signOut() {
        player.shutdown()
        Keychain.delete(account: Self.sessionKey)
        client = nil
        libraries = []
        favoriteOverrides = [:]
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
    @Published private(set) var isShuffled: Bool
    @Published private(set) var repeatMode: RepeatMode
    @Published private(set) var sleepTimer: SleepTimer = .off

    /// Set when a Cast session is live, regardless of which route is selected.
    @Published private(set) var availableCastDevice: String?

    private let localPlayer = LocalPlayer()
    private let castEngine = CastEngine()

    private weak var client: JellyfinClient?
    private weak var appState: AppState?

    private var playSessionId = UUID().uuidString
    private var reportedItemId: String?
    private var lastProgressReport = Date.distantPast

    /// While shuffled, the order the queue had before — by entry, so turning
    /// shuffle off can put everything back, including tracks added since.
    private var unshuffledOrder: [UUID] = []

    private var sleepTask: Task<Void, Never>?

    private static let shuffleKey = "JellyCast.shuffle"
    private static let repeatKey = "JellyCast.repeatMode"

    var currentTrack: PlaybackTrack? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var isPlaying: Bool { state == .playing }

    private var engine: PlaybackEngine {
        route.isCast ? castEngine : localPlayer
    }

    override init() {
        isShuffled = UserDefaults.standard.bool(forKey: Self.shuffleKey)
        repeatMode = UserDefaults.standard.string(forKey: Self.repeatKey)
            .flatMap(RepeatMode.init(rawValue:)) ?? .off
        super.init()
        localPlayer.delegate = self
        castEngine.delegate = self
        localPlayer.setRepeatMode(repeatMode)
        castEngine.setRepeatMode(repeatMode)
        configureModeCommands()

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

        // Rebuilt for the new output: a speaker can't reach a file on this
        // phone, and the phone may want a lighter stream than the speaker.
        let rebuilt = resumeQueue.map { rebuild($0) }

        // Hand the queue over and land back on the same spot.
        engine.load(queue: rebuilt, startIndex: resumeIndex)
        queue = rebuilt
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
        items.compactMap { makeTrack($0) }
    }

    private func rebuild(_ track: PlaybackTrack) -> PlaybackTrack {
        guard var fresh = makeTrack(track.item) else { return track }
        fresh.entryId = track.entryId
        return fresh
    }

    /// A downloaded file when playing on this phone; otherwise a stream at the
    /// quality for the current connection.
    private func makeTrack(_ item: JFItem) -> PlaybackTrack? {
        guard let client, let appState else { return nil }
        let downloads = DownloadStore.shared

        if !route.isCast, let file = downloads.localURL(for: item.id), let saved = downloads.downloaded[item.id] {
            return PlaybackTrack(
                item: item,
                streamURL: file,
                contentType: "",
                artworkURL: downloads.localArtworkURL(for: item.id) ?? client.artworkURL(for: item),
                sourceLabel: "Downloaded · \(saved.formatLabel)"
            )
        }

        let quality = !route.isCast && NetworkMonitor.shared.isExpensive
            ? appState.cellularQuality : appState.streamQuality
        let stream = client.streamInfo(for: item, quality: quality)
        // Mirrors streamInfo: untouched only at Original, and only if playable as-is.
        let converted = quality != .original || !client.canDirectPlay(item) || item.sourceContainer == nil
        return PlaybackTrack(
            item: item,
            streamURL: stream.url,
            contentType: stream.contentType,
            artworkURL: client.artworkURL(for: item),
            sourceLabel: "\(converted ? "Converted" : "Streaming") · \(stream.label)"
        )
    }

    /// - Parameters:
    ///   - startIndex: the track to start on. `nil` means the first — or, when
    ///     shuffling, a random one.
    ///   - shuffle: `true` for a Shuffle button, `false` for a Play button;
    ///   `nil` (tapping a single track) keeps whatever mode is on.
    func play(items: [JFItem], startAt startIndex: Int? = nil, shuffle: Bool? = nil) {
        var tracks = makeTracks(items)
        guard !tracks.isEmpty else { return }

        let shuffle = shuffle ?? isShuffled
        if shuffle != isShuffled { setShuffleFlag(shuffle) }

        var start = max(0, min(startIndex ?? 0, tracks.count - 1))
        if shuffle {
            unshuffledOrder = tracks.map(\.entryId)
            if let startIndex {
                // The tapped track first, then everything else at random.
                let chosen = tracks.remove(at: max(0, min(startIndex, tracks.count - 1)))
                tracks = [chosen] + tracks.shuffled()
            } else {
                tracks.shuffle()
            }
            start = 0
        } else {
            unshuffledOrder = []
        }

        playSessionId = UUID().uuidString
        queue = tracks
        index = start
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
        if isShuffled {
            // Unshuffling should leave added tracks where they'd naturally be:
            // appended ones at the end, "play next" ones after their neighbour.
            let ids = tracks.map(\.entryId)
            if target < queue.count, target > 0,
               let anchor = unshuffledOrder.firstIndex(of: queue[target - 1].entryId) {
                unshuffledOrder.insert(contentsOf: ids, at: anchor + 1)
            } else if target == 0 {
                unshuffledOrder.insert(contentsOf: ids, at: 0)
            } else {
                unshuffledOrder.append(contentsOf: ids)
            }
        }
        queue.insert(contentsOf: tracks, at: target)
        if target <= index { index += tracks.count }
        engine.insert(tracks, at: target)
    }

    func removeFromQueue(at removeIndex: Int) {
        guard queue.indices.contains(removeIndex) else { return }
        let wasCurrent = removeIndex == index

        let removed = queue.remove(at: removeIndex)
        unshuffledOrder.removeAll { $0 == removed.entryId }
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
        unshuffledOrder = []
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

    /// Jumps within the current track; negative goes back.
    func skip(by seconds: TimeInterval) {
        guard currentTrack != nil, state != .idle else { return }
        let end = duration > 0 ? duration : .greatestFiniteMagnitude
        seek(to: min(max(0, position + seconds), end))
    }

    // MARK: - Instant Mix

    /// Replaces the queue with a radio-style mix the server builds around `item`.
    func playInstantMix(from item: JFItem) async {
        guard let client else { return }
        do {
            let mix = try await client.instantMix(from: item.id)
            guard !mix.isEmpty else {
                errorMessage = "Jellyfin couldn't build a mix from “\(item.name)”."
                return
            }
            // The server already orders a mix to flow; shuffling would undo that.
            play(items: mix, shuffle: false)
        } catch {
            errorMessage = "Couldn't start a mix. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = .at(deadline)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.fallAsleep()
        }
    }

    /// Stops when the playing track ends rather than cutting it off mid-song.
    func sleepAtEndOfTrack() {
        sleepTask?.cancel()
        sleepTimer = .endOfTrack
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTimer = .off
    }

    private func fallAsleep() {
        sleepTimer = .off
        if isPlaying { engine.pause() }
    }

    // MARK: - Volume levelling

    func setLevelling(_ enabled: Bool) {
        localPlayer.setLevelling(enabled)
        castEngine.setLevelling(enabled)
    }

    // MARK: - Shuffle and repeat

    func toggleShuffle() { setShuffle(!isShuffled) }

    /// Shuffling keeps the playing track playing and randomizes everything
    /// else after it; unshuffling restores the original order around it.
    func setShuffle(_ on: Bool) {
        guard on != isShuffled else { return }
        setShuffleFlag(on)

        guard let current = currentTrack else {
            unshuffledOrder = []
            return
        }

        let reordered: [PlaybackTrack]
        if on {
            unshuffledOrder = queue.map(\.entryId)
            var rest = queue
            rest.remove(at: index)
            reordered = [current] + rest.shuffled()
        } else {
            let byEntry = Dictionary(queue.map { ($0.entryId, $0) }, uniquingKeysWith: { first, _ in first })
            let known = Set(unshuffledOrder)
            reordered = unshuffledOrder.compactMap { byEntry[$0] }
                + queue.filter { !known.contains($0.entryId) }
            unshuffledOrder = []
        }

        let newIndex = reordered.firstIndex { $0.entryId == current.entryId } ?? 0
        queue = reordered
        index = newIndex
        // Once playback has ended the engine holds no queue; play reloads it.
        if state != .idle { engine.reorder(reordered, index: newIndex) }
    }

    func cycleRepeatMode() { setRepeatMode(repeatMode.next) }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.repeatKey)
        localPlayer.setRepeatMode(mode)
        castEngine.setRepeatMode(mode)
        MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType = mode.remoteType
    }

    private func setShuffleFlag(_ on: Bool) {
        isShuffled = on
        UserDefaults.standard.set(on, forKey: Self.shuffleKey)
        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = on ? .items : .off
    }

    /// CarPlay's shuffle and repeat buttons, and Siri, arrive here. They need
    /// the coordinator rather than an engine because they reorder the queue.
    private func configureModeCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = repeatMode.remoteType

        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.setShuffle(event.shuffleType != .off) }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode
            switch event.repeatType {
            case .one: mode = .one
            case .all: mode = .all
            default: mode = .off
            }
            Task { @MainActor in self?.setRepeatMode(mode) }
            return .success
        }
    }

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
        unshuffledOrder = []
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
            let moved = index != self.index
            self.index = index
            self.position = 0
            self.duration = self.currentTrack?.duration ?? 0
            self.reportStartIfNeeded()
            if moved, self.sleepTimer == .endOfTrack { self.fallAsleep() }
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
            if self.sleepTimer == .endOfTrack { self.cancelSleepTimer() }
        }
    }

    nonisolated func engine(_ engine: PlaybackEngine, didFail message: String) {
        Task { @MainActor in self.errorMessage = message }
    }
}

private extension RepeatMode {
    var remoteType: MPRepeatType {
        switch self {
        case .off: return .off
        case .all: return .all
        case .one: return .one
        }
    }
}

enum SleepTimer: Equatable {
    case off
    case at(Date)
    case endOfTrack
}
