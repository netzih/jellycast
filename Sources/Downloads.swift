import Foundation
import Network
import UIKit

/// One song kept on the phone, with everything needed to show and play it
/// without the server.
struct DownloadedTrack: Codable, Identifiable {
    let item: JFItem
    let fileName: String
    /// "FLAC", "MP3 192" — what was actually saved.
    let formatLabel: String
    let bytes: Int64
    let artworkFileName: String?
    let downloadedAt: Date

    var id: String { item.id }
}

struct DownloadedAlbum: Identifiable {
    let id: String
    let title: String
    let artist: String
    let tracks: [JFItem]
}

enum DownloadState: Equatable {
    case none
    /// 0…1; 0 also covers "waiting for a free connection".
    case downloading(Double)
    case downloaded
}

/// Downloads songs in a background `URLSession`, so they finish with the
/// phone locked or the app closed, and keeps an index of what's on disk.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()
    static let sessionIdentifier = "com.yitzchokwagner.jellycast.downloads"

    @Published private(set) var downloaded: [String: DownloadedTrack] = [:]
    /// In-flight downloads by item id, with progress.
    @Published private(set) var active: [String: Double] = [:]

    /// Handed over by the app delegate when iOS wakes the app for finished
    /// background downloads; called once every event has been delivered.
    var backgroundCompletionHandler: (() -> Void)?

    /// Metadata for in-flight downloads. On disk too, because a background
    /// download can finish after the app that started it was killed.
    private var pending: [String: PendingDownload] = [:]
    private let delegate = DownloadSessionDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private struct PendingDownload: Codable {
        let item: JFItem
        let fileExtension: String
        let formatLabel: String
        let artworkURL: URL?
    }

    // MARK: - Files

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Re-downloadable, so keep it out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    private static let indexURL = directory.appendingPathComponent("index.json")
    private static let pendingURL = directory.appendingPathComponent("pending.json")

    private init() {
        downloaded = Self.read([String: DownloadedTrack].self, from: Self.indexURL) ?? [:]
        // Drop entries whose file has gone missing — say, after a restore.
        downloaded = downloaded.filter {
            FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent($0.value.fileName).path)
        }
        pending = Self.read([String: PendingDownload].self, from: Self.pendingURL) ?? [:]

        delegate.store = self
        // Re-attach to downloads still running from a previous launch.
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription.flatMap(DownloadSessionDelegate.itemId(from:)) })
            Task { @MainActor in
                for id in self.pending.keys where !running.contains(id) && self.downloaded[id] == nil {
                    self.pending[id] = nil
                }
                for id in running { self.active[id] = self.active[id] ?? 0 }
                self.savePending()
            }
        }
    }

    // MARK: - Queries

    func state(for itemId: String) -> DownloadState {
        if downloaded[itemId] != nil { return .downloaded }
        if let progress = active[itemId] { return .downloading(progress) }
        return .none
    }

    /// The file to play, if this song is on the phone.
    func localURL(for itemId: String) -> URL? {
        downloaded[itemId].map { Self.directory.appendingPathComponent($0.fileName) }
    }

    func localArtworkURL(for itemId: String) -> URL? {
        downloaded[itemId]?.artworkFileName.map { Self.directory.appendingPathComponent($0) }
    }

    /// True when every one of these is on the phone.
    func allDownloaded(_ items: [JFItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { downloaded[$0.id] != nil }
    }

    var totalBytes: Int64 { downloaded.values.reduce(0) { $0 + $1.bytes } }

    /// Downloaded songs grouped by album, albums by name, songs in disc order.
    var albums: [DownloadedAlbum] {
        let groups = Dictionary(grouping: downloaded.values.map(\.item)) { $0.albumId ?? $0.album ?? $0.id }
        return groups
            .map { key, tracks -> DownloadedAlbum in
                let sorted = tracks.sorted {
                    ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0, $0.name) <
                        ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0, $1.name)
                }
                let first = sorted[0]
                return DownloadedAlbum(id: key, title: first.album ?? first.name, artist: first.displayArtist, tracks: sorted)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Changes

    func download(_ items: [JFItem]) {
        guard let client = AppState.shared.client else { return }
        let quality = AppState.shared.downloadQuality
        for item in items where downloaded[item.id] == nil && active[item.id] == nil {
            let info = client.downloadInfo(for: item, quality: quality)
            pending[item.id] = PendingDownload(
                item: item, fileExtension: info.fileExtension, formatLabel: info.label,
                artworkURL: client.artworkURL(for: item, maxHeight: 600)
            )
            active[item.id] = 0
            let task = session.downloadTask(with: info.url)
            task.taskDescription = DownloadSessionDelegate.taskDescription(itemId: item.id, fileExtension: info.fileExtension)
            task.resume()
        }
        savePending()
    }

    func remove(_ itemIds: [String]) {
        for id in itemIds {
            guard let entry = downloaded.removeValue(forKey: id) else { continue }
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(entry.fileName))
        }
        removeOrphanedArtwork()
        saveIndex()
    }

    /// Deletes every download and cancels any still running.
    func removeAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        pending = [:]
        active = [:]
        remove(Array(downloaded.keys))
        savePending()
    }

    // MARK: - Session events (from the delegate, already on the main actor)

    fileprivate func progress(_ fraction: Double, for itemId: String) {
        guard active[itemId] != nil else { return }
        // Publishing every chunk would redraw lists hundreds of times a second.
        if fraction - (active[itemId] ?? 0) >= 0.02 || fraction >= 1 { active[itemId] = fraction }
    }

    fileprivate func finished(itemId: String, fileName: String, bytes: Int64) {
        guard let info = pending.removeValue(forKey: itemId) else {
            // Nothing to describe it with, so it can't be shown or played.
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(fileName))
            return
        }
        active[itemId] = nil
        let artworkName = "art-\(info.item.artworkItemId).jpg"
        downloaded[itemId] = DownloadedTrack(
            item: info.item, fileName: fileName, formatLabel: info.formatLabel, bytes: bytes,
            artworkFileName: info.artworkURL == nil ? nil : artworkName, downloadedAt: Date()
        )
        saveIndex()
        savePending()
        if let artworkURL = info.artworkURL { fetchArtwork(from: artworkURL, named: artworkName) }
    }

    fileprivate func failed(itemId: String, message: String) {
        pending[itemId] = nil
        active[itemId] = nil
        savePending()
        print("[JellyCast] download of \(itemId) failed: \(message)")
    }

    fileprivate func finishedBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    // MARK: - Internals

    /// One image per album, shared by its songs, so offline lists have art.
    private func fetchArtwork(from url: URL, named name: String) {
        let destination = Self.directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        Task.detached {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            try? data.write(to: destination)
        }
    }

    private func removeOrphanedArtwork() {
        let inUse = Set(downloaded.values.compactMap(\.artworkFileName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        for file in files where file.hasPrefix("art-") && !inUse.contains(file) {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(file))
        }
    }

    private func saveIndex() { Self.write(downloaded, to: Self.indexURL) }
    private func savePending() { Self.write(pending, to: Self.pendingURL) }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.jellyfin.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// URLSession calls back on its own queue. The finished file must be moved
/// before `didFinishDownloadingTo` returns, so that happens here, synchronously;
/// only the bookkeeping hops to the main actor.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    weak var store: DownloadStore?

    static func taskDescription(itemId: String, fileExtension: String) -> String {
        "\(itemId)|\(fileExtension)"
    }

    static func itemId(from description: String) -> String? {
        description.split(separator: "|").first.map(String.init)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(Self.itemId(from:)) else { return }
        // Transcoded streams don't announce a length; show them as indeterminate.
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak store] in store?.progress(fraction, for: id) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let parts = downloadTask.taskDescription?.split(separator: "|"), parts.count == 2 else { return }
        let id = String(parts[0]), ext = String(parts[1])

        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            Task { @MainActor [weak store] in store?.failed(itemId: id, message: "HTTP \(status)") }
            return
        }

        let fileName = "\(id).\(ext)"
        let destination = DownloadStore.directory.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Task { @MainActor [weak store] in store?.finished(itemId: id, fileName: fileName, bytes: bytes) }
        } catch {
            Task { @MainActor [weak store] in store?.failed(itemId: id, message: error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(Self.itemId(from:)) else { return }
        // Cancelled by "remove all" — nothing to report.
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor [weak store] in store?.failed(itemId: id, message: error.localizedDescription) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak store] in store?.finishedBackgroundEvents() }
    }
}

/// Whether the phone is on mobile data (or a hotspot), for picking stream quality.
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private(set) var isExpensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.isExpensive = path.isExpensive }
        monitor.start(queue: DispatchQueue(label: "JellyCast.network"))
    }
}
