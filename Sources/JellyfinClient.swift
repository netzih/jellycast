import Foundation

/// How audio is delivered to the Cast device.
enum StreamQuality: String, CaseIterable, Identifiable {
    case original = "original"
    case mp3 = "mp3"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original quality"
        case .mp3: return "MP3 320 (max compatibility)"
        }
    }

    var detail: String {
        switch self {
        case .original: return "Sends FLAC, MP3 and AAC untouched. Falls back to MP3 for formats the speaker can't play."
        case .mp3: return "Always converts on the server. Use this if some tracks refuse to play."
        }
    }
}

struct JellyfinSession: Codable, Equatable {
    var baseURL: URL
    var accessToken: String
    var userId: String
    var userName: String
}

final class JellyfinClient {
    let session: JellyfinSession
    private let urlSession: URLSession

    /// Which media folder library browsing is restricted to, or `nil` for all
    /// of them. Set by `AppState` whenever the user changes the selection, so
    /// every call site — including CarPlay — is scoped without passing it down.
    var libraryId: String?

    /// Stable per-install device id; Jellyfin uses it to group playback sessions.
    static let deviceId: String = {
        let key = "JellyCast.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    static let clientName = "JellyCast"
    static let clientVersion = "1.0"

    init(session: JellyfinSession) {
        self.session = session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Auth

    /// `Authorization` value Jellyfin expects, with or without a token.
    static func authHeader(token: String?) -> String {
        var parts = [
            "MediaBrowser Client=\"\(clientName)\"",
            "Device=\"iPhone\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(clientVersion)\"",
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return parts.joined(separator: ", ")
    }

    static func normalizeServerURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    static func logIn(server: String, username: String, password: String) async throws -> JellyfinSession {
        guard let baseURL = normalizeServerURL(server) else { throw JellyfinError.badURL }

        var request = URLRequest(url: baseURL.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(token: nil), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["Username": username, "Pw": password]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw JellyfinError.badCredentials }
        guard (200..<300).contains(code) else {
            throw JellyfinError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }

        do {
            let auth = try JSONDecoder.jellyfin.decode(AuthResponse.self, from: data)
            return JellyfinSession(
                baseURL: baseURL,
                accessToken: auth.accessToken,
                userId: auth.user.id,
                userName: auth.user.name
            )
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    // MARK: - Request plumbing

    private func makeURL(_ path: String, _ query: [String: String?]) -> URL {
        var components = URLComponents(
            url: session.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        let pairs = query.compactMap { key, value -> URLQueryItem? in
            guard let value else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        if !pairs.isEmpty { components.queryItems = pairs.sorted { $0.name < $1.name } }
        return components.url!
    }

    private func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        var request = URLRequest(url: makeURL(path, query))
        request.setValue(Self.authHeader(token: session.accessToken), forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw JellyfinError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder.jellyfin.decode(T.self, from: data)
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    /// Performs a mutating request and returns the raw body. Unlike `post`,
    /// failures are thrown — these are user-initiated edits, not telemetry.
    @discardableResult
    private func send(
        _ method: String,
        _ path: String,
        query: [String: String?] = [:],
        body: [String: Any]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: makeURL(path, query))
        request.httpMethod = method
        request.setValue(Self.authHeader(token: session.accessToken), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await urlSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw JellyfinError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return data
    }

    /// Fire-and-forget POST used only by playback reporting.
    private func post(_ path: String, body: [String: Any]) async {
        do {
            try await send("POST", path, body: body)
        } catch {
            // Reporting is best-effort telemetry; never let it break playback.
            // Logged rather than swallowed so failures are visible in Console.
            print("[JellyCast] playback report to \(path) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Library

    private static let trackFields = "MediaSources,ParentId"

    /// The user's top-level media folders, narrowed to the musical ones — a
    /// server can hold "Music" and "Story tapes" as two separate libraries.
    func musicLibraries() async throws -> [JFItem] {
        // `/UserViews` is the modern spelling; older servers only answer the
        // per-user path. Try both before giving up.
        let response: ItemsResponse
        if let modern: ItemsResponse = try? await get("UserViews", query: ["userId": session.userId]) {
            response = modern
        } else {
            response = try await get("Users/\(session.userId)/Views")
        }
        let musical = response.items.filter { $0.collectionType?.lowercased() == "music" }
        // A folder with no declared collection type can still be full of audio,
        // so fall back to showing everything rather than an empty picker.
        return musical.isEmpty ? response.items : musical
    }

    func albums(startIndex: Int = 0, limit: Int = 200) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "includeItemTypes": "MusicAlbum",
            "recursive": "true",
            "parentId": libraryId,
            "sortBy": "SortName",
            "sortOrder": "Ascending",
            "startIndex": String(startIndex),
            "limit": String(limit),
            "fields": "PrimaryImageAspectRatio",
        ])
        return response.items
    }

    func artists(startIndex: Int = 0, limit: Int = 200) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Artists", query: [
            "userId": session.userId,
            "parentId": libraryId,
            "sortBy": "SortName",
            "sortOrder": "Ascending",
            "startIndex": String(startIndex),
            "limit": String(limit),
        ])
        return response.items
    }

    /// Deliberately *not* scoped to `libraryId`: Jellyfin keeps playlists in
    /// their own root folder, outside any music library.
    func playlists() async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "includeItemTypes": "Playlist",
            "recursive": "true",
            "sortBy": "SortName",
            "fields": "ChildCount",
        ])
        // A Jellyfin playlist can hold video too. Exclude only the ones the
        // server explicitly calls video — older versions leave `MediaType`
        // unset or "Unknown" on perfectly good music playlists.
        return response.items.filter { $0.mediaType?.caseInsensitiveCompare("Video") != .orderedSame }
    }

    func albums(forArtist artistId: String) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "albumArtistIds": artistId,
            "includeItemTypes": "MusicAlbum",
            "recursive": "true",
            "parentId": libraryId,
            "sortBy": "ProductionYear,SortName",
        ])
        return response.items
    }

    /// Tracks of an album or playlist, in playing order.
    func tracks(inParent parentId: String) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "parentId": parentId,
            "includeItemTypes": "Audio",
            "sortBy": "ParentIndexNumber,IndexNumber,SortName",
            "fields": Self.trackFields,
        ])
        return response.items
    }

    func search(_ term: String) async throws -> (artists: [JFItem], albums: [JFItem], tracks: [JFItem]) {
        async let artistsResult: ItemsResponse = get("Items", query: [
            "userId": session.userId, "searchTerm": term, "includeItemTypes": "MusicArtist",
            "recursive": "true", "parentId": libraryId, "limit": "20",
        ])
        async let albumsResult: ItemsResponse = get("Items", query: [
            "userId": session.userId, "searchTerm": term, "includeItemTypes": "MusicAlbum",
            "recursive": "true", "parentId": libraryId, "limit": "40",
        ])
        async let tracksResult: ItemsResponse = get("Items", query: [
            "userId": session.userId, "searchTerm": term, "includeItemTypes": "Audio",
            "recursive": "true", "parentId": libraryId, "limit": "60", "fields": Self.trackFields,
        ])
        return try await (artistsResult.items, albumsResult.items, tracksResult.items)
    }

    /// Tracks by a single artist, used by "play everything by this artist".
    func tracks(byArtist artistId: String) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "artistIds": artistId,
            "includeItemTypes": "Audio",
            "recursive": "true",
            "parentId": libraryId,
            "sortBy": "Album,ParentIndexNumber,IndexNumber",
            "fields": Self.trackFields,
        ])
        return response.items
    }

    // MARK: - Playlist editing
    //
    // Playlist membership is identified by `PlaylistItemId`, not the track's own
    // id — the same song can sit in a playlist twice. Only `/Playlists/{id}/Items`
    // returns that handle, which is why playlists don't share `tracks(inParent:)`.

    func playlistTracks(playlistId: String) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Playlists/\(playlistId)/Items", query: [
            "userId": session.userId,
            "fields": Self.trackFields,
        ])
        return response.items
    }

    /// Creates a playlist and returns its id. `itemIds` may be empty.
    func createPlaylist(name: String, itemIds: [String] = []) async throws -> String {
        var body: [String: Any] = [
            "Name": name,
            "UserId": session.userId,
            "MediaType": "Audio",
        ]
        if !itemIds.isEmpty { body["Ids"] = itemIds }
        let data = try await send("POST", "Playlists", body: body)
        return try JSONDecoder.jellyfin.decode(PlaylistCreationResult.self, from: data).id
    }

    func addToPlaylist(playlistId: String, itemIds: [String]) async throws {
        guard !itemIds.isEmpty else { return }
        try await send("POST", "Playlists/\(playlistId)/Items", query: [
            "ids": itemIds.joined(separator: ","),
            "userId": session.userId,
        ])
    }

    /// - Parameter entryIds: `PlaylistItemId` values, not track ids.
    func removeFromPlaylist(playlistId: String, entryIds: [String]) async throws {
        guard !entryIds.isEmpty else { return }
        try await send("DELETE", "Playlists/\(playlistId)/Items", query: [
            "entryIds": entryIds.joined(separator: ","),
        ])
    }

    func movePlaylistItem(playlistId: String, entryId: String, to newIndex: Int) async throws {
        try await send("POST", "Playlists/\(playlistId)/Items/\(entryId)/Move/\(newIndex)")
    }

    /// Needs the account's "allow deletion" permission; the caller surfaces a 401/403.
    func deletePlaylist(playlistId: String) async throws {
        try await send("DELETE", "Items/\(playlistId)")
    }

    // MARK: - URLs handed to the Cast device
    //
    // The speaker fetches these itself, so every URL must carry `api_key` —
    // the Authorization header only exists on requests this app makes.

    /// Containers a Google Home / Nest speaker can decode natively.
    private static let castableContainers: Set<String> = [
        "mp3", "flac", "wav", "aac", "m4a", "mp4", "ogg", "oga", "opus", "webm",
    ]
    /// Codecs that appear inside those containers but the speaker cannot decode.
    private static let uncastableCodecs: Set<String> = ["alac", "wmav2", "wmapro", "ape", "dsd"]

    private static func contentType(forContainer container: String) -> String {
        switch container {
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "m4a", "mp4": return "audio/mp4"
        case "ogg", "oga", "opus": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "audio/mpeg"
        }
    }

    func canDirectPlay(_ item: JFItem) -> Bool {
        guard let container = item.sourceContainer,
              Self.castableContainers.contains(container) else { return false }
        if let codec = item.sourceAudioCodec, Self.uncastableCodecs.contains(codec) { return false }
        return true
    }

    /// Returns the URL the speaker should fetch, plus its MIME type.
    func streamInfo(for item: JFItem, quality: StreamQuality) -> (url: URL, contentType: String) {
        if quality == .original, canDirectPlay(item), let container = item.sourceContainer {
            let url = makeURL("Audio/\(item.id)/stream.\(container)", [
                "static": "true",
                "api_key": session.accessToken,
                "deviceId": Self.deviceId,
            ])
            return (url, Self.contentType(forContainer: container))
        }

        // Server-side transcode to a format every Cast receiver accepts.
        let url = makeURL("Audio/\(item.id)/universal", [
            "api_key": session.accessToken,
            "userId": session.userId,
            "deviceId": Self.deviceId,
            "container": "mp3",
            "audioCodec": "mp3",
            "transcodingContainer": "mp3",
            "transcodingProtocol": "http",
            "maxStreamingBitrate": "320000",
        ])
        return (url, "audio/mpeg")
    }

    func artworkURL(for item: JFItem, maxHeight: Int = 512) -> URL? {
        guard let tag = item.artworkTag else { return nil }
        return makeURL("Items/\(item.artworkItemId)/Images/Primary", [
            "tag": tag,
            "maxHeight": String(maxHeight),
            "quality": "90",
            "api_key": session.accessToken,
        ])
    }

    // MARK: - Playback reporting (keeps Jellyfin's "recently played" honest)

    func reportPlaybackStart(itemId: String, sessionId: String) async {
        await post("Sessions/Playing", body: [
            "ItemId": itemId, "PlaySessionId": sessionId,
            "CanSeek": true, "IsPaused": false, "PositionTicks": 0,
            "PlayMethod": "DirectStream",
        ])
    }

    func reportPlaybackProgress(itemId: String, sessionId: String, position: TimeInterval, isPaused: Bool) async {
        await post("Sessions/Playing/Progress", body: [
            "ItemId": itemId, "PlaySessionId": sessionId,
            "CanSeek": true, "IsPaused": isPaused,
            "PositionTicks": Int64(max(0, position) * 10_000_000),
            "PlayMethod": "DirectStream",
        ])
    }

    func reportPlaybackStopped(itemId: String, sessionId: String, position: TimeInterval) async {
        await post("Sessions/Playing/Stopped", body: [
            "ItemId": itemId, "PlaySessionId": sessionId,
            "PositionTicks": Int64(max(0, position) * 10_000_000),
        ])
    }
}
