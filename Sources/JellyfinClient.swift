import Foundation

/// How audio is delivered — streamed, cast or downloaded.
enum StreamQuality: String, CaseIterable, Identifiable {
    case original = "original"
    /// Raw value kept from when this was the only converted option.
    case high = "mp3"
    case medium = "mp3_192"
    case low = "mp3_128"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .high: return "High · 320 kbps"
        case .medium: return "Medium · 192 kbps"
        case .low: return "Low · 128 kbps"
        }
    }

    var detail: String {
        switch self {
        case .original:
            return "Plays FLAC, MP3 and AAC untouched. Anything else is converted to MP3 320."
        case .high:
            return "Always converted to MP3 on the server. Use this if some tracks refuse to play."
        case .medium:
            return "About 1.4 MB a minute. Hard to tell apart from High in a car."
        case .low:
            return "About 1 MB a minute. Easiest on mobile data and weak signal."
        }
    }

    /// Bits per second to convert to; `nil` for untouched originals.
    var bitrate: Int? {
        switch self {
        case .original: return nil
        case .high: return 320_000
        case .medium: return 192_000
        case .low: return 128_000
        }
    }
}

/// How the Albums and Artists lists are ordered.
struct LibrarySort: Equatable {
    enum Field: String, CaseIterable, Identifiable {
        case name, artist, dateAdded, year, random

        var id: String { rawValue }

        var label: String {
            switch self {
            case .name: return "Name"
            case .artist: return "Artist"
            case .dateAdded: return "Recently added"
            case .year: return "Year"
            case .random: return "Random"
            }
        }

        /// Newest-first reads naturally for dates; A→Z for everything else.
        var defaultAscending: Bool { !(self == .dateAdded || self == .year) }

        /// Jellyfin `sortBy`. A secondary SortName keeps ties in a stable order.
        var jellyfinSortBy: String {
            switch self {
            case .name: return "SortName"
            case .artist: return "AlbumArtist,SortName"
            case .dateAdded: return "DateCreated,SortName"
            case .year: return "ProductionYear,SortName"
            case .random: return "Random"
            }
        }

        /// Artists have no artist or year of their own.
        static func available(for kind: LibraryKind) -> [Field] {
            kind == .artists ? [.name, .dateAdded, .random] : allCases
        }
    }

    var field: Field
    var ascending: Bool

    static let byName = LibrarySort(field: .name, ascending: true)

    /// "name:asc" — for UserDefaults.
    var rawValue: String { "\(field.rawValue):\(ascending ? "asc" : "desc")" }

    init(field: Field, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let field = Field(rawValue: String(parts[0])) else { return nil }
        self.init(field: field, ascending: parts[1] == "asc")
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
        return try session(from: data, baseURL: baseURL)
    }

    // MARK: - Quick Connect
    //
    // Signing in without a password: this device gets a short code, someone
    // already signed in approves it (Jellyfin's web app, or JellyCast on
    // another phone), and the secret then trades for a session.

    /// Unauthenticated request against a server we don't have a session for yet.
    private static func anonymous(_ method: String, _ baseURL: URL, _ path: String,
                                  query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(authHeader(token: nil), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw JellyfinError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return data
    }

    static func quickConnectEnabled(server: String) async throws -> Bool {
        guard let baseURL = normalizeServerURL(server) else { throw JellyfinError.badURL }
        let data = try await anonymous("GET", baseURL, "QuickConnect/Enabled")
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    /// Starts a request; show `code` to the person, keep `secret` to poll with.
    static func initiateQuickConnect(server: String) async throws -> (baseURL: URL, code: String, secret: String) {
        guard let baseURL = normalizeServerURL(server) else { throw JellyfinError.badURL }
        let data: Data
        do {
            data = try await anonymous("POST", baseURL, "QuickConnect/Initiate")
        } catch JellyfinError.http(let status, _) where status == 404 || status == 405 {
            // Before 10.9 this was a GET.
            data = try await anonymous("GET", baseURL, "QuickConnect/Initiate")
        }
        let result = try JSONDecoder.jellyfin.decode(QuickConnectResult.self, from: data)
        return (baseURL, result.code, result.secret)
    }

    /// True once someone has approved the code.
    static func quickConnectApproved(baseURL: URL, secret: String) async throws -> Bool {
        let data = try await anonymous("GET", baseURL, "QuickConnect/Connect",
                                       query: [URLQueryItem(name: "secret", value: secret)])
        return try JSONDecoder.jellyfin.decode(QuickConnectResult.self, from: data).authenticated
    }

    static func logIn(baseURL: URL, quickConnectSecret secret: String) async throws -> JellyfinSession {
        let data = try await anonymous("POST", baseURL, "Users/AuthenticateWithQuickConnect", body: ["Secret": secret])
        return try session(from: data, baseURL: baseURL)
    }

    /// Approves a code shown on another device; it signs in as this user.
    func authorizeQuickConnect(code: String) async throws {
        try await send("POST", "QuickConnect/Authorize", query: ["code": code, "userId": session.userId])
    }

    private static func session(from data: Data, baseURL: URL) throws -> JellyfinSession {
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

    func albums(startIndex: Int = 0, limit: Int = 200,
                sort: LibrarySort = .byName, genreId: String? = nil) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "includeItemTypes": "MusicAlbum",
            "recursive": "true",
            "parentId": libraryId,
            "genreIds": genreId,
            "sortBy": sort.field.jellyfinSortBy,
            "sortOrder": sort.ascending ? "Ascending" : "Descending",
            "startIndex": String(startIndex),
            "limit": String(limit),
            "fields": "PrimaryImageAspectRatio",
        ])
        return response.items
    }

    func artists(startIndex: Int = 0, limit: Int = 200, sort: LibrarySort = .byName) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Artists", query: [
            "userId": session.userId,
            "parentId": libraryId,
            "sortBy": sort.field.jellyfinSortBy,
            "sortOrder": sort.ascending ? "Ascending" : "Descending",
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
    /// - Parameter allLibraries: ignore the library picker — for Siri, which
    ///   can't see which library is selected.
    func tracks(byArtist artistId: String, allLibraries: Bool = false) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "artistIds": artistId,
            "includeItemTypes": "Audio",
            "recursive": "true",
            "parentId": allLibraries ? nil : libraryId,
            "sortBy": "Album,ParentIndexNumber,IndexNumber",
            "fields": Self.trackFields,
        ])
        return response.items
    }

    // MARK: - Home

    /// Songs most recently played, newest first.
    func recentlyPlayedTracks(limit: Int = 30) async throws -> [JFItem] {
        try await homeTracks(sortBy: "DatePlayed", limit: limit)
    }

    /// Songs played most often.
    func mostPlayedTracks(limit: Int = 30) async throws -> [JFItem] {
        try await homeTracks(sortBy: "PlayCount", limit: limit)
    }

    private func homeTracks(sortBy: String, limit: Int) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "includeItemTypes": "Audio",
            "recursive": "true",
            "parentId": libraryId,
            "filters": "IsPlayed",
            "sortBy": sortBy,
            "sortOrder": "Descending",
            "limit": String(limit),
            "fields": Self.trackFields,
        ])
        return response.items
    }

    /// Albums newest to the server first.
    func recentlyAddedAlbums(limit: Int = 20) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "includeItemTypes": "MusicAlbum",
            "recursive": "true",
            "parentId": libraryId,
            "sortBy": "DateCreated",
            "sortOrder": "Descending",
            "limit": String(limit),
        ])
        return response.items
    }

    // MARK: - Favorites

    /// Favorites of one type — MusicArtist, MusicAlbum or Audio.
    func favorites(type: String, limit: Int = 300) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "includeItemTypes": type,
            "recursive": "true",
            "parentId": libraryId,
            "filters": "IsFavorite",
            "sortBy": type == "Audio" ? "Album,ParentIndexNumber,IndexNumber" : "SortName",
            "limit": String(limit),
            "fields": type == "Audio" ? Self.trackFields : nil,
        ])
        return response.items
    }

    func setFavorite(_ isFavorite: Bool, itemId: String) async throws {
        let method = isFavorite ? "POST" : "DELETE"
        // 10.9 moved this off the per-user path; older servers only know the old one.
        do {
            try await send(method, "UserFavoriteItems/\(itemId)", query: ["userId": session.userId])
        } catch JellyfinError.http(404, _) {
            try await send(method, "Users/\(session.userId)/FavoriteItems/\(itemId)")
        }
    }

    // MARK: - Genres

    /// Music genres in the current library — empty when nothing is tagged.
    func genres() async throws -> [JFItem] {
        let response: ItemsResponse = try await get("MusicGenres", query: [
            "userId": session.userId,
            "parentId": libraryId,
            "sortBy": "SortName",
        ])
        return response.items
    }

    // MARK: - Similar

    /// Artists, albums or songs the server considers alike — works on any item.
    func similar(to itemId: String, limit: Int = 12) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items/\(itemId)/Similar", query: [
            "userId": session.userId,
            "limit": String(limit),
        ])
        return response.items
    }

    // MARK: - Instant Mix

    /// A radio-style list the server builds from any song, album, artist or
    /// playlist. Not scoped to a library — a mix should range freely.
    func instantMix(from itemId: String, limit: Int = 100) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items/\(itemId)/InstantMix", query: [
            "userId": session.userId,
            "limit": String(limit),
            "fields": Self.trackFields,
        ])
        return response.items
    }

    // MARK: - Voice requests
    //
    // Deliberately not scoped to `libraryId`: a spoken "play the story tape"
    // shouldn't fail because the picker happens to be on Music.

    /// Items of one type whose name matches `term`. `type` is a Jellyfin item
    /// type: MusicArtist, MusicAlbum, Playlist or Audio.
    func voiceSearch(_ term: String, type: String, limit: Int = 15) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "searchTerm": term,
            "includeItemTypes": type,
            "recursive": "true",
            "limit": String(limit),
            "fields": type == "Audio" ? Self.trackFields : nil,
        ])
        return response.items
    }

    /// A random selection from the current library, for "play some music".
    func randomTracks(limit: Int = 200) async throws -> [JFItem] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId,
            "includeItemTypes": "Audio",
            "recursive": "true",
            "parentId": libraryId,
            "sortBy": "Random",
            "limit": String(limit),
            "fields": Self.trackFields,
        ])
        return response.items
    }

    func item(id: String) async throws -> JFItem {
        try await get("Users/\(session.userId)/Items/\(id)", query: ["fields": Self.trackFields])
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

    /// Returns the URL to fetch, its MIME type, and a short label for the
    /// quality badge ("FLAC", "MP3 192").
    func streamInfo(for item: JFItem, quality: StreamQuality) -> (url: URL, contentType: String, label: String) {
        if quality == .original, canDirectPlay(item), let container = item.sourceContainer {
            let url = makeURL("Audio/\(item.id)/stream.\(container)", [
                "static": "true",
                "api_key": session.accessToken,
                "deviceId": Self.deviceId,
            ])
            return (url, Self.contentType(forContainer: container), Self.formatLabel(for: item))
        }

        // Server-side transcode to a format every Cast receiver accepts.
        let bitrate = quality.bitrate ?? 320_000
        return (transcodeURL(for: item, bitrate: bitrate), "audio/mpeg", "MP3 \(bitrate / 1000)")
    }

    private func transcodeURL(for item: JFItem, bitrate: Int) -> URL {
        makeURL("Audio/\(item.id)/universal", [
            "api_key": session.accessToken,
            "userId": session.userId,
            "deviceId": Self.deviceId,
            "container": "mp3",
            "audioCodec": "mp3",
            "transcodingContainer": "mp3",
            "transcodingProtocol": "http",
            "maxStreamingBitrate": String(bitrate),
            "audioBitRate": String(bitrate),
        ])
    }

    /// Formats iOS itself plays from a file. Wider than what Cast takes:
    /// downloads only ever play on this phone.
    private static let locallyPlayableContainers: Set<String> = ["mp3", "m4a", "mp4", "aac", "flac", "wav"]

    /// Where to download a track from, and the file extension to keep it under.
    func downloadInfo(for item: JFItem, quality: StreamQuality) -> (url: URL, fileExtension: String, label: String) {
        if quality == .original, let container = item.sourceContainer,
           Self.locallyPlayableContainers.contains(container) {
            let url = makeURL("Audio/\(item.id)/stream.\(container)", [
                "static": "true",
                "api_key": session.accessToken,
                "deviceId": Self.deviceId,
            ])
            return (url, container, Self.formatLabel(for: item))
        }
        let bitrate = quality.bitrate ?? 320_000
        return (transcodeURL(for: item, bitrate: bitrate), "mp3", "MP3 \(bitrate / 1000)")
    }

    /// "FLAC", "AAC", "MP3" — the codec if the server said, else the container.
    static func formatLabel(for item: JFItem) -> String {
        (item.sourceAudioCodec ?? item.sourceContainer ?? "audio").uppercased()
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
