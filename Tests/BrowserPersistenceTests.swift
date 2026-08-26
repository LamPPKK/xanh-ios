import CloudKit
import XCTest
@testable import XanhIOS

@MainActor
final class BrowserPersistenceTests: XCTestCase {
    func testBrandNewRepositoryUsesTheStableDefaultProfile() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)

        let snapshot = try await repository.load()

        XCTAssertEqual(snapshot.profiles.map(\.id), [BrowserProfile.defaultID])
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Default"])
        XCTAssertTrue(snapshot.profileDeletionCleanups.isEmpty)
    }

    func testCloudAccountStatusAlwaysKeepsBrowsingAvailableLocally() {
        XCTAssertEqual(CoreDataBrowserRepository.syncStatus(for: .available), .available)
        XCTAssertEqual(
            CoreDataBrowserRepository.syncStatus(for: .noAccount),
            .degraded("Sign in to iCloud to synchronize metadata. Browsing continues locally.")
        )
        XCTAssertEqual(
            CoreDataBrowserRepository.syncStatus(for: .temporarilyUnavailable),
            .degraded("iCloud is temporarily unavailable. Browsing continues locally.")
        )
    }

    func testPrivateObjectsNeverEnterPersistentSnapshot() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var snapshot = try await repository.load()
        let privateProfile = BrowserProfile.privateProfile()
        let privateSpace = BrowserSpace(
            id: SpaceID(),
            profileID: privateProfile.id,
            name: "Private",
            sortIndex: 2,
            selectedTabID: nil,
            storageMode: .ephemeral,
            modifiedAt: .now
        )
        snapshot.profiles.append(privateProfile)
        snapshot.spaces.append(privateSpace)
        snapshot.tabs.append(
            BrowserTab(
                id: TabID(),
                spaceID: privateSpace.id,
                url: URL(string: "https://private.example"),
                title: "Private",
                sortIndex: 0,
                lastActiveAt: .now,
                storageMode: .ephemeral,
                modifiedAt: .now
            )
        )

        try repository.save(snapshot)
        let restored = try await repository.load()

        XCTAssertFalse(restored.profiles.contains { $0.storageMode == .ephemeral })
        XCTAssertFalse(restored.spaces.contains { $0.storageMode == .ephemeral })
        XCTAssertFalse(restored.tabs.contains { $0.storageMode == .ephemeral })
    }

    func testProfileTombstoneCreatesAndRetainsLocalCleanupLedger() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var snapshot = try await repository.load()
        let now = Date.now
        let deletedProfile = BrowserProfile(
            id: ProfileID(),
            name: "Deleted",
            colorHex: "F58547",
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: now
        )
        snapshot.profiles.append(deletedProfile)
        try repository.save(snapshot)

        snapshot.profiles.removeAll { $0.id == deletedProfile.id }
        try repository.save(snapshot)

        var restored = try await repository.load()
        let pending = try XCTUnwrap(restored.profileDeletionCleanups.first {
            $0.profileID == deletedProfile.id
        })
        XCTAssertFalse(pending.isComplete)

        restored.profileDeletionCleanups = [
            ProfileDeletionCleanup(
                profileID: deletedProfile.id,
                websiteDataRemoved: true,
                keychainLockRemoved: true,
                createdAt: pending.createdAt,
                modifiedAt: .now
            ),
        ]
        try repository.save(restored)

        let reloaded = try await repository.load()
        let completed = try XCTUnwrap(reloaded.profileDeletionCleanups.first {
            $0.profileID == deletedProfile.id
        })
        XCTAssertTrue(completed.isComplete)
    }

    func testIncompleteCleanupLedgerOutlivesMissingTombstoneUntilCompletion() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var snapshot = try await repository.load()
        let deletedProfileID = ProfileID()
        snapshot.profileDeletionCleanups = [
            ProfileDeletionCleanup(profileID: deletedProfileID),
        ]
        try repository.save(snapshot)

        var restored = try await repository.load()
        let pending = try XCTUnwrap(restored.profileDeletionCleanups.first {
            $0.profileID == deletedProfileID
        })
        XCTAssertFalse(pending.isComplete)

        restored.profileDeletionCleanups = [
            ProfileDeletionCleanup(
                profileID: deletedProfileID,
                websiteDataRemoved: true,
                keychainLockRemoved: true,
                createdAt: pending.createdAt,
                modifiedAt: .now
            ),
        ]
        try repository.save(restored)

        let completed = try await repository.load()
        XCTAssertFalse(completed.profileDeletionCleanups.contains {
            $0.profileID == deletedProfileID
        })
    }

    func testFailedRepositorySaveRollsBackStagedProfileDeletion() async throws {
        var shouldFailSave = false
        let repository = CoreDataBrowserRepository(
            inMemory: true,
            cloudKitEnabled: false,
            beforeContextSave: {
                if shouldFailSave {
                    throw PersistenceFailure.expected
                }
            }
        )
        var snapshot = try await repository.load()
        let retainedProfile = BrowserProfile(
            id: ProfileID(),
            name: "Retained",
            colorHex: "F58547",
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: .now
        )
        snapshot.profiles.append(retainedProfile)
        try repository.save(snapshot)

        shouldFailSave = true
        snapshot.profiles.removeAll { $0.id == retainedProfile.id }
        XCTAssertThrowsError(try repository.save(snapshot))

        shouldFailSave = false
        let restored = try await repository.load()
        XCTAssertTrue(restored.profiles.contains { $0.id == retainedProfile.id })
        XCTAssertFalse(restored.profileDeletionCleanups.contains {
            $0.profileID == retainedProfile.id
        })
    }

    func testZeroProfileRecoveryPreservesCleanupForEveryDeletedStore() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var snapshot = try await repository.load()
        let originalProfileIDs = Set(snapshot.profiles.map(\.id))
        let secondProfile = BrowserProfile(
            id: ProfileID(),
            name: "Second",
            colorHex: "64D8FF",
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: .now
        )
        snapshot.profiles.append(secondProfile)
        try repository.save(snapshot)

        let deletedProfileIDs = originalProfileIDs.union([secondProfile.id])
        snapshot.profiles = []
        snapshot.spaces = []
        snapshot.tabs = []
        snapshot.profileDeletionCleanups = []
        snapshot.settings.historySyncEnabled = true
        snapshot.settings.automaticArchiveInterval = .thirtyDays
        snapshot.settings.modifiedAt = .now
        try repository.save(snapshot)

        let recovered = try await repository.load()
        let recoveredProfile = try XCTUnwrap(recovered.profiles.first)
        XCTAssertEqual(recovered.profiles.count, 1)
        XCTAssertFalse(deletedProfileIDs.contains(recoveredProfile.id))
        XCTAssertEqual(
            Set(recovered.profileDeletionCleanups.map(\.profileID)),
            deletedProfileIDs
        )
        XCTAssertTrue(recovered.profileDeletionCleanups.allSatisfy { !$0.isComplete })
        XCTAssertTrue(recovered.settings.historySyncEnabled)
        XCTAssertEqual(recovered.settings.automaticArchiveInterval, .thirtyDays)
    }

    func testPreviouslyUsedZeroProfileStoreNeverResurrectsDefaultAfterTombstoneExpiry() async throws {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = CoreDataBrowserRepository(
            inMemory: true,
            cloudKitEnabled: false,
            currentDate: { clock }
        )
        var snapshot = try await repository.load()
        snapshot.profiles = []
        snapshot.spaces = []
        snapshot.tabs = []
        snapshot.profileDeletionCleanups = [
            ProfileDeletionCleanup(
                profileID: BrowserProfile.defaultID,
                websiteDataRemoved: true,
                keychainLockRemoved: true,
                createdAt: clock,
                modifiedAt: clock
            ),
        ]
        try repository.save(snapshot)

        clock = clock.addingTimeInterval(31 * 24 * 60 * 60)
        let recovered = try await repository.load()

        let recoveredProfile = try XCTUnwrap(recovered.profiles.first)
        XCTAssertEqual(recovered.profiles.count, 1)
        XCTAssertNotEqual(recoveredProfile.id, BrowserProfile.defaultID)
        XCTAssertTrue(recovered.profileDeletionCleanups.isEmpty)
    }

    func testHistoryMovesBetweenLocalAndSyncedStoresWithoutDataLoss() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var snapshot = try await repository.load()
        let visit = HistoryVisit(
            id: HistoryVisitID(),
            profileID: try XCTUnwrap(snapshot.profiles.first?.id),
            url: try XCTUnwrap(URL(string: "https://example.com")),
            title: "Example",
            visitedAt: .now,
            modifiedAt: .now
        )
        snapshot.history = [visit]
        try repository.save(snapshot)
        let localHistory = try await repository.load().history
        XCTAssertEqual(localHistory.map(\.id), [visit.id])

        snapshot.settings.historySyncEnabled = true
        snapshot.settings.modifiedAt = .now
        try repository.save(snapshot)

        let restored = try await repository.load()
        XCTAssertTrue(restored.settings.historySyncEnabled)
        XCTAssertEqual(restored.history.map(\.id), [visit.id])
    }

    func testRegularArchivePersistsButPrivateProfileArchiveIsRejected() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var snapshot = try await repository.load()
        let regularProfile = try XCTUnwrap(snapshot.profiles.first)
        let regularSpace = try XCTUnwrap(snapshot.spaces.first)
        let now = Date.now
        let regular = ArchivedTab(
            id: ArchivedTabID(),
            profileID: regularProfile.id,
            sourceSpaceID: regularSpace.id,
            url: try XCTUnwrap(URL(string: "https://regular.example")),
            title: "Regular",
            archivedAt: now,
            modifiedAt: now
        )
        let privateProfile = BrowserProfile.privateProfile(now: now)
        snapshot.profiles.append(privateProfile)
        snapshot.archivedTabs = [
            regular,
            ArchivedTab(
                id: ArchivedTabID(),
                profileID: privateProfile.id,
                sourceSpaceID: SpaceID(),
                url: try XCTUnwrap(URL(string: "https://private.example")),
                title: "Private",
                archivedAt: now,
                modifiedAt: now
            ),
        ]

        try repository.save(snapshot)
        let restored = try await repository.load()

        XCTAssertEqual(restored.archivedTabs.map(\.id), [regular.id])
        XCTAssertEqual(restored.archivedTabs.map(\.profileID), [regular.profileID])
        XCTAssertEqual(restored.archivedTabs.map(\.url), [regular.url])
        XCTAssertFalse(restored.archivedTabs.contains { $0.profileID == privateProfile.id })
    }

    func testRegularSiteExceptionPersistsButPrivateAndMalformedEntriesAreRejected() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var snapshot = try await repository.load()
        let regularProfile = try XCTUnwrap(snapshot.profiles.first)
        let privateProfile = BrowserProfile.privateProfile()
        let now = Date.now
        let regular = BlockerSiteException(
            id: BlockerSiteExceptionID(),
            profileID: regularProfile.id,
            host: "example.com",
            createdAt: now,
            modifiedAt: now
        )
        snapshot.profiles.append(privateProfile)
        snapshot.blockerSiteExceptions = [
            regular,
            BlockerSiteException(
                id: BlockerSiteExceptionID(),
                profileID: privateProfile.id,
                host: "private.example",
                createdAt: now,
                modifiedAt: now
            ),
            BlockerSiteException(
                id: BlockerSiteExceptionID(),
                profileID: regularProfile.id,
                host: "EXAMPLE.COM",
                createdAt: now,
                modifiedAt: now
            ),
        ]

        try repository.save(snapshot)
        let restored = try await repository.load()

        let restoredException = try XCTUnwrap(restored.blockerSiteExceptions.first)
        XCTAssertEqual(restored.blockerSiteExceptions.count, 1)
        XCTAssertEqual(restoredException.id, regular.id)
        XCTAssertEqual(restoredException.profileID, regular.profileID)
        XCTAssertEqual(restoredException.host, regular.host)
        XCTAssertEqual(restoredException.createdAt.timeIntervalSince1970, regular.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(
            restoredException.modifiedAt.timeIntervalSince1970,
            regular.modifiedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testHistoryOlderThanNinetyDaysIsNotRestored() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var snapshot = try await repository.load()
        let oldDate = Date.now.addingTimeInterval(-91 * 24 * 60 * 60)
        snapshot.history = [
            HistoryVisit(
                id: HistoryVisitID(),
                profileID: try XCTUnwrap(snapshot.profiles.first?.id),
                url: try XCTUnwrap(URL(string: "https://old.example")),
                title: "Old",
                visitedAt: oldDate,
                modifiedAt: oldDate
            ),
        ]
        try repository.save(snapshot)

        let restoredHistory = try await repository.load().history
        XCTAssertTrue(restoredHistory.isEmpty)
    }

    func testOlderWriterCannotReplaceNewerProfileMetadata() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var newer = try await repository.load()
        let baseline = Date.now
        newer.profiles[0].name = "Newer"
        newer.profiles[0].modifiedAt = baseline.addingTimeInterval(200)
        try repository.save(newer)

        var stale = newer
        stale.profiles[0].name = "Stale"
        stale.profiles[0].modifiedAt = baseline.addingTimeInterval(100)
        try repository.save(stale)

        let restored = try await repository.load()
        XCTAssertEqual(restored.profiles[0].name, "Newer")
    }

    func testPortableImportOverridesNewerRecordsTombstonesAndDuplicateCandidates() async throws {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = CoreDataBrowserRepository(
            inMemory: true,
            cloudKitEnabled: false,
            currentDate: { clock }
        )
        let baseline = clock
        var stored = try await repository.load()
        let defaultProfileID = try XCTUnwrap(stored.profiles.first?.id)
        stored.profiles[0].name = "Newer local profile"
        stored.profiles[0].modifiedAt = baseline.addingTimeInterval(500)
        stored.settings.automaticArchiveInterval = .thirtyDays
        stored.settings.modifiedAt = baseline.addingTimeInterval(500)

        let revivedProfile = BrowserProfile(
            id: ProfileID(),
            name: "Deleted newer profile",
            colorHex: "67F58A",
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: baseline.addingTimeInterval(500)
        )
        let revivedSpace = BrowserSpace(
            id: SpaceID(),
            profileID: revivedProfile.id,
            name: "Deleted newer space",
            sortIndex: 1,
            selectedTabID: nil,
            storageMode: .persistent,
            modifiedAt: baseline.addingTimeInterval(500)
        )
        let revivedBookmark = Bookmark(
            id: BookmarkID(),
            profileID: defaultProfileID,
            url: try XCTUnwrap(URL(string: "https://revived.example")),
            title: "Deleted newer bookmark",
            createdAt: baseline,
            modifiedAt: baseline.addingTimeInterval(500)
        )
        stored.profiles.append(revivedProfile)
        stored.spaces.append(revivedSpace)
        stored.bookmarks = [revivedBookmark]
        try repository.save(stored)
        try repository.duplicateSyncedRecordForTesting(
            kind: "profile",
            recordID: defaultProfileID.rawValue.uuidString
        )
        XCTAssertEqual(
            try repository.syncedRecordCountForTesting(
                kind: "profile",
                recordID: defaultProfileID.rawValue.uuidString
            ),
            2
        )

        clock = baseline.addingTimeInterval(600)
        var withoutDeletedRecords = stored
        withoutDeletedRecords.profiles.removeAll { $0.id == revivedProfile.id }
        withoutDeletedRecords.spaces.removeAll { $0.id == revivedSpace.id }
        withoutDeletedRecords.bookmarks = []
        try repository.save(withoutDeletedRecords)

        let oldDate = baseline.addingTimeInterval(-500)
        var imported = stored
        imported.profiles[0].name = "Imported older profile"
        imported.profiles[0].modifiedAt = oldDate
        imported.profiles[1].name = "Imported revived profile"
        imported.profiles[1].modifiedAt = oldDate
        imported.spaces[1].name = "Imported revived space"
        imported.spaces[1].modifiedAt = oldDate
        imported.bookmarks[0].title = "Imported revived bookmark"
        imported.bookmarks[0].modifiedAt = oldDate
        imported.settings.automaticArchiveInterval = .oneDay
        imported.settings.modifiedAt = oldDate

        let importedAt = baseline.addingTimeInterval(100)
        try repository.savePortableImport(imported, importedAt: importedAt)
        let restored = try await repository.load()

        XCTAssertEqual(restored.profiles.first { $0.id == defaultProfileID }?.name, "Imported older profile")
        XCTAssertEqual(restored.profiles.first { $0.id == revivedProfile.id }?.name, "Imported revived profile")
        XCTAssertEqual(restored.bookmarks.map(\.title), ["Imported revived bookmark"])
        XCTAssertEqual(restored.settings.automaticArchiveInterval, .oneDay)
        XCTAssertTrue(restored.profiles.allSatisfy { $0.modifiedAt == importedAt })
        XCTAssertEqual(restored.settings.modifiedAt, importedAt)
        XCTAssertEqual(
            try repository.syncedRecordCountForTesting(
                kind: "profile",
                recordID: defaultProfileID.rawValue.uuidString
            ),
            1
        )
    }

    func testPortableImportRetainsWebsiteDataUntilAnExplicitProfileDeletion() async throws {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = CoreDataBrowserRepository(
            inMemory: true,
            cloudKitEnabled: false,
            currentDate: { clock }
        )
        var original = try await repository.load()
        let retainedProfile = BrowserProfile(
            id: ProfileID(),
            name: "Website data must survive",
            colorHex: "67F58A",
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: clock
        )
        let retainedSpace = BrowserSpace(
            id: SpaceID(),
            profileID: retainedProfile.id,
            name: retainedProfile.name,
            sortIndex: 1,
            selectedTabID: nil,
            storageMode: .persistent,
            modifiedAt: clock
        )
        original.profiles.append(retainedProfile)
        original.spaces.append(retainedSpace)
        try repository.save(original)

        var imported = original
        imported.profiles.removeAll { $0.id == retainedProfile.id }
        imported.spaces.removeAll { $0.id == retainedSpace.id }
        clock = clock.addingTimeInterval(100)
        try repository.savePortableImport(imported, importedAt: clock)

        let afterImport = try await repository.load()
        XCTAssertFalse(afterImport.profiles.contains { $0.id == retainedProfile.id })
        XCTAssertFalse(afterImport.profileDeletionCleanups.contains {
            $0.profileID == retainedProfile.id
        })

        try repository.save(afterImport)
        let afterOrdinarySave = try await repository.load()
        XCTAssertFalse(afterOrdinarySave.profileDeletionCleanups.contains {
            $0.profileID == retainedProfile.id
        })

        clock = clock.addingTimeInterval(100)
        try repository.savePortableImport(original, importedAt: clock)
        var restoredProfile = try await repository.load()
        XCTAssertTrue(restoredProfile.profiles.contains { $0.id == retainedProfile.id })

        restoredProfile.profiles.removeAll { $0.id == retainedProfile.id }
        restoredProfile.spaces.removeAll { $0.profileID == retainedProfile.id }
        restoredProfile.profileDeletionCleanups.append(
            ProfileDeletionCleanup(
                profileID: retainedProfile.id,
                createdAt: clock,
                modifiedAt: clock
            )
        )
        try repository.save(restoredProfile)

        let afterExplicitDeletion = try await repository.load()
        XCTAssertTrue(afterExplicitDeletion.profileDeletionCleanups.contains {
            $0.profileID == retainedProfile.id && !$0.isComplete
        })
    }

    func testPortableImportPreservesExplicitDeletionForRemoteCleanup() async throws {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = CoreDataBrowserRepository(
            inMemory: true,
            cloudKitEnabled: false,
            currentDate: { clock }
        )
        var snapshot = try await repository.load()
        let deletedProfile = BrowserProfile(
            id: ProfileID(),
            name: "Explicitly deleted",
            colorHex: "67F58A",
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: clock
        )
        snapshot.profiles.append(deletedProfile)
        try repository.save(snapshot)

        clock = clock.addingTimeInterval(100)
        snapshot.profiles.removeAll { $0.id == deletedProfile.id }
        try repository.save(snapshot)
        var pendingImport = try await repository.load()
        XCTAssertTrue(pendingImport.profileDeletionCleanups.contains {
            $0.profileID == deletedProfile.id && !$0.isComplete
        })

        clock = clock.addingTimeInterval(100)
        try repository.savePortableImport(pendingImport, importedAt: clock)
        let afterImport = try await repository.load()
        XCTAssertTrue(afterImport.profileDeletionCleanups.contains {
            $0.profileID == deletedProfile.id && !$0.isComplete
        })

        pendingImport.profileDeletionCleanups = []
        clock = clock.addingTimeInterval(100)
        try repository.savePortableImport(pendingImport, importedAt: clock)
        let destructiveFlags = try repository.profileTombstoneRetentionFlagsForTesting(
            profileID: deletedProfile.id
        )
        XCTAssertFalse(destructiveFlags.isEmpty)
        XCTAssertTrue(destructiveFlags.allSatisfy { !$0 })

        try repository.deleteLocalProfileDeletionCleanupForTesting(profileID: deletedProfile.id)
        let remoteReplica = try await repository.load()
        XCTAssertTrue(remoteReplica.profileDeletionCleanups.contains {
            $0.profileID == deletedProfile.id && !$0.isComplete
        })
    }

    func testProfileTombstoneDuplicatesUseGroupWideDestructivePrecedence() async throws {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = CoreDataBrowserRepository(
            inMemory: true,
            cloudKitEnabled: false,
            currentDate: { clock }
        )
        var original = try await repository.load()
        let omittedProfile = BrowserProfile(
            id: ProfileID(),
            name: "Omitted by import",
            colorHex: "67F58A",
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: clock
        )
        original.profiles.append(omittedProfile)
        try repository.save(original)

        var imported = original
        imported.profiles.removeAll { $0.id == omittedProfile.id }
        clock = clock.addingTimeInterval(100)
        try repository.savePortableImport(imported, importedAt: clock)
        XCTAssertEqual(
            try repository.profileTombstoneRetentionFlagsForTesting(profileID: omittedProfile.id),
            [true]
        )

        try repository.insertProfileRecordForTesting(
            profileID: omittedProfile.id,
            state: .live(omittedProfile),
            timestamp: clock
        )
        clock = clock.addingTimeInterval(100)
        try repository.save(imported)
        let retainedFlags = try repository.profileTombstoneRetentionFlagsForTesting(
            profileID: omittedProfile.id
        )
        XCTAssertEqual(retainedFlags.count, 2)
        XCTAssertTrue(retainedFlags.allSatisfy { $0 })
        let retainedSnapshot = try await repository.load()
        XCTAssertFalse(retainedSnapshot.profileDeletionCleanups.contains {
            $0.profileID == omittedProfile.id
        })

        try repository.insertProfileRecordForTesting(
            profileID: omittedProfile.id,
            state: .live(omittedProfile),
            timestamp: clock
        )
        try repository.insertProfileRecordForTesting(
            profileID: omittedProfile.id,
            state: .destructiveTombstone,
            timestamp: clock
        )
        clock = clock.addingTimeInterval(100)
        try repository.save(imported)
        let destructiveFlags = try repository.profileTombstoneRetentionFlagsForTesting(
            profileID: omittedProfile.id
        )
        XCTAssertEqual(destructiveFlags.count, 4)
        XCTAssertTrue(destructiveFlags.allSatisfy { !$0 })

        try repository.deleteLocalProfileDeletionCleanupForTesting(profileID: omittedProfile.id)
        let remoteReplica = try await repository.load()
        XCTAssertTrue(remoteReplica.profileDeletionCleanups.contains {
            $0.profileID == omittedProfile.id && !$0.isComplete
        })
    }

    func testTombstonePreventsOfflineBookmarkResurrection() async throws {
        let repository = CoreDataBrowserRepository(inMemory: true, cloudKitEnabled: false)
        var snapshot = try await repository.load()
        let bookmark = Bookmark(
            id: BookmarkID(),
            profileID: snapshot.profiles[0].id,
            url: URL(string: "https://deleted.example")!,
            title: "Deleted",
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        snapshot.bookmarks = [bookmark]
        try repository.save(snapshot)

        snapshot.bookmarks = []
        try repository.save(snapshot)
        snapshot.bookmarks = [bookmark]
        try repository.save(snapshot)

        let restored = try await repository.load()
        XCTAssertTrue(restored.bookmarks.isEmpty)
    }
}

private enum PersistenceFailure: Error {
    case expected
}
