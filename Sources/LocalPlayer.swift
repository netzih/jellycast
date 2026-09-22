import AVFoundation
import MediaPlayer
import UIKit

/// Plays through the iPhone's own audio output — which is what CarPlay,
/// Bluetooth and headphones all are. This is the engine used in the car.
final class LocalPlayer: NSObject, PlaybackEngine {
    weak var delegate: PlaybackEngineDelegate?

    private let player = AVPlayer()
    private var queue: [PlaybackTrack] = []
    private var index = 0
    private var timeObserver: Any?
    private var artworkTask: Task<Void, Never>?
    private var didConfigureCommands = false

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        addTimeObserver()
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemDidPlayToEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemFailedToPlay(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback keeps audio alive when the phone locks and routes to CarPlay.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("[JellyCast] audio session activation failed: \(error.localizedDescription)")
            delegate?.engine(self, didFail: "Couldn't start audio on this iPhone.")
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - PlaybackEngine

    func load(queue: [PlaybackTrack], startIndex: Int) {
        guard !queue.isEmpty else { return }
        self.queue = queue
        self.index = max(0, min(startIndex, queue.count - 1))
        configureRemoteCommandsIfNeeded()
        activateSession()
        startCurrentItem()
    }

    func play() {
        guard !queue.isEmpty else { return }
        activateSession()
        player.play()
        delegate?.engine(self, didChangeState: .playing)
        updateNowPlayingPlaybackState()
    }

    func pause() {
        player.pause()
        delegate?.engine(self, didChangeState: .paused)
        updateNowPlayingPlaybackState()
    }

    func next() {
        guard index + 1 < queue.count else {
            stop()
            delegate?.engineDidFinishQueue(self)
            return
        }
        index += 1
        startCurrentItem()
    }

    func previous() {
        // Match the usual convention: restart the track unless we're near its start.
        if player.currentTime().seconds > 3 {
            seek(to: 0)
            return
        }
        guard index > 0 else {
            seek(to: 0)
            return
        }
        index -= 1
        startCurrentItem()
    }

    func seek(to position: TimeInterval) {
        let time = CMTime(seconds: max(0, position), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlayingPlaybackState()
        }
    }

    func setVolume(_ volume: Float) {
        // System volume is owned by the hardware buttons / car head unit on this
        // route; adjusting AVPlayer.volume would fight the user. Intentionally a no-op.
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        artworkTask?.cancel()
        queue = []
        index = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateSession()
        delegate?.engine(self, didChangeState: .idle)
    }

    // MARK: - Queue editing
    //
    // These keep the engine's own array in step with the coordinator's, which
    // applied the same edit to the copy SwiftUI renders. Only edits that change
    // *which track is playing* report back, so the scrubber doesn't reset when
    // something is merely inserted further down the queue.

    func insert(_ newTracks: [PlaybackTrack], at insertIndex: Int) {
        guard !newTracks.isEmpty else { return }
        let target = max(0, min(insertIndex, queue.count))
        queue.insert(contentsOf: newTracks, at: target)
        if target <= index { index += newTracks.count }
    }

    func remove(at removeIndex: Int) {
        guard queue.indices.contains(removeIndex) else { return }
        queue.remove(at: removeIndex)

        if queue.isEmpty {
            stop()
            delegate?.engineDidFinishQueue(self)
            return
        }
        if removeIndex < index {
            index -= 1
        } else if removeIndex == index {
            guard index < queue.count else {
                // The playing track was last; nothing follows it.
                let remaining = queue
                stop()
                queue = remaining
                index = remaining.count - 1
                delegate?.engineDidFinishQueue(self)
                return
            }
            // Dropping the playing track means the next one takes its place.
            startCurrentItem()
        }
    }

    func move(from oldIndex: Int, to newIndex: Int) {
        guard queue.indices.contains(oldIndex) else { return }
        let target = max(0, min(newIndex, queue.count - 1))
        guard target != oldIndex else { return }

        let track = queue.remove(at: oldIndex)
        queue.insert(track, at: target)

        // Keep pointing at the same track wherever it ended up.
        if oldIndex == index {
            index = target
        } else if oldIndex < index && target >= index {
            index -= 1
        } else if oldIndex > index && target <= index {
            index += 1
        }
    }

    func jump(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        activateSession()
        startCurrentItem()
    }

    // MARK: - Internals

    private func startCurrentItem() {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        let asset = AVURLAsset(url: track.streamURL)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.play()

        delegate?.engine(self, didChangeIndex: index)
        delegate?.engine(self, didChangeState: .playing)
        updateNowPlayingInfo(for: track)
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.queue.indices.contains(self.index) else { return }
            let position = time.seconds.isFinite ? time.seconds : 0
            var duration = self.player.currentItem?.duration.seconds ?? 0
            if !duration.isFinite || duration <= 0 { duration = self.queue[self.index].duration }
            self.delegate?.engine(self, didChangePosition: position, duration: duration)
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
    }

    @objc private func itemDidPlayToEnd(_ note: Notification) {
        guard (note.object as? AVPlayerItem) === player.currentItem else { return }
        next()
    }

    @objc private func itemFailedToPlay(_ note: Notification) {
        let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        let message = error?.localizedDescription ?? "unknown error"
        print("[JellyCast] local playback failed: \(message)")
        delegate?.engine(self, didFail: "This track wouldn't play. \(message)")
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            delegate?.engine(self, didChangeState: .paused)
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0)
            }
            if options?.contains(.shouldResume) == true { play() }
        @unknown default:
            break
        }
    }

    // MARK: - Now Playing (this is what the car's dashboard shows)

    private func updateNowPlayingInfo(for track: PlaybackTrack) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        artworkTask?.cancel()
        guard let artworkURL = track.artworkURL else { return }
        artworkTask = Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: artworkURL).0,
                  let image = UIImage(data: data),
                  !Task.isCancelled else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard self != nil else { return }
                info[MPMediaItemPropertyArtwork] = artwork
                // Only apply if the same track is still current.
                let current = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                if current == track.title {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
    }

    private func updateNowPlayingPlaybackState() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] =
            player.rate > 0 ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
            player.currentTime().seconds
    }

    /// Steering-wheel buttons, lock screen, and the CarPlay Now Playing screen.
    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureCommands else { return }
        didConfigureCommands = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player.rate > 0 ? self.pause() : self.play()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }
}
