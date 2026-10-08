import Foundation
import GoogleCast

/// Sends audio to a Google Home / Nest / Chromecast device.
///
/// The speaker fetches the stream from Jellyfin itself — this app only sends a
/// URL and transport commands, so playback survives the phone sleeping.
final class CastEngine: NSObject, PlaybackEngine {
    weak var delegate: PlaybackEngineDelegate?

    /// Non-nil while a Cast session is live.
    private(set) var connectedDeviceName: String?
    var onConnectionChange: ((String?) -> Void)?

    private var tracks: [PlaybackTrack] = []
    /// The receiver's own id for each entry, parallel to `tracks`. Queue edits
    /// are addressed by these, not by position, so a status update that lands
    /// mid-edit can't make us remove the wrong song.
    private var itemIDs: [UInt] = []
    private var index = 0
    private var repeatMode: RepeatMode = .off
    private var levelling = false
    private var positionTimer: Timer?
    private var pendingLoad: (tracks: [PlaybackTrack], startIndex: Int)?

    /// Custom metadata key used to map a Cast queue entry back to a Jellyfin item.
    private static let itemIdKey = "jellyfinItemId"

    private var remoteClient: GCKRemoteMediaClient? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    override init() {
        super.init()
        GCKCastContext.sharedInstance().sessionManager.add(self)
    }

    // MARK: - PlaybackEngine

    func load(queue: [PlaybackTrack], startIndex: Int) {
        guard !queue.isEmpty else { return }
        tracks = queue
        // The receiver hasn't assigned ids yet; `refreshItemIDs` fills these in
        // from the first status update after the load lands.
        itemIDs = Array(repeating: kGCKMediaQueueInvalidItemID, count: queue.count)
        index = max(0, min(startIndex, queue.count - 1))

        guard let client = remoteClient else {
            // Not connected yet — remember the request and fire it on connect.
            pendingLoad = (queue, index)
            delegate?.engine(self, didFail: "Pick a speaker first, then press play.")
            return
        }

        let queueData = GCKMediaQueueDataBuilder(queueType: .playlist)
        queueData.items = queue.map(makeQueueItem)
        queueData.startIndex = UInt(index)
        queueData.repeatMode = Self.castRepeatMode(repeatMode)

        let request = GCKMediaLoadRequestDataBuilder()
        request.queueData = queueData.build()
        client.loadMedia(with: request.build())
        client.add(self)
        // Applied once the receiver reports the load; stream volume set before
        // then would land on the previous media.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.applyLevelling() }
        startPositionTimer()
        delegate?.engine(self, didChangeIndex: index)
        delegate?.engine(self, didChangeState: .buffering)
    }

    func play() { remoteClient?.play() }
    func pause() { remoteClient?.pause() }
    func next() { remoteClient?.queueNextItem() }

    func previous() {
        guard let client = remoteClient else { return }
        if client.approximateStreamPosition() > 3 {
            seek(to: 0)
        } else {
            client.queuePreviousItem()
        }
    }

    func seek(to position: TimeInterval) {
        let options = GCKMediaSeekOptions()
        options.interval = position
        options.resumeState = .play
        remoteClient?.seek(with: options)
    }

    func setVolume(_ volume: Float) {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?
            .setDeviceVolume(volume)
    }

    func stop() {
        positionTimer?.invalidate()
        positionTimer = nil
        remoteClient?.stop()
        tracks = []
        itemIDs = []
        index = 0
        delegate?.engine(self, didChangeState: .idle)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        // The receiver advances on its own, so repeat has to live there too.
        if !tracks.isEmpty { remoteClient?.queueSetRepeatMode(Self.castRepeatMode(mode)) }
    }

    func setLevelling(_ enabled: Bool) {
        levelling = enabled
        applyLevelling()
    }

    /// Stream volume scales this media only, under the speaker's own volume,
    /// so the volume slider keeps meaning what it says.
    private func applyLevelling() {
        guard let client = remoteClient, tracks.indices.contains(index) else { return }
        client.setStreamVolume(levelling ? tracks[index].levellingVolume : 1)
    }

    private static func castRepeatMode(_ mode: RepeatMode) -> GCKMediaRepeatMode {
        switch mode {
        case .off: return .off
        case .all: return .all
        case .one: return .single
        }
    }

    /// Ends the connection to the speaker entirely.
    func disconnect() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    var currentVolume: Float {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.currentDeviceVolume ?? 0.5
    }

    // MARK: - Queue editing

    private func itemID(at index: Int) -> UInt {
        itemIDs.indices.contains(index) ? itemIDs[index] : kGCKMediaQueueInvalidItemID
    }

    func insert(_ newTracks: [PlaybackTrack], at insertIndex: Int) {
        guard !newTracks.isEmpty else { return }
        let target = max(0, min(insertIndex, tracks.count))

        tracks.insert(contentsOf: newTracks, at: target)
        itemIDs.insert(
            contentsOf: Array(repeating: kGCKMediaQueueInvalidItemID, count: newTracks.count),
            at: min(target, itemIDs.count)
        )
        if target <= index { index += newTracks.count }

        // An invalid "before" id means append, which is exactly what we want
        // when the insertion point is the end of the queue.
        remoteClient?.queueInsert(
            newTracks.map(makeQueueItem),
            beforeItemWithID: itemID(at: target + newTracks.count)
        )
    }

    func remove(at removeIndex: Int) {
        guard tracks.indices.contains(removeIndex) else { return }
        let doomedID = itemID(at: removeIndex)

        tracks.remove(at: removeIndex)
        if itemIDs.indices.contains(removeIndex) { itemIDs.remove(at: removeIndex) }
        // Removing what's playing lets the receiver advance on its own; `index`
        // already points at whatever slid into the gap.
        if removeIndex < index { index -= 1 }

        if doomedID != kGCKMediaQueueInvalidItemID {
            remoteClient?.queueRemoveItem(withID: doomedID)
        }
        if tracks.isEmpty { stop() }
    }

    func move(from oldIndex: Int, to newIndex: Int) {
        guard tracks.indices.contains(oldIndex) else { return }
        let target = max(0, min(newIndex, tracks.count - 1))
        guard target != oldIndex else { return }

        let movedID = itemID(at: oldIndex)
        let track = tracks.remove(at: oldIndex)
        tracks.insert(track, at: target)
        if itemIDs.indices.contains(oldIndex) {
            let id = itemIDs.remove(at: oldIndex)
            itemIDs.insert(id, at: min(target, itemIDs.count))
        }

        if oldIndex == index {
            index = target
        } else if oldIndex < index && target >= index {
            index -= 1
        } else if oldIndex > index && target <= index {
            index += 1
        }

        if movedID != kGCKMediaQueueInvalidItemID {
            remoteClient?.queueMoveItem(withID: movedID, beforeItemWithID: itemID(at: target + 1))
        }
    }

    func jump(to newIndex: Int) {
        guard tracks.indices.contains(newIndex) else { return }
        let targetID = itemID(at: newIndex)
        guard targetID != kGCKMediaQueueInvalidItemID else {
            // The receiver hasn't acknowledged this entry yet, so it has no id
            // to jump to. Re-sending the queue lands on the right track anyway.
            load(queue: tracks, startIndex: newIndex)
            return
        }
        index = newIndex
        remoteClient?.queueJumpToItem(withID: targetID)
        delegate?.engine(self, didChangeIndex: newIndex)
    }

    func reorder(_ newQueue: [PlaybackTrack], index newIndex: Int) {
        guard newQueue.indices.contains(newIndex) else { return }
        // Entries are matched by entry id, so duplicate songs keep their own
        // receiver ids through the shuffle.
        let idByEntry = Dictionary(
            zip(tracks.map(\.entryId), itemIDs.indices.map { itemID(at: $0) }),
            uniquingKeysWith: { first, _ in first }
        )
        let newIDs = newQueue.map { idByEntry[$0.entryId] ?? kGCKMediaQueueInvalidItemID }

        guard let client = remoteClient, !newIDs.contains(kGCKMediaQueueInvalidItemID) else {
            // Some entry hasn't been acknowledged yet, so it can't be addressed.
            // Re-sending the queue and seeking back is a brief hiccup, not a wrong order.
            let resumeAt = remoteClient?.approximateStreamPosition() ?? 0
            load(queue: newQueue, startIndex: newIndex)
            if resumeAt > 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.seek(to: resumeAt)
                }
            }
            return
        }

        tracks = newQueue
        itemIDs = newIDs
        index = newIndex
        // Moving every id to the end, in order, rewrites the whole order at once.
        client.queueReorderItems(
            withIDs: newIDs.map { NSNumber(value: $0) },
            insertBeforeItemWithID: kGCKMediaQueueInvalidItemID
        )
    }

    /// Re-syncs `itemIDs` from a status update, but only when the receiver's
    /// queue still matches ours track for track. A mismatch means an edit is
    /// still in flight, and adopting those ids would scramble the mapping.
    private func refreshItemIDs(from status: GCKMediaStatus) {
        guard status.queueItemCount == tracks.count else { return }
        var fresh: [UInt] = []
        fresh.reserveCapacity(tracks.count)
        for position in 0..<tracks.count {
            guard let entry = status.queueItem(at: UInt(position)),
                  entry.mediaInformation.metadata?.string(forKey: Self.itemIdKey) == tracks[position].id
            else { return }
            fresh.append(entry.itemID)
        }
        itemIDs = fresh
    }

    // MARK: - Building the Cast queue

    private func makeQueueItem(_ track: PlaybackTrack) -> GCKMediaQueueItem {
        let metadata = GCKMediaMetadata(metadataType: .musicTrack)
        metadata.setString(track.title, forKey: kGCKMetadataKeyTitle)
        if !track.artist.isEmpty { metadata.setString(track.artist, forKey: kGCKMetadataKeyArtist) }
        if !track.album.isEmpty { metadata.setString(track.album, forKey: kGCKMetadataKeyAlbumTitle) }
        metadata.setString(track.id, forKey: Self.itemIdKey)
        if let artworkURL = track.artworkURL {
            metadata.addImage(GCKImage(url: artworkURL, width: 512, height: 512))
        }

        let mediaBuilder = GCKMediaInformationBuilder(contentURL: track.streamURL)
        mediaBuilder.streamType = .buffered
        mediaBuilder.contentType = track.contentType
        mediaBuilder.metadata = metadata
        if track.duration > 0 { mediaBuilder.streamDuration = track.duration }

        let itemBuilder = GCKMediaQueueItemBuilder()
        itemBuilder.mediaInformation = mediaBuilder.build()
        itemBuilder.autoplay = true
        itemBuilder.preloadTime = 5
        return itemBuilder.build()
    }

    // MARK: - Position polling
    //
    // The receiver pushes status on change, not continuously, so poll for the
    // scrubber. `approximateStreamPosition` is local dead-reckoning — cheap.

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let client = self.remoteClient else { return }
            let position = client.approximateStreamPosition()
            var duration = client.mediaStatus?.mediaInformation?.streamDuration ?? 0
            if !duration.isFinite || duration <= 0 {
                duration = self.tracks.indices.contains(self.index) ? self.tracks[self.index].duration : 0
            }
            self.delegate?.engine(self, didChangePosition: position, duration: duration)
        }
    }
}

// MARK: - Session lifecycle

extension CastEngine: GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        handleConnected(session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        handleConnected(session)
    }

    private func handleConnected(_ session: GCKSession) {
        connectedDeviceName = session.device.friendlyName ?? "Speaker"
        onConnectionChange?(connectedDeviceName)
        remoteClient?.add(self)

        if let pending = pendingLoad {
            pendingLoad = nil
            load(queue: pending.tracks, startIndex: pending.startIndex)
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        if let error {
            print("[JellyCast] cast session ended with error: \(error.localizedDescription)")
            delegate?.engine(self, didFail: "Lost the connection to \(connectedDeviceName ?? "the speaker").")
        }
        positionTimer?.invalidate()
        positionTimer = nil
        connectedDeviceName = nil
        onConnectionChange?(nil)
        delegate?.engine(self, didChangeState: .idle)
    }

    func sessionManager(_ sessionManager: GCKSessionManager,
                        didFailToStart session: GCKSession, withError error: Error) {
        print("[JellyCast] cast session failed to start: \(error.localizedDescription)")
        connectedDeviceName = nil
        onConnectionChange?(nil)
        delegate?.engine(self, didFail: "Couldn't connect to that speaker. Make sure it's on the same Wi-Fi network.")
    }
}

// MARK: - Receiver status

extension CastEngine: GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else { return }

        switch mediaStatus.playerState {
        case .playing:
            delegate?.engine(self, didChangeState: .playing)
        case .paused:
            delegate?.engine(self, didChangeState: .paused)
        case .buffering, .loading:
            delegate?.engine(self, didChangeState: .buffering)
        case .idle:
            if mediaStatus.idleReason == .finished {
                delegate?.engineDidFinishQueue(self)
            }
            delegate?.engine(self, didChangeState: .idle)
        default:
            break
        }

        refreshItemIDs(from: mediaStatus)

        // Map the receiver's current entry back to our queue position. Prefer
        // the queue item id: a track can legitimately appear twice, and then
        // its Jellyfin id no longer identifies a single row.
        var newIndex = itemIDs.firstIndex(of: mediaStatus.currentItemID)
        if newIndex == nil, let itemId = mediaStatus.mediaInformation?.metadata?.string(forKey: Self.itemIdKey) {
            newIndex = tracks.firstIndex { $0.id == itemId }
        }
        if let newIndex, newIndex != index {
            index = newIndex
            delegate?.engine(self, didChangeIndex: newIndex)
            applyLevelling()
        }
    }
}
