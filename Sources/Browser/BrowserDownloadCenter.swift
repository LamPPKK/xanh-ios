import Foundation
import Observation
import WebKit

enum BrowserDownloadState: Equatable {
    case downloading
    case paused
    case completed
    case failed(String)
    case cancelled

    var label: String {
        switch self {
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Downloaded"
        case let .failed(message): "Failed: \(message)"
        case .cancelled: "Cancelled"
        }
    }
}

struct BrowserDownloadRequest {
    let sourceURL: URL?
    let suggestedFilename: String
    let tabID: TabID
    let profileID: ProfileID
    let isPrivate: Bool
}

struct BrowserDownloadPlan {
    let id: DownloadID
    let destinationURL: URL
}

@MainActor
@Observable
final class BrowserDownloadItem: Identifiable {
    let id: DownloadID
    let tabID: TabID?
    let profileID: ProfileID?
    let sourceURL: URL?
    let isPrivate: Bool
    let createdAt: Date
    var filename: String
    var destinationURL: URL
    var state: BrowserDownloadState
    @ObservationIgnored var progress: Progress?
    @ObservationIgnored var resumeData: Data?

    init(
        id: DownloadID = DownloadID(),
        tabID: TabID?,
        profileID: ProfileID?,
        sourceURL: URL?,
        isPrivate: Bool,
        createdAt: Date = .now,
        filename: String,
        destinationURL: URL,
        state: BrowserDownloadState,
        progress: Progress? = nil,
        resumeData: Data? = nil
    ) {
        self.id = id
        self.tabID = tabID
        self.profileID = profileID
        self.sourceURL = sourceURL
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.filename = filename
        self.destinationURL = destinationURL
        self.state = state
        self.progress = progress
        self.resumeData = resumeData
    }

    var canPause: Bool { state == .downloading }
    var canResume: Bool { state == .paused && resumeData != nil }
    var canShare: Bool { state == .completed }
}

enum BrowserDownloadError: LocalizedError, Equatable {
    case storageUnavailable
    case itemUnavailable
    case resumeUnavailable

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: "Xanh could not prepare download storage."
        case .itemUnavailable: "The download is no longer available."
        case .resumeUnavailable: "This server did not provide resumable download data."
        }
    }
}

enum BrowserDownloadResponsePolicy {
    static func allowsDownloadURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "blob"
    }

    static func shouldDownload(canShowMIMEType: Bool, contentDisposition: String?) -> Bool {
        !canShowMIMEType || contentDisposition?.lowercased().contains("attachment") == true
    }
}

@MainActor
@Observable
final class BrowserDownloadCenter {
    private(set) var items: [BrowserDownloadItem] = []
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let persistentRoot: URL
    @ObservationIgnored private let privateRoot: URL
    @ObservationIgnored private lazy var webKitDelegate = BrowserDownloadDelegate(center: self)
    @ObservationIgnored private var transports: [DownloadID: WKDownload] = [:]

    init(
        fileManager: FileManager = .default,
        persistentRoot: URL? = nil,
        privateRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.persistentRoot = persistentRoot ?? documents.appending(path: "Xanh Downloads", directoryHint: .isDirectory)
        self.privateRoot = privateRoot ?? caches.appending(path: "Xanh Private Downloads", directoryHint: .isDirectory)

        prepareStorageAndRestoreFiles()
    }

    var activeCount: Int {
        items.count { $0.state == .downloading }
    }

    var hasDownloads: Bool { !items.isEmpty }

    func accept(
        _ download: WKDownload,
        tabID: TabID,
        profileID: ProfileID,
        isPrivate: Bool,
        resuming id: DownloadID? = nil
    ) {
        webKitDelegate.accept(
            download,
            context: BrowserDownloadContext(
                tabID: tabID,
                profileID: profileID,
                isPrivate: isPrivate,
                existingID: id
            )
        )
    }

    func prepare(
        _ request: BrowserDownloadRequest,
        progress: Progress? = nil,
        transport: WKDownload? = nil,
        resuming existingID: DownloadID? = nil
    ) throws -> BrowserDownloadPlan {
        let root = request.isPrivate ? privateRoot : persistentRoot
        try ensureDirectory(root, excludedFromBackup: request.isPrivate)
        let filename = sanitizedFilename(request.suggestedFilename, sourceURL: request.sourceURL)
        let destination = uniqueDestination(for: filename, in: root)

        if let existingID {
            guard let item = item(withID: existingID),
                  item.profileID == request.profileID,
                  item.isPrivate == request.isPrivate else {
                throw BrowserDownloadError.itemUnavailable
            }
            item.filename = destination.lastPathComponent
            item.destinationURL = destination
            item.state = .downloading
            item.progress = progress
            item.resumeData = nil
            if let transport {
                transports[existingID] = transport
            }
            return BrowserDownloadPlan(id: existingID, destinationURL: destination)
        }

        let item = BrowserDownloadItem(
            tabID: request.tabID,
            profileID: request.profileID,
            sourceURL: request.sourceURL,
            isPrivate: request.isPrivate,
            filename: destination.lastPathComponent,
            destinationURL: destination,
            state: .downloading,
            progress: progress
        )
        items.insert(item, at: 0)
        if let transport {
            transports[item.id] = transport
        }
        return BrowserDownloadPlan(id: item.id, destinationURL: destination)
    }

    func pause(_ id: DownloadID) {
        guard let item = item(withID: id),
              item.state == .downloading,
              let download = transports[id] else { return }
        download.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self, let item = self.item(withID: id) else { return }
                self.transports[id] = nil
                item.progress = nil
                item.resumeData = resumeData
                item.state = resumeData == nil ? .cancelled : .paused
            }
        }
    }

    func resumeContext(for id: DownloadID) throws -> (item: BrowserDownloadItem, data: Data) {
        guard let item = item(withID: id) else { throw BrowserDownloadError.itemUnavailable }
        guard item.state == .paused, let data = item.resumeData else {
            throw BrowserDownloadError.resumeUnavailable
        }
        return (item, data)
    }

    func markResumeStarted(_ id: DownloadID) {
        item(withID: id)?.state = .downloading
    }

    func remove(_ id: DownloadID) {
        guard let item = item(withID: id) else { return }
        if item.state == .downloading {
            let destination = item.destinationURL
            transports[id]?.cancel { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isManagedFile(destination) else { return }
                    try? self.fileManager.removeItem(at: destination)
                }
            }
        }
        transports[id] = nil
        if isManagedFile(item.destinationURL) {
            try? fileManager.removeItem(at: item.destinationURL)
        }
        items.removeAll { $0.id == id }
    }

    func removePrivateDownloads(for profileID: ProfileID) {
        let privateIDs = items
            .filter { $0.isPrivate && $0.profileID == profileID }
            .map(\.id)
        for id in privateIDs {
            remove(id)
        }
    }

    func markFinished(_ id: DownloadID) {
        guard let item = item(withID: id) else { return }
        transports[id] = nil
        item.progress = nil
        item.resumeData = nil
        item.state = .completed
    }

    func markFailed(_ id: DownloadID, error: Error, resumeData: Data?) {
        guard let item = item(withID: id) else { return }
        transports[id] = nil
        item.progress = nil
        item.resumeData = resumeData
        if let resumeData, !resumeData.isEmpty {
            item.resumeData = resumeData
            item.state = .paused
        } else if (error as NSError).code == NSURLErrorCancelled {
            item.state = .cancelled
        } else {
            item.state = .failed(error.localizedDescription)
        }
    }

    func item(withID id: DownloadID) -> BrowserDownloadItem? {
        items.first { $0.id == id }
    }

    fileprivate func report(_ error: Error) {
        onError?(error.localizedDescription)
    }

    private func prepareStorageAndRestoreFiles() {
        try? fileManager.removeItem(at: privateRoot)
        try? ensureDirectory(privateRoot, excludedFromBackup: true)
        try? ensureDirectory(persistentRoot, excludedFromBackup: false)

        guard let urls = try? fileManager.contentsOfDirectory(
            at: persistentRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        items = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            return BrowserDownloadItem(
                tabID: nil,
                profileID: nil,
                sourceURL: nil,
                isPrivate: false,
                createdAt: .distantPast,
                filename: url.lastPathComponent,
                destinationURL: url,
                state: .completed
            )
        }
        .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    private func ensureDirectory(_ url: URL, excludedFromBackup: Bool) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            var directory = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = excludedFromBackup
            try directory.setResourceValues(values)
        } catch {
            throw BrowserDownloadError.storageUnavailable
        }
    }

    private func sanitizedFilename(_ suggested: String, sourceURL: URL?) -> String {
        let decoded = suggested.removingPercentEncoding ?? suggested
        let pathLeaf = decoded.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
        let sourceLeaf = sourceURL?.lastPathComponent.removingPercentEncoding
        let candidate = [pathLeaf, sourceLeaf]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? "download"
        let invalid = CharacterSet.controlCharacters
            .union(.illegalCharacters)
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        let scalars = candidate.unicodeScalars.map {
            invalid.contains($0) || $0.properties.generalCategory == .format ? "_" : String($0)
        }
        var safe = scalars.joined().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if safe.isEmpty || safe == "." || safe == ".." {
            safe = "download"
        }
        return cappedFilename(safe)
    }

    private func cappedFilename(_ filename: String, maximumUTF8Bytes: Int = 180) -> String {
        guard filename.utf8.count > maximumUTF8Bytes else { return filename }
        let value = filename as NSString
        let rawExtension = String(value.pathExtension.prefix(16))
        let candidateSuffix = rawExtension.isEmpty ? "" : ".\(rawExtension)"
        let suffix = candidateSuffix.utf8.count <= 32 ? candidateSuffix : ""
        let stem = suffix.isEmpty ? filename : value.deletingPathExtension
        var result = ""
        for character in stem {
            let candidate = result + String(character)
            guard (candidate + suffix).utf8.count <= maximumUTF8Bytes else { break }
            result = candidate
        }
        if result.isEmpty {
            result = "download"
        }
        return result + suffix
    }

    private func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let original = directory.appending(path: filename)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let value = filename as NSString
        let stem = value.deletingPathExtension
        let pathExtension = value.pathExtension
        for suffix in 1 ... 9_999 {
            let candidateName = pathExtension.isEmpty
                ? "\(stem) (\(suffix))"
                : "\(stem) (\(suffix)).\(pathExtension)"
            let candidate = directory.appending(path: candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appending(path: "\(UUID().uuidString)-\(filename)")
    }

    private func isManagedFile(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        return standardized.hasPrefix(persistentRoot.standardizedFileURL.path + "/")
            || standardized.hasPrefix(privateRoot.standardizedFileURL.path + "/")
    }
}

private struct BrowserDownloadContext {
    let tabID: TabID
    let profileID: ProfileID
    let isPrivate: Bool
    let existingID: DownloadID?
}

@MainActor
private final class BrowserDownloadDelegate: NSObject, WKDownloadDelegate {
    private weak var center: BrowserDownloadCenter?
    private var contexts: [ObjectIdentifier: BrowserDownloadContext] = [:]
    private var identifiers: [ObjectIdentifier: DownloadID] = [:]

    init(center: BrowserDownloadCenter) {
        self.center = center
    }

    func accept(_ download: WKDownload, context: BrowserDownloadContext) {
        contexts[ObjectIdentifier(download)] = context
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let key = ObjectIdentifier(download)
        guard let center, let context = contexts[key] else {
            return nil
        }
        let request = BrowserDownloadRequest(
            sourceURL: download.originalRequest?.url ?? response.url,
            suggestedFilename: suggestedFilename,
            tabID: context.tabID,
            profileID: context.profileID,
            isPrivate: context.isPrivate
        )
        do {
            let plan = try center.prepare(
                request,
                progress: download.progress,
                transport: download,
                resuming: context.existingID
            )
            identifiers[key] = plan.id
            return plan.destinationURL
        } catch {
            contexts[key] = nil
            if let downloadError = error as? BrowserDownloadError,
               case .itemUnavailable = downloadError {
                return nil
            }
            center.report(error)
            return nil
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        if let id = identifiers[key] {
            center?.markFinished(id)
        }
        clear(key)
    }

    func download(
        _ download: WKDownload,
        decidedPolicyForHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest
    ) async -> WKDownload.RedirectPolicy {
        BrowserDownloadResponsePolicy.allowsDownloadURL(newRequest.url) ? .allow : .cancel
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        if let id = identifiers[key] {
            center?.markFailed(id, error: error, resumeData: resumeData)
        }
        clear(key)
    }

    private func clear(_ key: ObjectIdentifier) {
        contexts[key] = nil
        identifiers[key] = nil
    }
}
