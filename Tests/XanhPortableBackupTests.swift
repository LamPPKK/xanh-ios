import XCTest
@testable import XanhIOS

final class XanhPortableBackupTests: XCTestCase {
    func testRoundTripIncludesRegularMetadataAndExcludesPrivateStateAndCleanupLedger() throws {
        var snapshot = makeRegularSnapshot()
        let regularProfile = try XCTUnwrap(snapshot.profiles.first)
        let regularSpace = try XCTUnwrap(snapshot.spaces.first)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        snapshot.archivedTabs = [
            ArchivedTab(
                id: ArchivedTabID(),
                profileID: regularProfile.id,
                sourceSpaceID: regularSpace.id,
                url: try XCTUnwrap(URL(string: "https://archive.example")),
                title: "Archive",
                archivedAt: now,
                modifiedAt: now
            )
        ]
        snapshot.bookmarks = [
            Bookmark(
                id: BookmarkID(),
                profileID: regularProfile.id,
                url: try XCTUnwrap(URL(string: "https://bookmark.example")),
                title: "Bookmark",
                createdAt: now,
                modifiedAt: now
            )
        ]
        snapshot.history = [
            HistoryVisit(
                id: HistoryVisitID(),
                profileID: regularProfile.id,
                url: try XCTUnwrap(URL(string: "https://history.example")),
                title: "History",
                visitedAt: now,
                modifiedAt: now
            )
        ]
        snapshot.blockerSiteExceptions = [
            BlockerSiteException(
                id: BlockerSiteExceptionID(),
                profileID: regularProfile.id,
                host: "allowed.example",
                createdAt: now,
                modifiedAt: now
            )
        ]
        snapshot.profileDeletionCleanups = [ProfileDeletionCleanup(profileID: ProfileID())]

        let privateProfile = BrowserProfile.privateProfile(now: now)
        let privateSpace = BrowserSpace(
            id: SpaceID(),
            profileID: privateProfile.id,
            name: "Do not export this space",
            sortIndex: 10,
            selectedTabID: nil,
            storageMode: .ephemeral,
            modifiedAt: now
        )
        let privateTab = BrowserTab(
            id: TabID(),
            spaceID: privateSpace.id,
            url: try XCTUnwrap(URL(string: "https://private-secret.example")),
            title: "Private secret",
            sortIndex: 0,
            lastActiveAt: now,
            storageMode: .ephemeral,
            modifiedAt: now
        )
        snapshot.profiles.append(privateProfile)
        snapshot.spaces.append(privateSpace)
        snapshot.tabs.append(privateTab)
        snapshot.blockerSiteExceptions.append(
            BlockerSiteException(
                id: BlockerSiteExceptionID(),
                profileID: privateProfile.id,
                host: "private-secret.example",
                createdAt: now,
                modifiedAt: now
            )
        )

        let encoded = try XanhPortableBackup.encode(snapshot, exportedAt: now)
        let decoded = try XanhPortableBackup.decode(encoded)

        XCTAssertEqual(decoded.profiles.map(\.id), [regularProfile.id])
        XCTAssertTrue(decoded.spaces.allSatisfy { $0.storageMode == .persistent })
        XCTAssertTrue(decoded.tabs.allSatisfy { $0.storageMode == .persistent })
        XCTAssertEqual(decoded.archivedTabs.count, 1)
        XCTAssertEqual(decoded.bookmarks.count, 1)
        XCTAssertEqual(decoded.history.count, 1)
        XCTAssertEqual(decoded.blockerSiteExceptions.map(\.host), ["allowed.example"])
        XCTAssertTrue(decoded.profileDeletionCleanups.isEmpty)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-secret"))
    }

    func testRejectsUnsupportedSchemaBeforeImport() throws {
        let encoded = try XanhPortableBackup.encode(makeRegularSnapshot())
        let changed = try mutate(encoded) { root in
            root["schemaVersion"] = 999
        }

        XCTAssertThrowsError(try XanhPortableBackup.decode(changed)) { error in
            XCTAssertEqual(error as? XanhPortableBackupError, .unsupportedSchemaVersion(999))
        }
    }

    func testRejectsEphemeralObjectsAndUnknownPrivateFields() throws {
        let encoded = try XanhPortableBackup.encode(makeRegularSnapshot())
        let ephemeral = try mutate(encoded) { root in
            var payload = root["data"] as! [String: Any]
            var profiles = payload["profiles"] as! [[String: Any]]
            profiles[0]["storageMode"] = "ephemeral"
            payload["profiles"] = profiles
            root["data"] = payload
        }
        XCTAssertThrowsError(try XanhPortableBackup.decode(ephemeral)) { error in
            guard case .privateData = error as? XanhPortableBackupError else {
                return XCTFail("Expected private-data rejection, got \(error)")
            }
        }

        let injected = try mutate(encoded) { root in
            root["privateTabs"] = []
        }
        XCTAssertThrowsError(try XanhPortableBackup.decode(injected)) { error in
            guard case .privateData = error as? XanhPortableBackupError else {
                return XCTFail("Expected private-field rejection, got \(error)")
            }
        }

        let unknownRootField = try mutate(encoded) { root in
            root["futureMetadata"] = true
        }
        XCTAssertThrowsError(try XanhPortableBackup.decode(unknownRootField)) { error in
            XCTAssertEqual(
                error as? XanhPortableBackupError,
                .unknownField("root.futureMetadata")
            )
        }

        let unknownNestedField = try mutate(encoded) { root in
            var payload = root["data"] as! [String: Any]
            var profiles = payload["profiles"] as! [[String: Any]]
            profiles[0]["futureSetting"] = "unsupported"
            payload["profiles"] = profiles
            root["data"] = payload
        }
        XCTAssertThrowsError(try XanhPortableBackup.decode(unknownNestedField)) { error in
            XCTAssertEqual(
                error as? XanhPortableBackupError,
                .unknownField("root.data.profiles[0].futureSetting")
            )
        }

        let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let duplicateRootField = Data(
            ("{\"for\\u006dat\":\"\(XanhPortableBackup.formatIdentifier)\"," + source.dropFirst()).utf8
        )
        XCTAssertThrowsError(try XanhPortableBackup.decode(duplicateRootField)) { error in
            XCTAssertEqual(
                error as? XanhPortableBackupError,
                .duplicateField("root.format")
            )
        }

        let profilesKey = try XCTUnwrap(source.range(of: "\"profiles\""))
        let profileObjectStart = try XCTUnwrap(
            source[profilesKey.upperBound...].firstIndex(of: "{")
        )
        var duplicateNestedField = source
        duplicateNestedField.insert(
            contentsOf: "\"na\\u006de\":\"shadowed\",",
            at: duplicateNestedField.index(after: profileObjectStart)
        )
        XCTAssertThrowsError(
            try XanhPortableBackup.decode(Data(duplicateNestedField.utf8))
        ) { error in
            XCTAssertEqual(
                error as? XanhPortableBackupError,
                .duplicateField("root.data.profiles[0].name")
            )
        }
    }

    func testRejectsBrokenProfileReferences() throws {
        var snapshot = makeRegularSnapshot()
        let profileID = try XCTUnwrap(snapshot.profiles.first?.id)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        snapshot.bookmarks = [
            Bookmark(
                id: BookmarkID(),
                profileID: profileID,
                url: try XCTUnwrap(URL(string: "https://bookmark.example")),
                title: "Bookmark",
                createdAt: now,
                modifiedAt: now
            )
        ]
        let encoded = try XanhPortableBackup.encode(snapshot)
        let changed = try mutate(encoded) { root in
            var payload = root["data"] as! [String: Any]
            var bookmarks = payload["bookmarks"] as! [[String: Any]]
            bookmarks[0]["profileID"] = ["rawValue": UUID().uuidString]
            payload["bookmarks"] = bookmarks
            root["data"] = payload
        }

        XCTAssertThrowsError(try XanhPortableBackup.decode(changed)) { error in
            XCTAssertEqual(error as? XanhPortableBackupError, .invalidReference("bookmark profile"))
        }
    }

    func testRejectsCredentialBearingURLsAndOversizedFiles() throws {
        var snapshot = makeRegularSnapshot()
        snapshot.tabs[0].url = try XCTUnwrap(URL(string: "https://user:secret@example.com"))

        XCTAssertThrowsError(try XanhPortableBackup.encode(snapshot)) { error in
            guard case .privateData = error as? XanhPortableBackupError else {
                return XCTFail("Expected credential rejection, got \(error)")
            }
        }

        let oversized = Data(repeating: 0, count: XanhPortableBackup.maximumByteCount + 1)
        XCTAssertThrowsError(try XanhPortableBackup.decode(oversized)) { error in
            XCTAssertEqual(
                error as? XanhPortableBackupError,
                .fileTooLarge(maximumBytes: XanhPortableBackup.maximumByteCount)
            )
        }
    }

    func testRejectsExcessiveJSONNestingAndKeyLengthBeforeTypedDecode() {
        let deeplyNested = Data(
            (String(repeating: "[", count: 66)
                + "0"
                + String(repeating: "]", count: 66)).utf8
        )
        XCTAssertThrowsError(try XanhPortableBackup.decode(deeplyNested)) { error in
            XCTAssertEqual(
                error as? XanhPortableBackupError,
                .limitExceeded("JSON nesting depth")
            )
        }

        let oversizedKey = String(repeating: "x", count: 257)
        let document = Data("{\"\(oversizedKey)\":true}".utf8)
        XCTAssertThrowsError(try XanhPortableBackup.decode(document)) { error in
            XCTAssertEqual(
                error as? XanhPortableBackupError,
                .limitExceeded("JSON key length")
            )
        }
    }

    private func makeRegularSnapshot() -> BrowserSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshot = BrowserSnapshot.initial(now: now)
        let spaceID = snapshot.spaces[0].id
        let tab = BrowserTab(
            id: TabID(),
            spaceID: spaceID,
            url: URL(string: "https://xanh.example"),
            title: "Xanh",
            sortIndex: 0,
            lastActiveAt: now,
            storageMode: .persistent,
            modifiedAt: now
        )
        snapshot.tabs = [tab]
        snapshot.spaces[0].selectedTabID = tab.id
        snapshot.settings.lastSelectedSpaceID = spaceID
        return snapshot
    }

    private func mutate(
        _ data: Data,
        transform: (inout [String: Any]) -> Void
    ) throws -> Data {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        transform(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
