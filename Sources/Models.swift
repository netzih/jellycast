import Foundation

// MARK: - Decoding helpers

/// Jellyfin returns PascalCase keys. Rather than writing CodingKeys for every
/// field, lowercase the first letter of each key.
///
/// Caveat: this strategy also applies to *dictionary* keys, so `ImageTags`
/// arrives as `["primary": "..."]` rather than `["Primary": "..."]`. Lookups
/// below account for both spellings.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
}

extension JSONDecoder {
    static let jellyfin: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let last = keys[keys.count - 1]
            let s = last.stringValue
            guard let first = s.first else { return last }
            return AnyCodingKey(stringValue: first.lowercased() + s.dropFirst())
        }
        return d
    }()
}

// MARK: - Auth

struct AuthResponse: Decodable {
    let user: JFUser
    let accessToken: String
}

struct JFUser: Decodable {
    let id: String
    let name: String
}

// MARK: - Items

struct ItemsResponse: Decodable {
    let items: [JFItem]
    let totalRecordCount: Int?
}

struct JFItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String?

    let albumArtist: String?
    let artists: [String]?
    let album: String?
    let albumId: String?

    let indexNumber: Int?
    let parentIndexNumber: Int?
    let runTimeTicks: Int64?
    let productionYear: Int?
    let childCount: Int?

    let container: String?
    let mediaSources: [JFMediaSource]?

    /// "music", "tvshows", … — only set on the library folders `/Views` returns.
    let collectionType: String?
    /// Identity of a track *within a playlist*; the handle the remove API wants.
    /// Only present on items fetched from `/Playlists/{id}/Items`.
    let playlistItemId: String?
    let mediaType: String?

    let imageTags: [String: String]?
    let albumPrimaryImageTag: String?

    // MARK: Derived

    var displayArtist: String {
        albumArtist ?? artists?.first ?? ""
    }

    var duration: TimeInterval {
        guard let ticks = runTimeTicks else { return 0 }
        return Double(ticks) / 10_000_000.0
    }

    /// The image tag to use, tolerating both key spellings (see `AnyCodingKey`).
    var primaryImageTag: String? {
        imageTags?["primary"] ?? imageTags?["Primary"]
    }

    /// For a track, fall back to the parent album's artwork.
    var artworkItemId: String {
        if primaryImageTag != nil { return id }
        if albumPrimaryImageTag != nil, let albumId { return albumId }
        return id
    }

    var artworkTag: String? {
        primaryImageTag ?? albumPrimaryImageTag
    }

    /// Container/codec actually on disk, used to decide direct-play vs transcode.
    var sourceContainer: String? {
        let raw = mediaSources?.first?.container ?? container
        return raw?.split(separator: ",").first.map(String.init)?.lowercased()
    }

    var sourceAudioCodec: String? {
        mediaSources?.first?.mediaStreams?
            .first { $0.type?.lowercased() == "audio" }?
            .codec?.lowercased()
    }

    /// The same track can appear twice in one playlist, so `id` alone is not a
    /// stable list identity there.
    var rowId: String { playlistItemId ?? id }

    static func == (lhs: JFItem, rhs: JFItem) -> Bool {
        lhs.id == rhs.id && lhs.playlistItemId == rhs.playlistItemId
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(playlistItemId)
    }
}

/// `POST /Playlists` replies with just the new playlist's id.
struct PlaylistCreationResult: Decodable {
    let id: String
}

struct JFMediaSource: Decodable, Hashable {
    let container: String?
    let mediaStreams: [JFMediaStream]?
}

struct JFMediaStream: Decodable, Hashable {
    let type: String?
    let codec: String?
}

// MARK: - Errors

enum JellyfinError: LocalizedError {
    case badURL
    case badCredentials
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "That doesn't look like a valid server address. Try something like http://192.168.1.50:8096"
        case .badCredentials:
            return "Wrong username or password."
        case .http(let code, let body):
            if code == 401 { return "Your session expired. Please sign in again." }
            return "The server returned an error (\(code)). \(body)"
        case .decoding(let detail):
            return "Couldn't understand the server's reply. \(detail)"
        }
    }
}
