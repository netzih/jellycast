import Foundation
import Intents

/// "Hey Siri, play Abbey Road on JellyCast" — and the same by voice in CarPlay.
///
/// Handled inside the app rather than an Intents extension, so a request lands
/// on the live player: it plays on whatever route is current, the speaker at
/// home or the car. Siri only routes here once the App ID has the Siri
/// capability and the provisioning profile carries `com.apple.developer.siri`.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {

    /// What a resolved `INMediaItem` points at, round-tripped through its identifier.
    private enum Target {
        case artist(id: String)
        case album(id: String)
        case playlist(id: String)
        /// A song plays in the context of its album, so the music carries on after it.
        case track(id: String, albumId: String?)
        case library

        init?(identifier: String) {
            let parts = identifier.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch (parts.first, parts.count) {
            case ("artist", 2): self = .artist(id: parts[1])
            case ("album", 2): self = .album(id: parts[1])
            case ("playlist", 2): self = .playlist(id: parts[1])
            case ("track", 3): self = .track(id: parts[1], albumId: parts[2].isEmpty ? nil : parts[2])
            case ("library", _): self = .library
            default: return nil
            }
        }
    }

    // MARK: - Resolve

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        guard let client = await MainActor.run(body: { AppState.shared.client }) else {
            return [.unsupported(forReason: .loginRequired)]
        }
        let search = intent.mediaSearch

        // "Play JellyCast" / "play some music on JellyCast": nothing named.
        let nothingNamed = search?.mediaName == nil && search?.artistName == nil && search?.albumName == nil
        if nothingNamed {
            let item = INMediaItem(identifier: "library", title: "Your music", type: .music, artwork: nil)
            return INPlayMediaMediaItemResolutionResult.successes(with: [item])
        }

        do {
            guard let match = try await bestMatch(for: search, client: client) else {
                return [.unsupported()]
            }
            return INPlayMediaMediaItemResolutionResult.successes(with: [match])
        } catch {
            print("[JellyCast] Siri search failed: \(error.localizedDescription)")
            return [.unsupported(forReason: .serviceUnavailable)]
        }
    }

    /// Searches the kinds of thing the request could mean and keeps the
    /// closest name. Siri often can't tell an album from an artist, so an
    /// unspecified request tries everything.
    private func bestMatch(for search: INMediaSearch?, client: JellyfinClient) async throws -> INMediaItem? {
        let artistName = search?.artistName
        let kinds: [String]
        let term: String

        switch search?.mediaType ?? .unknown {
        case .artist:
            kinds = ["MusicArtist"]
            term = artistName ?? search?.mediaName ?? ""
        case .album:
            kinds = ["MusicAlbum"]
            term = search?.albumName ?? search?.mediaName ?? ""
        case .playlist:
            kinds = ["Playlist"]
            term = search?.mediaName ?? ""
        case .song:
            kinds = ["Audio"]
            term = search?.mediaName ?? ""
        default:
            if let name = search?.mediaName ?? search?.albumName {
                // Ties go to the earlier kind: someone naming a playlist means it.
                kinds = ["Playlist", "MusicArtist", "MusicAlbum", "Audio"]
                term = name
            } else {
                kinds = ["MusicArtist"]
                term = artistName ?? ""
            }
        }
        guard !term.isEmpty else { return nil }

        let results = try await withThrowingTaskGroup(of: (Int, [JFItem]).self) { group in
            for (rank, kind) in kinds.enumerated() {
                group.addTask { (rank, try await client.voiceSearch(term, type: kind)) }
            }
            var byRank: [Int: [JFItem]] = [:]
            for try await (rank, items) in group { byRank[rank] = items }
            return byRank
        }

        var best: (item: JFItem, score: Int, rank: Int)?
        for rank in kinds.indices {
            for item in results[rank] ?? [] {
                var score = Self.nameScore(item.name, against: term)
                guard score > 0 else { continue }
                // "Play Yerushalayim by Abie Rotenberg" — a matching artist breaks ties.
                if let artistName, item.type != "MusicArtist",
                   Self.nameScore(item.displayArtist, against: artistName) > 0 {
                    score += 1
                }
                if best == nil || score > best!.score || (score == best!.score && rank < best!.rank) {
                    best = (item, score, rank)
                }
            }
        }
        guard let item = best?.item else { return nil }
        return Self.mediaItem(for: item)
    }

    /// 0 = no match, higher is closer. Siri's spelling of a name rarely matches
    /// the tags exactly, so case, accents, punctuation and a leading "the" don't count.
    private static func nameScore(_ candidate: String, against spoken: String) -> Int {
        let a = normalize(candidate), b = normalize(spoken)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 6 }
        if a.hasPrefix(b) || b.hasPrefix(a) { return 4 }
        if a.contains(b) || b.contains(a) { return 2 }
        return 0
    }

    private static func normalize(_ text: String) -> String {
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        folded = String(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }.map(Character.init))
        folded = folded.split(separator: " ").joined(separator: " ")
        if folded.hasPrefix("the ") { folded.removeFirst(4) }
        return folded
    }

    private static func mediaItem(for item: JFItem) -> INMediaItem {
        let artist = item.displayArtist.isEmpty ? nil : item.displayArtist
        switch item.type {
        case "MusicArtist":
            return INMediaItem(identifier: "artist:\(item.id)", title: item.name, type: .artist, artwork: nil)
        case "MusicAlbum":
            return INMediaItem(identifier: "album:\(item.id)", title: item.name, type: .album,
                               artwork: nil, artist: artist)
        case "Playlist":
            return INMediaItem(identifier: "playlist:\(item.id)", title: item.name, type: .playlist, artwork: nil)
        default:
            return INMediaItem(identifier: "track:\(item.id):\(item.albumId ?? "")", title: item.name,
                               type: .song, artwork: nil, artist: artist)
        }
    }

    // MARK: - Handle

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        guard let client = await MainActor.run(body: { AppState.shared.client }),
              let identifier = intent.mediaItems?.first?.identifier,
              let target = Target(identifier: identifier) else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }

        let tracks: [JFItem]
        var startAt: Int?
        // An artist or "some music" is a pile, not a sequence — shuffle unless
        // Siri heard otherwise. Albums and playlists keep the current mode.
        var defaultShuffle: Bool?

        do {
            switch target {
            case .artist(let id):
                tracks = try await client.tracks(byArtist: id, allLibraries: true)
                defaultShuffle = true
            case .album(let id):
                tracks = try await client.tracks(inParent: id)
            case .playlist(let id):
                tracks = try await client.tracks(inParent: id)
            case .track(let id, let albumId):
                if let albumId, case let album = try await client.tracks(inParent: albumId),
                   let position = album.firstIndex(where: { $0.id == id }) {
                    tracks = album
                    startAt = position
                } else {
                    tracks = [try await client.item(id: id)]
                }
            case .library:
                tracks = try await client.randomTracks()
                defaultShuffle = true
            }
        } catch {
            print("[JellyCast] Siri playback lookup failed: \(error.localizedDescription)")
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }
        guard !tracks.isEmpty else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }

        let shuffle = intent.playShuffled ?? defaultShuffle
        let repeatMode: RepeatMode?
        switch intent.playbackRepeatMode {
        case .none: repeatMode = .off
        case .all: repeatMode = .all
        case .one: repeatMode = .one
        default: repeatMode = nil
        }

        await MainActor.run {
            let player = AppState.shared.player
            if let repeatMode { player.setRepeatMode(repeatMode) }
            player.play(items: tracks, startAt: startAt, shuffle: shuffle)
        }
        return INPlayMediaIntentResponse(code: .success, userActivity: nil)
    }
}

// MARK: - Vocabulary

enum SiriVocabulary {
    /// Teaches Siri the library's artist and playlist names, so names it
    /// wouldn't otherwise recognise get transcribed the way they're tagged.
    @MainActor
    static func update(using client: JellyfinClient) async {
        async let artists = try? client.artists(limit: 1000)
        async let playlists = try? client.playlists()
        let artistNames = (await artists ?? []).map(\.name)
        let playlistNames = (await playlists ?? []).map(\.name)

        let vocabulary = INVocabulary.shared()
        vocabulary.setVocabularyStrings(NSOrderedSet(array: artistNames), of: .mediaMusicArtistName)
        vocabulary.setVocabularyStrings(NSOrderedSet(array: playlistNames), of: .mediaPlaylistTitle)
    }

    /// The prompt only appears once; after that this is a no-op.
    static func requestAuthorizationIfNeeded() {
        guard INPreferences.siriAuthorizationStatus() == .notDetermined else { return }
        INPreferences.requestSiriAuthorization { _ in }
    }
}
