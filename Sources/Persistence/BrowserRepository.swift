import Foundation

enum BrowserSyncStatus: Equatable, Sendable {
    case starting
    case syncing
    case localOnly
    case available
    case degraded(String)

    var label: String {
        switch self {
        case .starting: "SYNC STARTING"
        case .syncing: "SYNCING"
        case .localOnly: "LOCAL ONLY"
        case .available: "ICLOUD READY"
        case .degraded: "SYNC DEGRADED"
        }
    }

    var detail: String {
        switch self {
        case .starting: "Checking iCloud availability. Browsing uses the local replica meanwhile."
        case .syncing: "Exchanging browser metadata with the private iCloud database."
        case .localOnly: "iCloud sync is disabled for this build. Browsing data remains local."
        case .available: "The local replica is ready to synchronize regular browser metadata."
        case let .degraded(message): message
        }
    }
}

@MainActor
protocol BrowserRepository: AnyObject {
    var syncStatus: BrowserSyncStatus { get }
    var onExternalChange: (@MainActor @Sendable () -> Void)? { get set }
    var onSyncStatusChange: (@MainActor @Sendable (BrowserSyncStatus) -> Void)? { get set }
    func load() async throws -> BrowserSnapshot
    func save(_ snapshot: BrowserSnapshot) throws
    func savePortableImport(_ snapshot: BrowserSnapshot, importedAt: Date) throws
}

@MainActor
final class InMemoryBrowserRepository: BrowserRepository {
    private var snapshot: BrowserSnapshot
    private(set) var syncStatus: BrowserSyncStatus
    var onExternalChange: (@MainActor @Sendable () -> Void)?
    var onSyncStatusChange: (@MainActor @Sendable (BrowserSyncStatus) -> Void)?

    init(snapshot: BrowserSnapshot = .initial(), syncStatus: BrowserSyncStatus = .localOnly) {
        self.snapshot = snapshot
        self.syncStatus = syncStatus
    }

    func load() async throws -> BrowserSnapshot {
        snapshot
    }

    func save(_ snapshot: BrowserSnapshot) throws {
        self.snapshot = snapshot
    }

    func savePortableImport(_ snapshot: BrowserSnapshot, importedAt: Date) throws {
        self.snapshot = XanhPortableBackup.rebasedForImport(snapshot, at: importedAt)
    }

    func updateSyncStatus(_ status: BrowserSyncStatus) {
        syncStatus = status
        onSyncStatusChange?(status)
    }
}
