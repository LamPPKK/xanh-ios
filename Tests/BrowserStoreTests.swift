import XCTest
import WebKit
@testable import XanhIOS

@MainActor
final class BrowserStoreTests: XCTestCase {
    func testBootstrapCreatesRestorableHomeTab() async throws {
        let repository = InMemoryBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)

        await store.bootstrap()

        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.activeTab?.storageMode, .persistent)
        XCTAssertNil(store.activeTab?.url)
    }

    func testProfileDeletionCommitsMetadataBeforeLocalCleanupAndCompletesLedger() async throws {
        let fixture = makeTwoProfileSnapshot()
        let events = TestEventLog()
        let repository = RecordingBrowserRepository(snapshot: fixture.snapshot, events: events)
        let dataStores = FakeWebsiteDataStoreManager(events: events)
        let locks = FakeProfileLockStore(events: events)
        let store = makeStore(repository: repository, profileLocks: locks, dataStores: dataStores)
        await store.bootstrap()
        events.entries.removeAll()

        await store.deleteProfile(fixture.deletedProfileID)

        XCTAssertFalse(store.profiles.contains { $0.id == fixture.deletedProfileID })
        let cleanup = try XCTUnwrap(store.profileDeletionCleanups.first {
            $0.profileID == fixture.deletedProfileID
        })
        XCTAssertTrue(cleanup.isComplete)
        XCTAssertEqual(dataStores.removedPersistentProfiles, [fixture.deletedProfileID])
        XCTAssertEqual(locks.disabledProfiles, [fixture.deletedProfileID])
        XCTAssertEqual(events.entries.first, "save")
        XCTAssertLessThan(
            try XCTUnwrap(events.entries.firstIndex(of: "save")),
            try XCTUnwrap(events.entries.firstIndex(of: "website-data"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(events.entries.firstIndex(of: "website-data")),
            try XCTUnwrap(events.entries.firstIndex(of: "keychain-lock"))
        )
        XCTAssertFalse(repository.snapshot.profiles.contains { $0.id == fixture.deletedProfileID })
        XCTAssertTrue(repository.snapshot.profileDeletionCleanups.first {
            $0.profileID == fixture.deletedProfileID
        }?.isComplete == true)
    }

    func testProfileDeletionCleanupFailureRetainsDurableRetryAndKeepsLock() async throws {
        let fixture = makeTwoProfileSnapshot()
        let repository = RecordingBrowserRepository(snapshot: fixture.snapshot)
        let dataStores = FakeWebsiteDataStoreManager(removalResult: .failure(TestFailure.expected))
        let locks = FakeProfileLockStore()
        let store = makeStore(repository: repository, profileLocks: locks, dataStores: dataStores)
        await store.bootstrap()

        await store.deleteProfile(fixture.deletedProfileID)

        XCTAssertFalse(store.profiles.contains { $0.id == fixture.deletedProfileID })
        let cleanup = try XCTUnwrap(repository.snapshot.profileDeletionCleanups.first {
            $0.profileID == fixture.deletedProfileID
        })
        XCTAssertFalse(cleanup.websiteDataRemoved)
        XCTAssertFalse(cleanup.keychainLockRemoved)
        XCTAssertTrue(locks.disabledProfiles.isEmpty)
        XCTAssertTrue(
            store.errorMessage?.hasPrefix("Profile data cleanup is pending and will retry:") == true
        )
    }

    func testProfileLockCleanupRetriesWithoutRepeatingWebsiteDataRemoval() async throws {
        let fixture = makeTwoProfileSnapshot()
        let repository = RecordingBrowserRepository(snapshot: fixture.snapshot)
        let dataStores = FakeWebsiteDataStoreManager()
        let failingLocks = FakeProfileLockStore(disableResult: .failure(TestFailure.expected))
        let store = makeStore(
            repository: repository,
            profileLocks: failingLocks,
            dataStores: dataStores
        )
        await store.bootstrap()

        await store.deleteProfile(fixture.deletedProfileID)

        let pending = try XCTUnwrap(repository.snapshot.profileDeletionCleanups.first {
            $0.profileID == fixture.deletedProfileID
        })
        XCTAssertTrue(pending.websiteDataRemoved)
        XCTAssertFalse(pending.keychainLockRemoved)
        XCTAssertEqual(dataStores.removedPersistentProfiles, [fixture.deletedProfileID])

        let retryDataStores = FakeWebsiteDataStoreManager()
        let retryLocks = FakeProfileLockStore()
        let relaunchedStore = makeStore(
            repository: repository,
            profileLocks: retryLocks,
            dataStores: retryDataStores
        )
        await relaunchedStore.bootstrap()

        XCTAssertTrue(retryDataStores.removedPersistentProfiles.isEmpty)
        XCTAssertEqual(retryLocks.disabledProfiles, [fixture.deletedProfileID])
        XCTAssertTrue(repository.snapshot.profileDeletionCleanups.first {
            $0.profileID == fixture.deletedProfileID
        }?.isComplete == true)
    }

    func testBootstrapRetriesDurableProfileDeletionCleanup() async throws {
        let deletedProfileID = ProfileID()
        var snapshot = BrowserSnapshot.initial()
        snapshot.profileDeletionCleanups = [ProfileDeletionCleanup(profileID: deletedProfileID)]
        let repository = RecordingBrowserRepository(snapshot: snapshot)
        let dataStores = FakeWebsiteDataStoreManager()
        let locks = FakeProfileLockStore()
        let store = makeStore(repository: repository, profileLocks: locks, dataStores: dataStores)

        await store.bootstrap()

        XCTAssertEqual(dataStores.removedPersistentProfiles, [deletedProfileID])
        XCTAssertEqual(locks.disabledProfiles, [deletedProfileID])
        XCTAssertTrue(repository.snapshot.profileDeletionCleanups.first {
            $0.profileID == deletedProfileID
        }?.isComplete == true)
    }

    func testForegroundRetriesCleanupThatFailedDuringBootstrap() async throws {
        let deletedProfileID = ProfileID()
        var snapshot = BrowserSnapshot.initial()
        snapshot.profileDeletionCleanups = [ProfileDeletionCleanup(profileID: deletedProfileID)]
        let repository = RecordingBrowserRepository(snapshot: snapshot)
        let dataStores = FakeWebsiteDataStoreManager(removalResult: .failure(TestFailure.expected))
        let locks = FakeProfileLockStore()
        let store = makeStore(repository: repository, profileLocks: locks, dataStores: dataStores)
        await store.bootstrap()
        XCTAssertFalse(repository.snapshot.profileDeletionCleanups.first {
            $0.profileID == deletedProfileID
        }?.isComplete == true)

        dataStores.updateRemovalResult(.success(()))
        await store.revealAfterForeground()

        XCTAssertEqual(dataStores.removedPersistentProfiles, [deletedProfileID])
        XCTAssertEqual(locks.disabledProfiles, [deletedProfileID])
        XCTAssertTrue(repository.snapshot.profileDeletionCleanups.first {
            $0.profileID == deletedProfileID
        }?.isComplete == true)
    }

    func testProfileDeletionPersistenceFailureRollsBackAndSkipsDestructiveCleanup() async throws {
        let fixture = makeTwoProfileSnapshot()
        let repository = RecordingBrowserRepository(snapshot: fixture.snapshot)
        let dataStores = FakeWebsiteDataStoreManager()
        let locks = FakeProfileLockStore()
        let store = makeStore(repository: repository, profileLocks: locks, dataStores: dataStores)
        await store.bootstrap()
        repository.saveResult = .failure(TestFailure.expected)

        await store.deleteProfile(fixture.deletedProfileID)

        XCTAssertTrue(store.profiles.contains { $0.id == fixture.deletedProfileID })
        XCTAssertTrue(store.profileDeletionCleanups.isEmpty)
        XCTAssertTrue(dataStores.removedPersistentProfiles.isEmpty)
        XCTAssertTrue(locks.disabledProfiles.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testDeletingSelectedProfileCreatesFallbackHomeBeforeCommit() async throws {
        var fixture = makeTwoProfileSnapshot()
        let deletedSpaceID = try XCTUnwrap(
            fixture.snapshot.spaces.first { $0.profileID == fixture.deletedProfileID }?.id
        )
        fixture.snapshot.settings.lastSelectedSpaceID = deletedSpaceID
        fixture.snapshot.tabs.removeAll {
            $0.spaceID != deletedSpaceID
        }
        let repository = RecordingBrowserRepository(snapshot: fixture.snapshot)
        let store = makeStore(repository: repository, dataStores: FakeWebsiteDataStoreManager())
        await store.bootstrap()
        XCTAssertEqual(store.selectedSpaceID, deletedSpaceID)

        await store.deleteProfile(fixture.deletedProfileID)

        XCTAssertNotEqual(store.selectedSpaceID, deletedSpaceID)
        XCTAssertEqual(store.activeTab?.spaceID, store.selectedSpaceID)
        XCTAssertNil(store.activeTab?.url)
        XCTAssertEqual(repository.snapshot.tabs.count, 1)
    }

    func testRemoteProfileDeletionTriggersLocalCleanupWithoutSyncedProgress() async throws {
        let fixture = makeTwoProfileSnapshot()
        let repository = RecordingBrowserRepository(snapshot: fixture.snapshot)
        let dataStores = FakeWebsiteDataStoreManager()
        let locks = FakeProfileLockStore()
        let store = makeStore(repository: repository, profileLocks: locks, dataStores: dataStores)
        await store.bootstrap()

        let removedSpaceIDs = Set(
            repository.snapshot.spaces
                .filter { $0.profileID == fixture.deletedProfileID }
                .map(\.id)
        )
        repository.snapshot.profiles.removeAll { $0.id == fixture.deletedProfileID }
        repository.snapshot.spaces.removeAll { $0.profileID == fixture.deletedProfileID }
        repository.snapshot.tabs.removeAll { removedSpaceIDs.contains($0.spaceID) }
        repository.snapshot.profileDeletionCleanups = [
            ProfileDeletionCleanup(profileID: fixture.deletedProfileID),
        ]
        repository.notifyExternalChange()
        for _ in 0 ..< 20 where dataStores.removedPersistentProfiles.isEmpty {
            await Task.yield()
        }

        XCTAssertFalse(store.profiles.contains { $0.id == fixture.deletedProfileID })
        XCTAssertEqual(dataStores.removedPersistentProfiles, [fixture.deletedProfileID])
        XCTAssertEqual(locks.disabledProfiles, [fixture.deletedProfileID])
        XCTAssertTrue(repository.snapshot.profileDeletionCleanups.first {
            $0.profileID == fixture.deletedProfileID
        }?.isComplete == true)
    }

    func testRemoteRetainedImportOmissionDoesNotDeleteWebsiteDataOrKeychainLock() async throws {
        let fixture = makeTwoProfileSnapshot()
        let events = TestEventLog()
        let repository = RecordingBrowserRepository(snapshot: fixture.snapshot, events: events)
        let dataStores = FakeWebsiteDataStoreManager()
        let locks = FakeProfileLockStore()
        let store = makeStore(repository: repository, profileLocks: locks, dataStores: dataStores)
        await store.bootstrap()
        events.entries.removeAll()

        let removedSpaceIDs = Set(
            repository.snapshot.spaces
                .filter { $0.profileID == fixture.deletedProfileID }
                .map(\.id)
        )
        repository.snapshot.profiles.removeAll { $0.id == fixture.deletedProfileID }
        repository.snapshot.spaces.removeAll { $0.profileID == fixture.deletedProfileID }
        repository.snapshot.tabs.removeAll { removedSpaceIDs.contains($0.spaceID) }
        repository.snapshot.profileDeletionCleanups = []
        repository.notifyExternalChange()
        for _ in 0 ..< 50 where store.profiles.contains(where: { $0.id == fixture.deletedProfileID }) {
            await Task.yield()
        }

        XCTAssertFalse(store.profiles.contains { $0.id == fixture.deletedProfileID })
        XCTAssertTrue(store.profileDeletionCleanups.isEmpty)
        XCTAssertTrue(dataStores.removedPersistentProfiles.isEmpty)
        XCTAssertTrue(locks.disabledProfiles.isEmpty)
        XCTAssertTrue(repository.snapshot.profileDeletionCleanups.isEmpty)
        XCTAssertFalse(events.entries.contains("save"))
    }

    func testPrivateSpaceIsMemoryOnly() async throws {
        let repository = InMemoryBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)
        await store.bootstrap()

        store.createPrivateSpace()
        XCTAssertEqual(store.selectedSpace?.storageMode, .ephemeral)

        let persisted = try await repository.load()
        XCTAssertFalse(persisted.spaces.contains { $0.storageMode == .ephemeral })
        XCTAssertFalse(persisted.tabs.contains { $0.storageMode == .ephemeral })
    }

    func testHistorySyncDefaultsOff() async {
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: .initial()))
        await store.bootstrap()

        XCTAssertFalse(store.settings.historySyncEnabled)
        store.setHistorySyncEnabled(true)
        XCTAssertTrue(store.settings.historySyncEnabled)
    }

    func testRepositorySyncStatusChangesReachBrowserStore() async {
        let repository = InMemoryBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)
        await store.bootstrap()

        repository.updateSyncStatus(.syncing)

        XCTAssertEqual(store.syncStatus, .syncing)
    }

    func testLastSelectedRegularSpaceRestoresAfterRelaunch() async throws {
        var snapshot = BrowserSnapshot.initial()
        let secondSpace = BrowserSpace(
            id: SpaceID(),
            profileID: try XCTUnwrap(snapshot.profiles.first?.id),
            name: "Research",
            sortIndex: 1,
            selectedTabID: nil,
            storageMode: .persistent,
            modifiedAt: .now
        )
        snapshot.spaces.append(secondSpace)
        snapshot.settings.lastSelectedSpaceID = secondSpace.id
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: snapshot))

        await store.bootstrap()

        XCTAssertEqual(store.selectedSpaceID, secondSpace.id)
        XCTAssertEqual(store.activeTab?.spaceID, secondSpace.id)
    }

    func testLRUTrimmingNeverReleasesActiveSession() async throws {
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: .initial()))
        await store.bootstrap()
        let old = try XCTUnwrap(store.createTab(url: URL(string: "https://old.example")))
        let recent = try XCTUnwrap(store.createTab(url: URL(string: "https://recent.example")))
        let active = try XCTUnwrap(store.createTab(url: URL(string: "https://active.example")))
        store.tabs[store.tabs.firstIndex(where: { $0.id == old.id })!].lastActiveAt = Date(timeIntervalSince1970: 1)
        store.tabs[store.tabs.firstIndex(where: { $0.id == recent.id })!].lastActiveAt = Date(timeIntervalSince1970: 2)

        let evicted = store.trimBackgroundSessions(keepingMostRecent: 1)

        XCTAssertTrue(evicted.contains(old.id))
        XCTAssertFalse(evicted.contains(recent.id))
        XCTAssertFalse(evicted.contains(active.id))
        XCTAssertFalse(store.isSessionLoaded(for: old.id))
        XCTAssertTrue(store.isSessionLoaded(for: recent.id))
        XCTAssertTrue(store.isSessionLoaded(for: active.id))
    }

    func testClosingRegularWebTabArchivesAndRestoresIt() async throws {
        let repository = InMemoryBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)
        await store.bootstrap()
        let url = try XCTUnwrap(URL(string: "https://archive.example/article"))
        let closed = try XCTUnwrap(store.createTab(url: url))

        store.closeTab(closed.id)

        let archived = try XCTUnwrap(store.archivedTabs.first)
        XCTAssertEqual(archived.url, url)
        XCTAssertEqual(archived.profileID, store.activeProfile?.id)
        XCTAssertFalse(store.tabs.contains { $0.id == closed.id })

        let restored = try XCTUnwrap(store.restoreArchivedTab(archived.id))

        XCTAssertEqual(restored.url, url)
        XCTAssertEqual(store.selectedTabID, restored.id)
        XCTAssertTrue(store.archivedTabs.isEmpty)
        XCTAssertNotEqual(restored.id, closed.id)
        let persisted = try await repository.load()
        XCTAssertTrue(persisted.tabs.map(\.id).contains(restored.id))
    }

    func testPrivateAndHomeTabsNeverEnterArchive() async throws {
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: .initial()))
        await store.bootstrap()
        let homeID = try XCTUnwrap(store.activeTab?.id)
        store.closeTab(homeID)
        XCTAssertTrue(store.archivedTabs.isEmpty)

        let blank = try XCTUnwrap(store.createTab(url: URL(string: "about:blank")))
        store.closeTab(blank.id)
        XCTAssertTrue(store.archivedTabs.isEmpty)

        store.createPrivateSpace()
        let privateTab = try XCTUnwrap(
            store.createTab(url: URL(string: "https://private.example/secret"))
        )
        store.closeTab(privateTab.id)

        XCTAssertTrue(store.archivedTabs.isEmpty)
    }

    func testArchiveDropsEntriesOlderThanThirtyDays() async throws {
        var snapshot = BrowserSnapshot.initial()
        let profile = try XCTUnwrap(snapshot.profiles.first)
        let space = try XCTUnwrap(snapshot.spaces.first)
        let oldDate = Date.now.addingTimeInterval(-31 * 24 * 60 * 60)
        snapshot.archivedTabs = [
            ArchivedTab(
                id: ArchivedTabID(),
                profileID: profile.id,
                sourceSpaceID: space.id,
                url: try XCTUnwrap(URL(string: "https://expired.example")),
                title: "Expired",
                archivedAt: oldDate,
                modifiedAt: oldDate
            ),
        ]
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: snapshot))

        await store.bootstrap()

        XCTAssertTrue(store.archivedTabs.isEmpty)
    }

    func testArchiveKeepsOnlyTwoHundredNewestEntriesPerProfile() async throws {
        var snapshot = BrowserSnapshot.initial()
        let profile = try XCTUnwrap(snapshot.profiles.first)
        let space = try XCTUnwrap(snapshot.spaces.first)
        let now = Date.now
        snapshot.archivedTabs = try (0 ..< 205).map { index in
            ArchivedTab(
                id: ArchivedTabID(),
                profileID: profile.id,
                sourceSpaceID: space.id,
                url: try XCTUnwrap(URL(string: "https://archive.example/\(index)")),
                title: "Archive \(index)",
                archivedAt: now.addingTimeInterval(TimeInterval(-index)),
                modifiedAt: now.addingTimeInterval(TimeInterval(-index))
            )
        }
        let newestID = try XCTUnwrap(snapshot.archivedTabs.first?.id)
        let oldestIDs = Set(snapshot.archivedTabs.suffix(5).map(\.id))
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: snapshot))

        await store.bootstrap()

        XCTAssertEqual(store.archivedTabs.count, 200)
        XCTAssertTrue(store.archivedTabs.contains { $0.id == newestID })
        XCTAssertTrue(oldestIDs.isDisjoint(with: Set(store.archivedTabs.map(\.id))))
    }

    func testPinnedTabSortsFirstAndRestoresPinnedIntentFromArchive() async throws {
        let repository = InMemoryBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)
        await store.bootstrap()
        let first = try XCTUnwrap(store.createTab(url: URL(string: "https://first.example")))
        let pinned = try XCTUnwrap(store.createTab(url: URL(string: "https://pinned.example")))

        store.togglePinned(pinned.id)

        XCTAssertEqual(store.tabsInSelectedSpace.first?.id, pinned.id)
        XCTAssertTrue(store.tabs.first(where: { $0.id == pinned.id })?.isPinned == true)
        store.closeTab(pinned.id)
        let archived = try XCTUnwrap(store.archivedTabs.first(where: { $0.url == pinned.url }))
        XCTAssertNotNil(archived.pinnedAt)

        let restored = try XCTUnwrap(store.restoreArchivedTab(archived.id))

        XCTAssertTrue(restored.isPinned)
        XCTAssertEqual(store.tabsInSelectedSpace.first?.id, restored.id)
        XCTAssertTrue(store.tabs.contains { $0.id == first.id })
        let persisted = try await repository.load()
        XCTAssertTrue(persisted.tabs.contains { $0.id == restored.id && $0.isPinned })
    }

    func testAutomaticArchiveMovesOnlyStaleUnpinnedBackgroundTabs() async throws {
        let repository = InMemoryBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)
        await store.bootstrap()
        store.setAutomaticArchiveInterval(nil)
        let active = try XCTUnwrap(store.createTab(url: URL(string: "https://active.example")))
        let stale = try XCTUnwrap(store.createTab(url: URL(string: "https://stale.example"), activate: false))
        let pinned = try XCTUnwrap(store.createTab(url: URL(string: "https://pinned.example"), activate: false))
        store.togglePinned(pinned.id)
        let oldDate = Date.now.addingTimeInterval(-8 * 24 * 60 * 60)
        store.tabs[try XCTUnwrap(store.tabs.firstIndex(where: { $0.id == active.id }))].lastActiveAt = oldDate
        store.tabs[try XCTUnwrap(store.tabs.firstIndex(where: { $0.id == stale.id }))].lastActiveAt = oldDate
        store.tabs[try XCTUnwrap(store.tabs.firstIndex(where: { $0.id == pinned.id }))].lastActiveAt = oldDate

        store.setAutomaticArchiveInterval(.sevenDays)

        XCTAssertTrue(store.tabs.contains { $0.id == active.id })
        XCTAssertFalse(store.tabs.contains { $0.id == stale.id })
        XCTAssertTrue(store.tabs.contains { $0.id == pinned.id })
        XCTAssertEqual(store.archivedTabs.first(where: { $0.url == stale.url })?.sourceSpaceID, stale.spaceID)
        XCTAssertFalse(store.archivedTabs.contains { $0.url == active.url || $0.url == pinned.url })
    }

    func testAutomaticArchiveOffLeavesStaleTabOpen() async throws {
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: .initial()))
        await store.bootstrap()
        store.setAutomaticArchiveInterval(nil)
        let stale = try XCTUnwrap(store.createTab(url: URL(string: "https://stale.example"), activate: false))
        store.tabs[try XCTUnwrap(store.tabs.firstIndex(where: { $0.id == stale.id }))].lastActiveAt =
            Date.now.addingTimeInterval(-31 * 24 * 60 * 60)

        let archived = store.performAutomaticArchive()

        XCTAssertTrue(archived.isEmpty)
        XCTAssertTrue(store.tabs.contains { $0.id == stale.id })
        XCTAssertTrue(store.archivedTabs.isEmpty)
    }

    func testAutomaticArchiveRepairsSelectionInInactiveSpace() async throws {
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: .initial()))
        await store.bootstrap()
        store.setAutomaticArchiveInterval(nil)
        let mainSpaceID = try XCTUnwrap(store.selectedSpaceID)
        let profileID = try XCTUnwrap(store.activeProfile?.id)
        store.createSpace(name: "Research", profileID: profileID)
        let researchSpaceID = try XCTUnwrap(store.selectedSpaceID)
        let stale = try XCTUnwrap(store.createTab(url: URL(string: "https://stale.example")))
        await store.selectSpace(mainSpaceID)
        store.tabs[try XCTUnwrap(store.tabs.firstIndex(where: { $0.id == stale.id }))].lastActiveAt =
            Date.now.addingTimeInterval(-8 * 24 * 60 * 60)

        store.setAutomaticArchiveInterval(.sevenDays)

        XCTAssertFalse(store.tabs.contains { $0.id == stale.id })
        let repairedSelection = store.spaces.first(where: { $0.id == researchSpaceID })?.selectedTabID
        XCTAssertNotEqual(repairedSelection, stale.id)
        XCTAssertTrue(store.tabs.contains { $0.id == repairedSelection })
        XCTAssertEqual(store.selectedSpaceID, mainSpaceID)
    }

    func testBlockerChangeIsStagedWithoutReloadingActiveWebView() async throws {
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: .initial()))
        await store.bootstrap()
        _ = store.createTab(url: URL(string: "https://form.example"))
        let originalSession = try XCTUnwrap(store.activeSession)
        let profileID = try XCTUnwrap(store.activeProfile?.id)

        store.setBlockerEnabled(false, for: profileID)

        XCTAssertTrue(originalSession === store.activeSession)
        XCTAssertTrue(originalSession.hasPendingPolicyChange)
        XCTAssertFalse(originalSession.profile.blockerEnabled)
    }

    func testSiteShieldsExceptionIsExactHostPersistentAndStagedWithoutReload() async throws {
        let repository = InMemoryBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)
        await store.bootstrap()
        let exactURL = try XCTUnwrap(URL(string: "https://example.com/form"))
        _ = store.createTab(url: exactURL)
        let originalSession = try XCTUnwrap(store.activeSession)

        store.setShieldsEnabledForActiveSite(false)

        XCTAssertTrue(originalSession === store.activeSession)
        XCTAssertTrue(originalSession.hasPendingPolicyChange)
        XCTAssertFalse(store.shieldsEnabledForActiveSite)
        XCTAssertEqual(store.blockerSiteExceptions.map(\.host), ["example.com"])
        let persisted = try await repository.load()
        XCTAssertEqual(persisted.blockerSiteExceptions.map(\.host), ["example.com"])

        _ = store.createTab(url: try XCTUnwrap(URL(string: "https://news.example.com/article")))

        XCTAssertEqual(store.activeBlockerHost, "news.example.com")
        XCTAssertTrue(store.shieldsEnabledForActiveSite)
    }

    func testPrivateSiteShieldsExceptionStaysInMemoryAndBurnsWithPrivateSpace() async throws {
        let repository = InMemoryBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)
        await store.bootstrap()
        store.createPrivateSpace()
        try store.navigate("https://private.example/secret")
        let privateProfileID = try XCTUnwrap(store.activeProfile?.id)

        store.setShieldsEnabledForActiveSite(false)

        XCTAssertTrue(store.blockerSiteExceptions.contains { $0.profileID == privateProfileID })
        let persisted = try await repository.load()
        XCTAssertTrue(persisted.blockerSiteExceptions.isEmpty)

        store.closeTab(try XCTUnwrap(store.activeTab?.id))

        XCTAssertFalse(store.blockerSiteExceptions.contains { $0.profileID == privateProfileID })
    }

    func testContentProcessTerminationUsesTheCorrectActiveAndBackgroundSessions() async throws {
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: .initial()))
        await store.bootstrap()
        let backgroundTab = try XCTUnwrap(store.createTab(url: URL(string: "https://background.example")))
        let backgroundSession = try XCTUnwrap(store.activeSession)
        let activeTab = try XCTUnwrap(store.createTab(url: URL(string: "https://active.example")))
        let activeSession = try XCTUnwrap(store.activeSession)

        XCTAssertFalse(backgroundSession === activeSession)
        XCTAssertNotNil(backgroundSession.webView.navigationDelegate)
        XCTAssertNotNil(activeSession.webView.navigationDelegate)

        backgroundSession.webContentProcessDidTerminate()
        XCTAssertFalse(store.isSessionLoaded(for: backgroundTab.id))
        XCTAssertTrue(store.isSessionLoaded(for: activeTab.id))

        activeSession.webContentProcessDidTerminate()
        XCTAssertTrue(store.isSessionLoaded(for: activeTab.id))
        XCTAssertNil(store.errorMessage)

        activeSession.webContentProcessDidTerminate()
        XCTAssertEqual(store.errorMessage, "The page stopped unexpectedly. Reload it when you are ready.")
        XCTAssertTrue(store.canRecoverFailedPage)

        store.openHomeAfterWebContentFailure()

        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.canRecoverFailedPage)
        XCTAssertNil(store.activeTab?.url)
        XCTAssertFalse(store.isSessionLoaded(for: activeTab.id))
    }

    func testContentProcessFailureCanRetryTheExactActivePage() async throws {
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: .initial()))
        await store.bootstrap()
        let tab = try XCTUnwrap(store.createTab(url: URL(string: "https://active.example/path")))
        let session = try XCTUnwrap(store.activeSession)

        session.webContentProcessDidTerminate()
        session.webContentProcessDidTerminate()
        XCTAssertTrue(store.canRecoverFailedPage)

        store.retryFailedPage()

        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.canRecoverFailedPage)
        XCTAssertEqual(store.activeTab?.id, tab.id)
        XCTAssertEqual(store.activeTab?.url?.absoluteString, "https://active.example/path")
        XCTAssertTrue(store.isSessionLoaded(for: tab.id))
    }

    func testPrivateSpaceLocksAcrossBackgroundTransition() async {
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: .initial()))
        await store.bootstrap()
        store.createPrivateSpace()

        store.lockProtectedContent()
        XCTAssertTrue(store.selectedProfileIsLocked)

        await store.revealAfterForeground()
        XCTAssertFalse(store.selectedProfileIsLocked)
    }

    func testCancelledProfileUnlockFailsClosed() async throws {
        let snapshot = BrowserSnapshot.initial()
        let profileID = try XCTUnwrap(snapshot.profiles.first?.id)
        let locks = FakeProfileLockStore(unlockResult: .failure(CancellationError()))
        try locks.enable(for: profileID)
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: snapshot), profileLocks: locks)
        await store.bootstrap()

        await store.unlockActiveProfileIfNeeded()

        XCTAssertTrue(store.selectedProfileIsLocked)
        XCTAssertEqual(store.errorMessage, "Profile remains locked.")
    }

    func testDeviceOwnerRecoveryUnlocksProfileAfterBiometricFailure() async throws {
        let snapshot = BrowserSnapshot.initial()
        let profileID = try XCTUnwrap(snapshot.profiles.first?.id)
        let locks = FakeProfileLockStore(unlockResult: .failure(SecureAccessError.authenticationFailed))
        try locks.enable(for: profileID)
        let store = makeStore(repository: InMemoryBrowserRepository(snapshot: snapshot), profileLocks: locks)
        await store.bootstrap()

        await store.recoverActiveProfileAccess()

        XCTAssertFalse(store.selectedProfileIsLocked)
    }

    func testPortableImportReplacesRegularMetadataAndPreservesPrivateRuntimeState() async throws {
        let repository = InMemoryBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)
        await store.bootstrap()
        store.createPrivateSpace()
        let privateProfileID = try XCTUnwrap(
            store.profiles.first(where: { $0.storageMode == .ephemeral })?.id
        )
        let privateTabID = try XCTUnwrap(
            store.tabs.first(where: { $0.storageMode == .ephemeral })?.id
        )

        var imported = BrowserSnapshot.initial(now: Date(timeIntervalSince1970: 1_700_000_000))
        imported.profiles[0].name = "Imported profile"
        let importedSpaceID = imported.spaces[0].id
        let importedTab = BrowserTab(
            id: TabID(),
            spaceID: importedSpaceID,
            url: URL(string: "https://imported.example"),
            title: "Imported tab",
            sortIndex: 0,
            lastActiveAt: .now,
            storageMode: .persistent,
            modifiedAt: .now
        )
        imported.tabs = [importedTab]
        imported.spaces[0].selectedTabID = importedTab.id
        imported.settings.lastSelectedSpaceID = importedSpaceID
        let encoded = try XanhPortableBackup.encode(imported)

        let importedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try store.importPortableBackupData(encoded, now: importedAt)

        XCTAssertTrue(store.profiles.contains { $0.name == "Imported profile" })
        XCTAssertTrue(store.profiles.contains { $0.id == privateProfileID && $0.storageMode == .ephemeral })
        XCTAssertTrue(store.tabs.contains { $0.id == privateTabID && $0.storageMode == .ephemeral })
        let persisted = try await repository.load()
        XCTAssertEqual(persisted.profiles.map(\.name), ["Imported profile"])
        XCTAssertTrue(persisted.profiles.allSatisfy { $0.modifiedAt == importedAt })
        XCTAssertEqual(persisted.settings.modifiedAt, importedAt)
        XCTAssertTrue(persisted.profiles.allSatisfy { $0.storageMode == .persistent })
        XCTAssertTrue(persisted.tabs.allSatisfy { $0.storageMode == .persistent })
    }

    func testPortableImportRejectsEveryPrivateRuntimeIDCollisionBeforeSaving() async throws {
        enum CollisionCase: CaseIterable {
            case profile
            case space
            case tab
            case siteException
        }

        for collision in CollisionCase.allCases {
            let repository = RecordingBrowserRepository(snapshot: .initial())
            let store = makeStore(repository: repository)
            await store.bootstrap()
            store.createPrivateSpace()

            let privateProfile = try XCTUnwrap(
                store.profiles.first { $0.storageMode == .ephemeral }
            )
            let privateSpace = try XCTUnwrap(
                store.spaces.first { $0.storageMode == .ephemeral }
            )
            let privateTab = try XCTUnwrap(
                store.tabs.first { $0.storageMode == .ephemeral }
            )
            let privateException = BlockerSiteException(
                id: BlockerSiteExceptionID(),
                profileID: privateProfile.id,
                host: "private.example",
                createdAt: .now,
                modifiedAt: .now
            )
            store.blockerSiteExceptions.append(privateException)

            let imported = makePortableImportSnapshot(
                profileID: collision == .profile ? privateProfile.id : ProfileID(),
                spaceID: collision == .space ? privateSpace.id : SpaceID(),
                tabID: collision == .tab ? privateTab.id : TabID(),
                exceptionID: collision == .siteException
                    ? privateException.id
                    : BlockerSiteExceptionID()
            )
            let data = try XanhPortableBackup.encode(imported)
            let originalProfiles = store.profiles
            let originalSpaces = store.spaces
            let originalTabs = store.tabs
            let originalExceptions = store.blockerSiteExceptions
            let originalSelectedSpaceID = store.selectedSpaceID
            let originalSelectedTabID = store.selectedTabID

            XCTAssertThrowsError(try store.importPortableBackupData(data), "\(collision)")
            XCTAssertEqual(repository.portableImportSaveCount, 0, "\(collision)")
            XCTAssertEqual(store.profiles, originalProfiles, "\(collision)")
            XCTAssertEqual(store.spaces, originalSpaces, "\(collision)")
            XCTAssertEqual(store.tabs, originalTabs, "\(collision)")
            XCTAssertEqual(store.blockerSiteExceptions, originalExceptions, "\(collision)")
            XCTAssertEqual(store.selectedSpaceID, originalSelectedSpaceID, "\(collision)")
            XCTAssertEqual(store.selectedTabID, originalSelectedTabID, "\(collision)")
        }
    }

    func testPortableImportRollsBackWhenRepositorySaveFails() async throws {
        let repository = RecordingBrowserRepository(snapshot: .initial())
        let store = makeStore(repository: repository)
        await store.bootstrap()
        let originalProfileIDs = store.profiles.map(\.id)
        let originalTabIDs = store.tabs.map(\.id)

        var imported = BrowserSnapshot.initial(now: Date(timeIntervalSince1970: 1_700_000_000))
        imported.profiles[0].name = "Must roll back"
        let spaceID = imported.spaces[0].id
        let tab = BrowserTab(
            id: TabID(),
            spaceID: spaceID,
            url: nil,
            title: "New Tab",
            sortIndex: 0,
            lastActiveAt: .now,
            storageMode: .persistent,
            modifiedAt: .now
        )
        imported.tabs = [tab]
        imported.spaces[0].selectedTabID = tab.id
        imported.settings.lastSelectedSpaceID = spaceID
        let encoded = try XanhPortableBackup.encode(imported)
        repository.saveResult = .failure(TestFailure.expected)

        XCTAssertThrowsError(try store.importPortableBackupData(encoded))
        XCTAssertEqual(store.profiles.map(\.id), originalProfileIDs)
        XCTAssertEqual(store.tabs.map(\.id), originalTabIDs)
        XCTAssertFalse(store.profiles.contains { $0.name == "Must roll back" })
    }

    private func makeStore(
        repository: any BrowserRepository,
        profileLocks: FakeProfileLockStore = FakeProfileLockStore(),
        dataStores: any WebsiteDataStoreManaging = WebsiteDataStoreRegistry()
    ) -> BrowserStore {
        BrowserStore(
            repository: repository,
            dataStores: dataStores,
            profileLocks: profileLocks,
            ownerAuthenticator: FakeOwnerAuthenticator(result: .success(())),
            loadBundledRules: false
        )
    }

    private func makeTwoProfileSnapshot() -> (snapshot: BrowserSnapshot, deletedProfileID: ProfileID) {
        var snapshot = BrowserSnapshot.initial()
        let now = Date.now
        let profile = BrowserProfile(
            id: ProfileID(),
            name: "Disposable",
            colorHex: "F58547",
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: now
        )
        let tabID = TabID()
        let space = BrowserSpace(
            id: SpaceID(),
            profileID: profile.id,
            name: profile.name,
            sortIndex: 1,
            selectedTabID: tabID,
            storageMode: .persistent,
            modifiedAt: now
        )
        snapshot.profiles.append(profile)
        snapshot.spaces.append(space)
        snapshot.tabs.append(
            BrowserTab(
                id: tabID,
                spaceID: space.id,
                url: URL(string: "https://delete.example"),
                title: "Delete",
                sortIndex: 0,
                lastActiveAt: now,
                storageMode: .persistent,
                modifiedAt: now
            )
        )
        return (snapshot, profile.id)
    }

    private func makePortableImportSnapshot(
        profileID: ProfileID,
        spaceID: SpaceID,
        tabID: TabID,
        exceptionID: BlockerSiteExceptionID
    ) -> BrowserSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = BrowserProfile(
            id: profileID,
            name: "Imported",
            colorHex: "67F58A",
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: now
        )
        let space = BrowserSpace(
            id: spaceID,
            profileID: profileID,
            name: "Imported",
            sortIndex: 0,
            selectedTabID: tabID,
            storageMode: .persistent,
            modifiedAt: now
        )
        let tab = BrowserTab(
            id: tabID,
            spaceID: spaceID,
            url: URL(string: "https://imported.example"),
            title: "Imported",
            sortIndex: 0,
            lastActiveAt: now,
            storageMode: .persistent,
            modifiedAt: now
        )
        return BrowserSnapshot(
            profiles: [profile],
            spaces: [space],
            tabs: [tab],
            archivedTabs: [],
            blockerSiteExceptions: [
                BlockerSiteException(
                    id: exceptionID,
                    profileID: profileID,
                    host: "imported.example",
                    createdAt: now,
                    modifiedAt: now
                ),
            ],
            bookmarks: [],
            history: [],
            profileDeletionCleanups: [],
            settings: BrowserSettings(lastSelectedSpaceID: spaceID, modifiedAt: now)
        )
    }
}

@MainActor
private final class FakeProfileLockStore: ProfileLocking {
    private var enabled: Set<ProfileID> = []
    private let unlockResult: Result<Void, any Error>
    private let disableResult: Result<Void, any Error>
    private let events: TestEventLog?
    private(set) var disabledProfiles: [ProfileID] = []

    init(
        unlockResult: Result<Void, any Error> = .success(()),
        disableResult: Result<Void, any Error> = .success(()),
        events: TestEventLog? = nil
    ) {
        self.unlockResult = unlockResult
        self.disableResult = disableResult
        self.events = events
    }

    func isEnabled(for profileID: ProfileID) -> Bool { enabled.contains(profileID) }
    func enable(for profileID: ProfileID) throws { enabled.insert(profileID) }
    func disable(for profileID: ProfileID) throws {
        events?.entries.append("keychain-lock")
        try disableResult.get()
        enabled.remove(profileID)
        disabledProfiles.append(profileID)
    }
    func unlock(profileID: ProfileID, reason: String) async throws {
        _ = profileID
        _ = reason
        try unlockResult.get()
    }
}

@MainActor
private final class FakeWebsiteDataStoreManager: WebsiteDataStoreManaging {
    private let transientStore = WKWebsiteDataStore.nonPersistent()
    private var removalResult: Result<Void, any Error>
    private let events: TestEventLog?
    private(set) var removedPersistentProfiles: [ProfileID] = []

    init(
        removalResult: Result<Void, any Error> = .success(()),
        events: TestEventLog? = nil
    ) {
        self.removalResult = removalResult
        self.events = events
    }

    func updateRemovalResult(_ result: Result<Void, any Error>) {
        removalResult = result
    }

    func store(for profile: BrowserProfile) -> WKWebsiteDataStore {
        _ = profile
        return transientStore
    }

    func removeEphemeralStore(for profileID: ProfileID) {
        _ = profileID
    }

    func removePersistentStore(for profileID: ProfileID) async throws {
        events?.entries.append("website-data")
        try removalResult.get()
        removedPersistentProfiles.append(profileID)
    }
}

@MainActor
private final class RecordingBrowserRepository: BrowserRepository {
    var snapshot: BrowserSnapshot
    var saveResult: Result<Void, any Error> = .success(())
    private(set) var syncStatus: BrowserSyncStatus = .localOnly
    var onExternalChange: (@MainActor @Sendable () -> Void)?
    var onSyncStatusChange: (@MainActor @Sendable (BrowserSyncStatus) -> Void)?
    private(set) var portableImportSaveCount = 0
    private let events: TestEventLog?

    init(snapshot: BrowserSnapshot, events: TestEventLog? = nil) {
        self.snapshot = snapshot
        self.events = events
    }

    func load() async throws -> BrowserSnapshot {
        snapshot
    }

    func save(_ snapshot: BrowserSnapshot) throws {
        events?.entries.append("save")
        try saveResult.get()
        self.snapshot = snapshot
    }

    func savePortableImport(_ snapshot: BrowserSnapshot, importedAt: Date) throws {
        portableImportSaveCount += 1
        try save(XanhPortableBackup.rebasedForImport(snapshot, at: importedAt))
    }

    func notifyExternalChange() {
        onExternalChange?()
    }
}

@MainActor
private final class TestEventLog {
    var entries: [String] = []
}

private enum TestFailure: Error {
    case expected
}
