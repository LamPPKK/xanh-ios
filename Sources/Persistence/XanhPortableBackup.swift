import Foundation

enum XanhPortableBackupError: Error, Equatable, LocalizedError {
    case emptyDocument
    case fileTooLarge(maximumBytes: Int)
    case malformedDocument
    case incompatibleFormat
    case unsupportedSchemaVersion(Int)
    case unknownField(String)
    case duplicateField(String)
    case privateData(String)
    case invalidReference(String)
    case invalidValue(String)
    case duplicateIdentifier(String)
    case limitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .emptyDocument:
            "The selected backup is empty."
        case let .fileTooLarge(maximumBytes):
            "The backup is larger than the \(maximumBytes / 1_048_576) MB safety limit."
        case .malformedDocument:
            "The selected file is not a valid Xanh backup."
        case .incompatibleFormat:
            "The selected file belongs to a different application or backup format."
        case let .unsupportedSchemaVersion(version):
            "Backup schema version \(version) is not supported."
        case let .unknownField(field):
            "The backup contains an unsupported field: \(field)."
        case let .duplicateField(field):
            "The backup contains a duplicate field: \(field)."
        case let .privateData(detail):
            "The backup was rejected because it contains private or ephemeral data: \(detail)."
        case let .invalidReference(detail):
            "The backup contains an invalid relationship: \(detail)."
        case let .invalidValue(detail):
            "The backup contains an invalid value: \(detail)."
        case let .duplicateIdentifier(detail):
            "The backup contains a duplicate identifier: \(detail)."
        case let .limitExceeded(detail):
            "The backup exceeds a safe item limit: \(detail)."
        }
    }
}

enum XanhPortableBackup {
    static let formatIdentifier = "io.github.lamppkk.xanhbrowser.portable-backup"
    static let applicationIdentifier = "io.github.lamppkk.xanhbrowser.ios"
    static let schemaVersion = 1
    static let maximumByteCount = 16 * 1_048_576

    private static let maximumProfiles = 128
    private static let maximumSpaces = 2_048
    private static let maximumTabs = 20_000
    private static let maximumArchivedTabs = 20_000
    private static let maximumBookmarks = 50_000
    private static let maximumHistoryVisits = 100_000
    private static let maximumSiteExceptions = 64_000
    private static let forbiddenFieldTokens = [
        "private",
        "ephemeral",
        "credential",
        "password",
        "cookie",
        "cache",
        "download",
        "profiledeletioncleanup",
    ]

    private struct Envelope: Codable {
        let format: String
        let schemaVersion: Int
        let application: String
        let exportedAt: Date
        let engineContractVersion: String
        let data: Payload
    }

    private struct Payload: Codable {
        let profiles: [BrowserProfile]
        let spaces: [BrowserSpace]
        let tabs: [BrowserTab]
        let archivedTabs: [ArchivedTab]
        let bookmarks: [Bookmark]
        let history: [HistoryVisit]
        let settings: BrowserSettings
        let siteExceptions: [BlockerSiteException]

        var snapshot: BrowserSnapshot {
            BrowserSnapshot(
                profiles: profiles,
                spaces: spaces,
                tabs: tabs,
                archivedTabs: archivedTabs,
                blockerSiteExceptions: siteExceptions,
                bookmarks: bookmarks,
                history: history,
                profileDeletionCleanups: [],
                settings: settings
            )
        }
    }

    static func encode(_ snapshot: BrowserSnapshot, exportedAt: Date = .now) throws -> Data {
        let regularProfileIDs = Set(
            snapshot.profiles.lazy.filter { $0.storageMode == .persistent }.map(\.id)
        )
        let regularSpaces = snapshot.spaces.filter {
            $0.storageMode == .persistent && regularProfileIDs.contains($0.profileID)
        }
        let regularSpaceIDs = Set(regularSpaces.map(\.id))
        let regularTabs = snapshot.tabs.filter {
            $0.storageMode == .persistent && regularSpaceIDs.contains($0.spaceID)
        }
        let settings = BrowserSettings(
            historySyncEnabled: snapshot.settings.historySyncEnabled,
            lastSelectedSpaceID: snapshot.settings.lastSelectedSpaceID.flatMap {
                regularSpaceIDs.contains($0) ? $0 : nil
            },
            automaticArchiveInterval: snapshot.settings.automaticArchiveInterval,
            modifiedAt: snapshot.settings.modifiedAt
        )
        let payload = Payload(
            profiles: snapshot.profiles.filter { regularProfileIDs.contains($0.id) },
            spaces: regularSpaces,
            tabs: regularTabs,
            archivedTabs: snapshot.archivedTabs.filter { regularProfileIDs.contains($0.profileID) },
            bookmarks: snapshot.bookmarks.filter { regularProfileIDs.contains($0.profileID) },
            history: snapshot.history.filter { regularProfileIDs.contains($0.profileID) },
            settings: settings,
            siteExceptions: snapshot.blockerSiteExceptions.filter { regularProfileIDs.contains($0.profileID) }
        )
        try validate(payload)
        let envelope = Envelope(
            format: formatIdentifier,
            schemaVersion: schemaVersion,
            application: applicationIdentifier,
            exportedAt: exportedAt,
            engineContractVersion: XanhWebViewEngineInfo.current.contractVersion,
            data: payload
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(envelope)
        guard encoded.count <= maximumByteCount else {
            throw XanhPortableBackupError.fileTooLarge(maximumBytes: maximumByteCount)
        }
        return encoded
    }

    static func decode(_ encoded: Data) throws -> BrowserSnapshot {
        guard !encoded.isEmpty else { throw XanhPortableBackupError.emptyDocument }
        guard encoded.count <= maximumByteCount else {
            throw XanhPortableBackupError.fileTooLarge(maximumBytes: maximumByteCount)
        }
        var duplicateKeyValidator = XanhJSONDuplicateKeyValidator(data: encoded)
        try duplicateKeyValidator.validate()
        do {
            let object = try JSONSerialization.jsonObject(with: encoded)
            try validateDocumentShape(object)
        } catch let error as XanhPortableBackupError {
            throw error
        } catch {
            throw XanhPortableBackupError.malformedDocument
        }

        let envelope: Envelope
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            envelope = try decoder.decode(Envelope.self, from: encoded)
        } catch {
            throw XanhPortableBackupError.malformedDocument
        }
        guard envelope.format == formatIdentifier,
              envelope.application == applicationIdentifier else {
            throw XanhPortableBackupError.incompatibleFormat
        }
        guard envelope.schemaVersion == schemaVersion else {
            throw XanhPortableBackupError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.engineContractVersion == XanhWebViewEngineInfo.current.contractVersion else {
            throw XanhPortableBackupError.invalidValue("engine contract version")
        }
        try validate(envelope.data)
        return envelope.data.snapshot
    }

    static func rebasedForImport(_ snapshot: BrowserSnapshot, at date: Date) -> BrowserSnapshot {
        var rebased = snapshot
        for index in rebased.profiles.indices { rebased.profiles[index].modifiedAt = date }
        for index in rebased.spaces.indices { rebased.spaces[index].modifiedAt = date }
        for index in rebased.tabs.indices { rebased.tabs[index].modifiedAt = date }
        for index in rebased.archivedTabs.indices { rebased.archivedTabs[index].modifiedAt = date }
        for index in rebased.bookmarks.indices { rebased.bookmarks[index].modifiedAt = date }
        for index in rebased.history.indices { rebased.history[index].modifiedAt = date }
        for index in rebased.blockerSiteExceptions.indices {
            rebased.blockerSiteExceptions[index].modifiedAt = date
        }
        rebased.settings.modifiedAt = date
        return rebased
    }

    private static func validate(_ payload: Payload) throws {
        try requireCount(payload.profiles.count, maximum: maximumProfiles, label: "profiles")
        try requireCount(payload.spaces.count, maximum: maximumSpaces, label: "spaces")
        try requireCount(payload.tabs.count, maximum: maximumTabs, label: "tabs")
        try requireCount(payload.archivedTabs.count, maximum: maximumArchivedTabs, label: "archive entries")
        try requireCount(payload.bookmarks.count, maximum: maximumBookmarks, label: "bookmarks")
        try requireCount(payload.history.count, maximum: maximumHistoryVisits, label: "history visits")
        try requireCount(payload.siteExceptions.count, maximum: maximumSiteExceptions, label: "site exceptions")
        guard !payload.profiles.isEmpty else {
            throw XanhPortableBackupError.invalidValue("at least one regular profile is required")
        }
        guard !payload.spaces.isEmpty else {
            throw XanhPortableBackupError.invalidValue("at least one regular space is required")
        }

        try requireUnique(payload.profiles.map(\.id), label: "profile")
        try requireUnique(payload.spaces.map(\.id), label: "space")
        try requireUnique(payload.tabs.map(\.id), label: "tab")
        try requireUnique(payload.archivedTabs.map(\.id), label: "archive entry")
        try requireUnique(payload.bookmarks.map(\.id), label: "bookmark")
        try requireUnique(payload.history.map(\.id), label: "history visit")
        try requireUnique(payload.siteExceptions.map(\.id), label: "site exception")

        let profilesByID = Dictionary(uniqueKeysWithValues: payload.profiles.map { ($0.id, $0) })
        let spacesByID = Dictionary(uniqueKeysWithValues: payload.spaces.map { ($0.id, $0) })
        let tabsByID = Dictionary(uniqueKeysWithValues: payload.tabs.map { ($0.id, $0) })

        for profile in payload.profiles {
            guard profile.storageMode == .persistent else {
                throw XanhPortableBackupError.privateData("profile \(profile.id.rawValue.uuidString)")
            }
            try requireText(profile.name, maximumLength: 128, label: "profile name")
            guard (profile.colorHex.count == 6 || profile.colorHex.count == 8),
                  profile.colorHex.allSatisfy({ $0.isHexDigit }) else {
                throw XanhPortableBackupError.invalidValue("profile color")
            }
        }
        for space in payload.spaces {
            guard space.storageMode == .persistent else {
                throw XanhPortableBackupError.privateData("space \(space.id.rawValue.uuidString)")
            }
            guard profilesByID[space.profileID]?.storageMode == .persistent else {
                throw XanhPortableBackupError.invalidReference("space profile")
            }
            try requireText(space.name, maximumLength: 128, label: "space name")
            if let selectedTabID = space.selectedTabID {
                guard tabsByID[selectedTabID]?.spaceID == space.id else {
                    throw XanhPortableBackupError.invalidReference("selected tab")
                }
            }
        }
        for profileID in profilesByID.keys where !payload.spaces.contains(where: { $0.profileID == profileID }) {
            throw XanhPortableBackupError.invalidReference("profile without a space")
        }
        for spaceID in spacesByID.keys where !payload.tabs.contains(where: { $0.spaceID == spaceID }) {
            throw XanhPortableBackupError.invalidReference("space without a tab")
        }
        for tab in payload.tabs {
            guard tab.storageMode == .persistent else {
                throw XanhPortableBackupError.privateData("tab \(tab.id.rawValue.uuidString)")
            }
            guard spacesByID[tab.spaceID]?.storageMode == .persistent else {
                throw XanhPortableBackupError.invalidReference("tab space")
            }
            try requireText(tab.title, maximumLength: 1_024, label: "tab title", allowEmpty: true)
            if let url = tab.url { try validateURL(url, label: "tab URL") }
        }
        for archived in payload.archivedTabs {
            guard let source = spacesByID[archived.sourceSpaceID],
                  source.profileID == archived.profileID,
                  profilesByID[archived.profileID] != nil else {
                throw XanhPortableBackupError.invalidReference("archive profile or source space")
            }
            try validateURL(archived.url, label: "archive URL")
            try requireText(archived.title, maximumLength: 1_024, label: "archive title", allowEmpty: true)
        }
        for bookmark in payload.bookmarks {
            guard profilesByID[bookmark.profileID] != nil else {
                throw XanhPortableBackupError.invalidReference("bookmark profile")
            }
            try validateURL(bookmark.url, label: "bookmark URL")
            try requireText(bookmark.title, maximumLength: 1_024, label: "bookmark title", allowEmpty: true)
        }
        for visit in payload.history {
            guard profilesByID[visit.profileID] != nil else {
                throw XanhPortableBackupError.invalidReference("history profile")
            }
            try validateURL(visit.url, label: "history URL")
            try requireText(visit.title, maximumLength: 1_024, label: "history title", allowEmpty: true)
        }
        var exceptionsPerProfile: [ProfileID: Int] = [:]
        var exceptionKeys: Set<String> = []
        for exception in payload.siteExceptions {
            guard profilesByID[exception.profileID] != nil else {
                throw XanhPortableBackupError.invalidReference("site-exception profile")
            }
            guard let normalized = BlockerSitePolicy.normalizedHost(exception.host),
                  normalized == exception.host else {
                throw XanhPortableBackupError.invalidValue("site-exception hostname")
            }
            let key = "\(exception.profileID.rawValue.uuidString)|\(normalized)"
            guard exceptionKeys.insert(key).inserted else {
                throw XanhPortableBackupError.duplicateIdentifier("site-exception hostname")
            }
            exceptionsPerProfile[exception.profileID, default: 0] += 1
            guard exceptionsPerProfile[exception.profileID, default: 0] <= 500 else {
                throw XanhPortableBackupError.limitExceeded("more than 500 site exceptions for one profile")
            }
        }
        if let lastSelectedSpaceID = payload.settings.lastSelectedSpaceID,
           spacesByID[lastSelectedSpaceID] == nil {
            throw XanhPortableBackupError.invalidReference("last selected space")
        }
    }

    private static func validateURL(_ url: URL, label: String) throws {
        guard url.absoluteString.utf8.count <= 8_192,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw XanhPortableBackupError.invalidValue(label)
        }
        guard components.user == nil, components.password == nil else {
            throw XanhPortableBackupError.privateData("credentials embedded in \(label)")
        }
    }

    private static func requireCount(_ count: Int, maximum: Int, label: String) throws {
        guard count <= maximum else {
            throw XanhPortableBackupError.limitExceeded(label)
        }
    }

    private static func requireUnique<ID: Hashable>(_ identifiers: [ID], label: String) throws {
        guard Set(identifiers).count == identifiers.count else {
            throw XanhPortableBackupError.duplicateIdentifier(label)
        }
    }

    private static func requireText(
        _ value: String,
        maximumLength: Int,
        label: String,
        allowEmpty: Bool = false
    ) throws {
        guard value.utf8.count <= maximumLength,
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XanhPortableBackupError.invalidValue(label)
        }
    }

    private static func validateDocumentShape(_ value: Any) throws {
        guard let root = value as? [String: Any] else {
            throw XanhPortableBackupError.malformedDocument
        }
        try requireAllowedKeys(
            root,
            allowed: ["format", "schemaVersion", "application", "exportedAt", "engineContractVersion", "data"],
            path: "root"
        )
        guard let payload = root["data"] as? [String: Any] else {
            throw XanhPortableBackupError.malformedDocument
        }
        try requireAllowedKeys(
            payload,
            allowed: ["profiles", "spaces", "tabs", "archivedTabs", "bookmarks", "history", "settings", "siteExceptions"],
            path: "root.data"
        )

        try validateRecords(
            in: payload,
            key: "profiles",
            allowed: ["id", "name", "colorHex", "storageMode", "searchProvider", "blockerEnabled", "modifiedAt"],
            identifierKeys: ["id"]
        )
        try validateRecords(
            in: payload,
            key: "spaces",
            allowed: ["id", "profileID", "name", "sortIndex", "selectedTabID", "storageMode", "modifiedAt"],
            identifierKeys: ["id", "profileID", "selectedTabID"]
        )
        try validateRecords(
            in: payload,
            key: "tabs",
            allowed: ["id", "spaceID", "url", "title", "sortIndex", "lastActiveAt", "pinnedAt", "storageMode", "modifiedAt"],
            identifierKeys: ["id", "spaceID"]
        )
        try validateRecords(
            in: payload,
            key: "archivedTabs",
            allowed: ["id", "profileID", "sourceSpaceID", "url", "title", "archivedAt", "pinnedAt", "modifiedAt"],
            identifierKeys: ["id", "profileID", "sourceSpaceID"]
        )
        try validateRecords(
            in: payload,
            key: "bookmarks",
            allowed: ["id", "profileID", "url", "title", "createdAt", "modifiedAt"],
            identifierKeys: ["id", "profileID"]
        )
        try validateRecords(
            in: payload,
            key: "history",
            allowed: ["id", "profileID", "url", "title", "visitedAt", "modifiedAt"],
            identifierKeys: ["id", "profileID"]
        )
        try validateRecords(
            in: payload,
            key: "siteExceptions",
            allowed: ["id", "profileID", "host", "createdAt", "modifiedAt"],
            identifierKeys: ["id", "profileID"]
        )

        guard let settings = payload["settings"] as? [String: Any] else {
            throw XanhPortableBackupError.malformedDocument
        }
        try requireAllowedKeys(
            settings,
            allowed: ["historySyncEnabled", "lastSelectedSpaceID", "automaticArchiveInterval", "modifiedAt"],
            path: "root.data.settings"
        )
        if let selectedSpaceID = settings["lastSelectedSpaceID"], !(selectedSpaceID is NSNull) {
            try validateIdentifier(selectedSpaceID, path: "root.data.settings.lastSelectedSpaceID")
        }
    }

    private static func validateRecords(
        in payload: [String: Any],
        key: String,
        allowed: Set<String>,
        identifierKeys: Set<String>
    ) throws {
        guard let records = payload[key] as? [Any] else {
            throw XanhPortableBackupError.malformedDocument
        }
        for (index, value) in records.enumerated() {
            guard let record = value as? [String: Any] else {
                throw XanhPortableBackupError.malformedDocument
            }
            let path = "root.data.\(key)[\(index)]"
            try requireAllowedKeys(record, allowed: allowed, path: path)
            for identifierKey in identifierKeys {
                guard let identifier = record[identifierKey], !(identifier is NSNull) else { continue }
                try validateIdentifier(identifier, path: "\(path).\(identifierKey)")
            }
        }
    }

    private static func validateIdentifier(_ value: Any, path: String) throws {
        guard let identifier = value as? [String: Any] else {
            throw XanhPortableBackupError.malformedDocument
        }
        try requireAllowedKeys(identifier, allowed: ["rawValue"], path: path)
    }

    private static func requireAllowedKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        path: String
    ) throws {
        for key in object.keys where !allowed.contains(key) {
            let normalizedKey = key.lowercased()
            if forbiddenFieldTokens.contains(where: normalizedKey.contains) {
                throw XanhPortableBackupError.privateData("field \(path).\(key)")
            }
            throw XanhPortableBackupError.unknownField("\(path).\(key)")
        }
    }
}

private struct XanhJSONDuplicateKeyValidator {
    private static let maximumNestingDepth = 64
    private static let maximumKeyByteCount = 256
    private static let maximumPathByteCount = 4_096
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func validate() throws {
        try parseValue(path: "root", depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw XanhPortableBackupError.malformedDocument
        }
    }

    private mutating func parseValue(path: String, depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw XanhPortableBackupError.limitExceeded("JSON nesting depth")
        }
        skipWhitespace()
        guard index < bytes.count else {
            throw XanhPortableBackupError.malformedDocument
        }
        switch bytes[index] {
        case 0x7B:
            try parseObject(path: path, depth: depth)
        case 0x5B:
            try parseArray(path: path, depth: depth)
        case 0x22:
            _ = try parseString()
        default:
            try parsePrimitive()
        }
    }

    private mutating func parseObject(path: String, depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }

        var keys: Set<String> = []
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw XanhPortableBackupError.malformedDocument
            }
            let key = try parseString()
            guard key.utf8.count <= Self.maximumKeyByteCount else {
                throw XanhPortableBackupError.limitExceeded("JSON key length")
            }
            guard keys.insert(key).inserted else {
                throw XanhPortableBackupError.duplicateField("\(path).\(key)")
            }
            skipWhitespace()
            guard consume(0x3A) else {
                throw XanhPortableBackupError.malformedDocument
            }
            let childPath = "\(path).\(key)"
            guard childPath.utf8.count <= Self.maximumPathByteCount else {
                throw XanhPortableBackupError.limitExceeded("JSON path length")
            }
            try parseValue(path: childPath, depth: depth + 1)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else {
                throw XanhPortableBackupError.malformedDocument
            }
        }
    }

    private mutating func parseArray(path: String, depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }

        var itemIndex = 0
        while true {
            let childPath = "\(path)[\(itemIndex)]"
            guard childPath.utf8.count <= Self.maximumPathByteCount else {
                throw XanhPortableBackupError.limitExceeded("JSON path length")
            }
            try parseValue(path: childPath, depth: depth + 1)
            itemIndex += 1
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else {
                throw XanhPortableBackupError.malformedDocument
            }
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                index += 1
                do {
                    return try JSONDecoder().decode(
                        String.self,
                        from: Data(bytes[start..<index])
                    )
                } catch {
                    throw XanhPortableBackupError.malformedDocument
                }
            case 0x5C:
                index += 2
            case 0x00 ... 0x1F:
                throw XanhPortableBackupError.malformedDocument
            default:
                index += 1
            }
        }
        throw XanhPortableBackupError.malformedDocument
    }

    private mutating func parsePrimitive() throws {
        let start = index
        while index < bytes.count {
            switch bytes[index] {
            case 0x09, 0x0A, 0x0D, 0x20, 0x2C, 0x5D, 0x7D:
                guard index > start else {
                    throw XanhPortableBackupError.malformedDocument
                }
                return
            default:
                index += 1
            }
        }
        guard index > start else {
            throw XanhPortableBackupError.malformedDocument
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x09 || bytes[index] == 0x0A
                || bytes[index] == 0x0D || bytes[index] == 0x20 {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
