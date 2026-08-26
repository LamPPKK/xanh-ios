import Observation
import UIKit
import WebKit

@MainActor
@Observable
final class BrowserStore {
    private static let webContentFailureMessage = "The page stopped unexpectedly. Reload it when you are ready."
    private static let historyLifetime: TimeInterval = 90 * 24 * 60 * 60
    private static let archiveLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumArchivedTabsPerProfile = 200
    private static let maximumBlockerSiteExceptionsPerProfile = 500

    private struct ProfileDeletionStateSnapshot {
        let profiles: [BrowserProfile]
        let spaces: [BrowserSpace]
        let tabs: [BrowserTab]
        let archivedTabs: [ArchivedTab]
        let blockerSiteExceptions: [BlockerSiteException]
        let bookmarks: [Bookmark]
        let history: [HistoryVisit]
        let profileDeletionCleanups: [ProfileDeletionCleanup]
        let settings: BrowserSettings
        let selectedSpaceID: SpaceID?
        let selectedTabID: TabID?
        let unlockedProfiles: Set<ProfileID>
    }

    var profiles: [BrowserProfile] = []
    var spaces: [BrowserSpace] = []
    var tabs: [BrowserTab] = []
    var archivedTabs: [ArchivedTab] = []
    var blockerSiteExceptions: [BlockerSiteException] = []
    var bookmarks: [Bookmark] = []
    var history: [HistoryVisit] = []
    var profileDeletionCleanups: [ProfileDeletionCleanup] = []
    var settings = BrowserSettings()
    var selectedSpaceID: SpaceID?
    var selectedTabID: TabID?
    var syncStatus: BrowserSyncStatus = .starting
    var isReady = false
    var errorMessage: String?
    var privacyShieldVisible = false
    var privateSpaceLocked = false
    var blockerStatus = "BUNDLED RULES"
    var pendingExternalURL: URL?
    private(set) var webContentFailureTabID: TabID?
    let downloadCenter: BrowserDownloadCenter

    @ObservationIgnored private let repository: any BrowserRepository
    @ObservationIgnored private let dataStores: any WebsiteDataStoreManaging
    @ObservationIgnored private let ruleCompiler: any ContentRuleCompiling
    @ObservationIgnored private let profileLocks: any ProfileLocking
    @ObservationIgnored private let ownerAuthenticator: any OwnerAuthenticating
    @ObservationIgnored private let loadBundledRules: Bool
    @ObservationIgnored private let blockerUpdater: BlockerUpdateService?
    @ObservationIgnored private let blockerManifestURL: URL?
    @ObservationIgnored private var sessions: [TabID: BrowserSession] = [:]
    @ObservationIgnored private var thumbnails: [TabID: UIImage] = [:]
    @ObservationIgnored private var contentRules: [WKContentRuleList] = []
    @ObservationIgnored private var unlockedProfiles: Set<ProfileID> = []
    @ObservationIgnored private var isProcessingProfileDeletionCleanups = false

    init(
        repository: any BrowserRepository,
        dataStores: any WebsiteDataStoreManaging = WebsiteDataStoreRegistry(),
        ruleCompiler: any ContentRuleCompiling = ContentRuleService(),
        profileLocks: any ProfileLocking = KeychainProfileLockStore(service: "io.github.lamppkk.xanhbrowser.ios.profile-lock"),
        ownerAuthenticator: any OwnerAuthenticating = LocalOwnerAuthenticator(),
        loadBundledRules: Bool = true,
        blockerUpdater: BlockerUpdateService? = nil,
        blockerManifestURL: URL? = nil,
        downloadCenter: BrowserDownloadCenter = BrowserDownloadCenter()
    ) {
        self.repository = repository
        self.dataStores = dataStores
        self.ruleCompiler = ruleCompiler
        self.profileLocks = profileLocks
        self.ownerAuthenticator = ownerAuthenticator
        self.loadBundledRules = loadBundledRules
        self.blockerUpdater = blockerUpdater
        self.blockerManifestURL = blockerManifestURL
        self.downloadCenter = downloadCenter
        self.downloadCenter.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    var selectedSpace: BrowserSpace? {
        spaces.first { $0.id == selectedSpaceID }
    }

    var activeProfile: BrowserProfile? {
        guard let selectedSpace else { return nil }
        return profiles.first { $0.id == selectedSpace.profileID }
    }

    var activeTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var activeSession: BrowserSession? {
        guard let activeTab, activeTab.url != nil else { return nil }
        return session(for: activeTab)
    }

    var activeBlockerHost: String? {
        BlockerSitePolicy.normalizedHost(for: activeTab?.url)
    }

    var shieldsEnabledForActiveSite: Bool {
        guard let profile = activeProfile else { return false }
        return BlockerSitePolicy.rulesEnabled(
            profileEnabled: profile.blockerEnabled,
            for: activeTab?.url,
            allowlistedHosts: blockerAllowlistedHosts(for: profile.id)
        )
    }

    var activeShieldsPolicyChangePending: Bool {
        activeSession?.hasPendingPolicyChange ?? false
    }

    var canRecoverFailedPage: Bool {
        errorMessage == Self.webContentFailureMessage
            && webContentFailureTabID == selectedTabID
            && activeSession != nil
    }

    var tabsInSelectedSpace: [BrowserTab] {
        guard let selectedSpaceID else { return [] }
        return sorted(tabs.filter { $0.spaceID == selectedSpaceID })
    }

    var regularProfiles: [BrowserProfile] {
        profiles.filter { $0.storageMode == .persistent }
    }

    var selectedProfileIsLocked: Bool {
        guard let activeProfile else { return false }
        if activeProfile.storageMode == .ephemeral {
            return privateSpaceLocked
        }
        return profileLocks.isEnabled(for: activeProfile.id) && !unlockedProfiles.contains(activeProfile.id)
    }

    func bootstrap() async {
        guard !isReady else { return }
        repository.onExternalChange = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.mergeExternalChanges()
            }
        }
        repository.onSyncStatusChange = { [weak self] status in
            self?.syncStatus = status
        }
        do {
            let snapshot = try await repository.load()
            profiles = snapshot.profiles
            spaces = sorted(snapshot.spaces)
            tabs = SessionRestoration().restorableTabs(from: snapshot.tabs)
            archivedTabs = snapshot.archivedTabs
            blockerSiteExceptions = sanitizedBlockerSiteExceptions(snapshot.blockerSiteExceptions)
            bookmarks = snapshot.bookmarks.sorted { $0.createdAt > $1.createdAt }
            history = snapshot.history
            profileDeletionCleanups = snapshot.profileDeletionCleanups
            settings = snapshot.settings
            purgeExpiredHistory(now: .now)
            purgeExpiredArchive(now: .now)
            syncStatus = repository.syncStatus
            try await loadContentRules()
            await refreshBlockerRules(force: false)
            ensureSelectionAndTab()
            _ = archiveStaleTabs(now: .now)
            try persist()
            await retryProfileDeletionCleanups()
        } catch {
            let fallback = BrowserSnapshot.initial()
            apply(fallback)
            syncStatus = .degraded(error.localizedDescription)
            errorMessage = "Browser storage is unavailable. This session may not persist changes."
            ensureSelectionAndTab()
        }
        isReady = true
    }

    func navigate(_ rawInput: String) throws {
        guard let profile = activeProfile, let tab = activeTab else { return }
        let url = try URLPolicy(searchProvider: profile.searchProvider).resolve(rawInput)
        updateTab(tab.id, url: url, title: tab.title)
        session(for: tab)?.load(url)
    }

    func openHome() {
        guard let tabID = selectedTabID else { return }
        sessions.removeValue(forKey: tabID)?.webView.stopLoading()
        updateTab(tabID, url: nil, title: "New Tab")
        clearWebContentFailure(for: tabID)
    }

    func retryFailedPage() {
        guard canRecoverFailedPage else { return }
        errorMessage = nil
        webContentFailureTabID = nil
        activeSession?.reload()
    }

    func openHomeAfterWebContentFailure() {
        guard canRecoverFailedPage else { return }
        openHome()
    }

    func dismissError() {
        errorMessage = nil
        webContentFailureTabID = nil
    }

    @discardableResult
    func createTab(
        url: URL? = nil,
        in spaceID: SpaceID? = nil,
        activate: Bool = true,
        pinnedAt: Date? = nil
    ) -> BrowserTab? {
        guard let space = spaces.first(where: { $0.id == (spaceID ?? selectedSpaceID) }) else { return nil }
        let now = Date.now
        let tab = BrowserTab(
            id: TabID(),
            spaceID: space.id,
            url: url,
            title: url?.host() ?? "New Tab",
            sortIndex: (tabs.filter { $0.spaceID == space.id }.map(\.sortIndex).max() ?? -1) + 1,
            lastActiveAt: now,
            pinnedAt: pinnedAt,
            storageMode: space.storageMode,
            modifiedAt: now
        )
        tabs.append(tab)
        if activate {
            selectedSpaceID = space.id
            selectedTabID = tab.id
            setSelectedTab(tab.id, in: space.id)
            rememberSelectedRegularSpace(space.id)
        }
        tryPersist()
        if url != nil {
            _ = session(for: tab)
        }
        return tab
    }

    func activateTab(_ tabID: TabID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        selectedSpaceID = tab.spaceID
        selectedTabID = tab.id
        setSelectedTab(tab.id, in: tab.spaceID)
        rememberSelectedRegularSpace(tab.spaceID)
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index].lastActiveAt = .now
            tabs[index].modifiedAt = .now
        }
        tryPersist()
    }

    func closeTab(_ tabID: TabID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        archiveTabIfEligible(tab, now: .now)
        clearWebContentFailure(for: tabID)
        sessions.removeValue(forKey: tabID)?.webView.stopLoading()
        thumbnails.removeValue(forKey: tabID)
        tabs.removeAll { $0.id == tabID }

        let remaining = sorted(tabs.filter { $0.spaceID == tab.spaceID })
        if selectedTabID == tabID {
            selectedTabID = remaining.last?.id
            setSelectedTab(selectedTabID, in: tab.spaceID)
        }
        if remaining.isEmpty {
            if tab.storageMode == .ephemeral {
                closePrivateSpace(tab.spaceID)
            } else {
                _ = createTab(in: tab.spaceID)
            }
        }
        tryPersist()
    }

    func togglePinned(_ tabID: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].url != nil else { return }
        let now = Date.now
        if tabs[index].pinnedAt == nil {
            tabs[index].pinnedAt = now
        } else {
            tabs[index].pinnedAt = nil
            tabs[index].lastActiveAt = now
        }
        tabs[index].modifiedAt = now
        tryPersist()
    }

    func createSpace(name: String, profileID: ProfileID) {
        guard profiles.contains(where: { $0.id == profileID && $0.storageMode == .persistent }) else { return }
        let now = Date.now
        let space = BrowserSpace(
            id: SpaceID(),
            profileID: profileID,
            name: normalizedName(name, fallback: "Space \(spaces.count + 1)"),
            sortIndex: (spaces.map(\.sortIndex).max() ?? -1) + 1,
            selectedTabID: nil,
            storageMode: .persistent,
            modifiedAt: now
        )
        spaces.append(space)
        selectedSpaceID = space.id
        rememberSelectedRegularSpace(space.id)
        _ = createTab(in: space.id)
        tryPersist()
    }

    func createPrivateSpace() {
        let now = Date.now
        let profile = BrowserProfile.privateProfile(now: now)
        let space = BrowserSpace(
            id: SpaceID(),
            profileID: profile.id,
            name: "Private",
            sortIndex: (spaces.map(\.sortIndex).max() ?? -1) + 1,
            selectedTabID: nil,
            storageMode: .ephemeral,
            modifiedAt: now
        )
        profiles.append(profile)
        spaces.append(space)
        selectedSpaceID = space.id
        _ = createTab(in: space.id)
    }

    func selectSpace(_ spaceID: SpaceID) async {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        selectedSpaceID = space.id
        selectedTabID = space.selectedTabID ?? sorted(tabs.filter { $0.spaceID == space.id }).last?.id
        if selectedTabID == nil {
            _ = createTab(in: space.id)
        }
        rememberSelectedRegularSpace(space.id)
        tryPersist()
        await unlockActiveProfileIfNeeded()
    }

    func createProfile(name: String, colorHex: String = "64D8FF") {
        let now = Date.now
        let profile = BrowserProfile(
            id: ProfileID(),
            name: normalizedName(name, fallback: "Profile \(regularProfiles.count + 1)"),
            colorHex: colorHex,
            storageMode: .persistent,
            searchProvider: .brave,
            blockerEnabled: true,
            modifiedAt: now
        )
        profiles.append(profile)
        createSpace(name: profile.name, profileID: profile.id)
    }

    func deleteProfile(_ profileID: ProfileID) async {
        guard regularProfiles.count > 1,
              profiles.contains(where: { $0.id == profileID && $0.storageMode == .persistent }) else {
            errorMessage = "Keep at least one regular profile."
            return
        }
        let now = Date.now
        let removedSpaces = Set(spaces.filter { $0.profileID == profileID }.map(\.id))
        let removedTabs = tabs.filter { removedSpaces.contains($0.spaceID) }.map(\.id)
        let previousState = profileDeletionStateSnapshot()
        do {
            profiles.removeAll { $0.id == profileID }
            spaces.removeAll { $0.profileID == profileID }
            tabs.removeAll { removedSpaces.contains($0.spaceID) }
            archivedTabs.removeAll { $0.profileID == profileID }
            blockerSiteExceptions.removeAll { $0.profileID == profileID }
            bookmarks.removeAll { $0.profileID == profileID }
            history.removeAll { $0.profileID == profileID }
            unlockedProfiles.remove(profileID)
            enqueueProfileDeletionCleanup(profileID, now: now)
            repairSelectionAfterProfileDeletion(removedSpaces: removedSpaces, now: now)
            try persist()
        } catch {
            restoreProfileDeletionState(previousState)
            errorMessage = "Profile deletion failed: \(error.localizedDescription)"
            return
        }
        for tabID in removedTabs {
            sessions.removeValue(forKey: tabID)?.webView.stopLoading()
            thumbnails.removeValue(forKey: tabID)
        }
        await retryProfileDeletionCleanups()
    }

    private func enqueueProfileDeletionCleanup(_ profileID: ProfileID, now: Date) {
        profileDeletionCleanups.removeAll { $0.profileID == profileID }
        profileDeletionCleanups.append(
            ProfileDeletionCleanup(profileID: profileID, createdAt: now, modifiedAt: now)
        )
    }

    private func repairSelectionAfterProfileDeletion(removedSpaces: Set<SpaceID>, now: Date) {
        let fallbackSpace = sorted(spaces.filter { $0.storageMode == .persistent }).first
        if settings.lastSelectedSpaceID.map(removedSpaces.contains) ?? false {
            settings.lastSelectedSpaceID = fallbackSpace?.id
            settings.modifiedAt = now
        }
        guard selectedSpaceID == nil || selectedSpaceID.map(removedSpaces.contains) == true else { return }
        selectedSpaceID = fallbackSpace?.id
        selectedTabID = fallbackSpace.flatMap { space in
            let candidates = sorted(tabs.filter { $0.spaceID == space.id })
            if let selected = space.selectedTabID, candidates.contains(where: { $0.id == selected }) {
                return selected
            }
            return candidates.last?.id
        }
        if let fallbackSpace {
            if selectedTabID == nil {
                let homeTab = BrowserTab(
                    id: TabID(),
                    spaceID: fallbackSpace.id,
                    url: nil,
                    title: "New Tab",
                    sortIndex: 0,
                    lastActiveAt: now,
                    storageMode: .persistent,
                    modifiedAt: now
                )
                tabs.append(homeTab)
                selectedTabID = homeTab.id
                setSelectedTab(homeTab.id, in: fallbackSpace.id)
            }
            settings.lastSelectedSpaceID = fallbackSpace.id
            settings.modifiedAt = now
        }
    }

    private func profileDeletionStateSnapshot() -> ProfileDeletionStateSnapshot {
        ProfileDeletionStateSnapshot(
            profiles: profiles,
            spaces: spaces,
            tabs: tabs,
            archivedTabs: archivedTabs,
            blockerSiteExceptions: blockerSiteExceptions,
            bookmarks: bookmarks,
            history: history,
            profileDeletionCleanups: profileDeletionCleanups,
            settings: settings,
            selectedSpaceID: selectedSpaceID,
            selectedTabID: selectedTabID,
            unlockedProfiles: unlockedProfiles
        )
    }

    private func restoreProfileDeletionState(_ state: ProfileDeletionStateSnapshot) {
        profiles = state.profiles
        spaces = state.spaces
        tabs = state.tabs
        archivedTabs = state.archivedTabs
        blockerSiteExceptions = state.blockerSiteExceptions
        bookmarks = state.bookmarks
        history = state.history
        profileDeletionCleanups = state.profileDeletionCleanups
        settings = state.settings
        selectedSpaceID = state.selectedSpaceID
        selectedTabID = state.selectedTabID
        unlockedProfiles = state.unlockedProfiles
    }

    private func retryProfileDeletionCleanups() async {
        guard !isProcessingProfileDeletionCleanups else { return }
        isProcessingProfileDeletionCleanups = true
        defer { isProcessingProfileDeletionCleanups = false }

        // Give SwiftUI a run-loop turn to release any active WKWebView before
        // removing its persistent website data store, as required by WebKit.
        await Task.yield()

        var attemptedProfileIDs: Set<ProfileID> = []
        while let profileID = (
            profileDeletionCleanups
                .filter { !$0.isComplete && !attemptedProfileIDs.contains($0.profileID) }
                .map(\.profileID)
                .min(by: { $0.rawValue.uuidString < $1.rawValue.uuidString })
        ) {
            attemptedProfileIDs.insert(profileID)
            guard !profiles.contains(where: { $0.id == profileID }) else {
                profileDeletionCleanups.removeAll { $0.profileID == profileID }
                tryPersist()
                continue
            }
            guard let initialIndex = profileDeletionCleanups.firstIndex(where: { $0.profileID == profileID }) else {
                continue
            }

            if !profileDeletionCleanups[initialIndex].websiteDataRemoved {
                do {
                    try await dataStores.removePersistentStore(for: profileID)
                    guard let index = profileDeletionCleanups.firstIndex(where: { $0.profileID == profileID }) else {
                        continue
                    }
                    let previous = profileDeletionCleanups[index]
                    profileDeletionCleanups[index].websiteDataRemoved = true
                    profileDeletionCleanups[index].modifiedAt = .now
                    do {
                        try persist()
                    } catch {
                        profileDeletionCleanups[index] = previous
                        throw error
                    }
                } catch {
                    errorMessage = "Profile data cleanup is pending and will retry: \(error.localizedDescription)"
                    continue
                }
            }

            guard let lockIndex = profileDeletionCleanups.firstIndex(where: { $0.profileID == profileID }) else {
                continue
            }
            if !profileDeletionCleanups[lockIndex].keychainLockRemoved {
                do {
                    try profileLocks.disable(for: profileID)
                    let previous = profileDeletionCleanups[lockIndex]
                    profileDeletionCleanups[lockIndex].keychainLockRemoved = true
                    profileDeletionCleanups[lockIndex].modifiedAt = .now
                    do {
                        try persist()
                    } catch {
                        profileDeletionCleanups[lockIndex] = previous
                        throw error
                    }
                } catch {
                    errorMessage = "Profile lock cleanup is pending and will retry: \(error.localizedDescription)"
                }
            }
        }
    }

    func toggleBookmarkForActiveTab() {
        guard let profile = activeProfile, profile.storageMode == .persistent,
              let tab = activeTab, let url = tab.url else { return }
        if let existing = bookmarks.firstIndex(where: { $0.profileID == profile.id && $0.url == url }) {
            bookmarks.remove(at: existing)
        } else {
            let now = Date.now
            bookmarks.insert(
                Bookmark(
                    id: BookmarkID(),
                    profileID: profile.id,
                    url: url,
                    title: tab.title,
                    createdAt: now,
                    modifiedAt: now
                ),
                at: 0
            )
        }
        tryPersist()
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let profile = activeProfile, let url else { return false }
        return bookmarks.contains { $0.profileID == profile.id && $0.url == url }
    }

    func removeBookmark(_ id: BookmarkID) {
        bookmarks.removeAll { $0.id == id }
        tryPersist()
    }

    func clearHistory(for profileID: ProfileID) {
        history.removeAll { $0.profileID == profileID }
        tryPersist()
    }

    func makePortableBackupData(exportedAt: Date = .now) throws -> Data {
        try XanhPortableBackup.encode(persistedSnapshot(), exportedAt: exportedAt)
    }

    func importPortableBackupData(_ data: Data, now: Date = .now) throws {
        let imported = XanhPortableBackup.rebasedForImport(
            try XanhPortableBackup.decode(data),
            at: now
        )
        let previousState = profileDeletionStateSnapshot()
        let previousPersistentTabIDs = Set(
            tabs.lazy.filter { $0.storageMode == .persistent }.map(\.id)
        )
        let privateProfiles = profiles.filter { $0.storageMode == .ephemeral }
        let privateSpaces = spaces.filter { $0.storageMode == .ephemeral }
        let privateTabs = tabs.filter { $0.storageMode == .ephemeral }
        let privateProfileIDs = Set(privateProfiles.map(\.id))
        let privateSiteExceptions = blockerSiteExceptions.filter {
            privateProfileIDs.contains($0.profileID)
        }
        try rejectPrivateRuntimeCollisions(
            imported: imported,
            privateProfiles: privateProfiles,
            privateSpaces: privateSpaces,
            privateTabs: privateTabs,
            privateSiteExceptions: privateSiteExceptions
        )
        let selectedPrivateSpaceID = selectedSpaceID.flatMap { selected in
            privateSpaces.contains(where: { $0.id == selected }) ? selected : nil
        }
        let importedProfileIDs = Set(imported.profiles.map(\.id))

        profiles = imported.profiles + privateProfiles
        spaces = sorted(imported.spaces + privateSpaces)
        tabs = sorted(imported.tabs) + privateTabs
        archivedTabs = sorted(imported.archivedTabs)
        blockerSiteExceptions = sanitizedBlockerSiteExceptions(
            imported.blockerSiteExceptions + privateSiteExceptions
        )
        bookmarks = imported.bookmarks.sorted { $0.createdAt > $1.createdAt }
        history = imported.history.sorted { $0.visitedAt > $1.visitedAt }
        profileDeletionCleanups = profileDeletionCleanups.filter {
            !importedProfileIDs.contains($0.profileID)
        }
        settings = imported.settings
        unlockedProfiles = Set(unlockedProfiles.filter(privateProfileIDs.contains))
        purgeExpiredHistory(now: now)
        purgeExpiredArchive(now: now)

        selectedSpaceID = selectedPrivateSpaceID
            ?? settings.lastSelectedSpaceID
            ?? sorted(imported.spaces).first?.id
        if let selectedSpace = spaces.first(where: { $0.id == selectedSpaceID }) {
            selectedTabID = selectedSpace.selectedTabID
                ?? sorted(tabs.filter { $0.spaceID == selectedSpace.id }).last?.id
        } else {
            selectedTabID = nil
        }

        do {
            try repository.savePortableImport(persistedSnapshot(), importedAt: now)
        } catch {
            restoreProfileDeletionState(previousState)
            throw error
        }

        for tabID in previousPersistentTabIDs {
            sessions.removeValue(forKey: tabID)?.webView.stopLoading()
            thumbnails.removeValue(forKey: tabID)
        }
        if let failureTabID = webContentFailureTabID,
           previousPersistentTabIDs.contains(failureTabID) {
            clearWebContentFailure(for: failureTabID)
        }
        for profile in imported.profiles {
            stagePolicyChange(for: profile.id)
        }
    }

    private func rejectPrivateRuntimeCollisions(
        imported: BrowserSnapshot,
        privateProfiles: [BrowserProfile],
        privateSpaces: [BrowserSpace],
        privateTabs: [BrowserTab],
        privateSiteExceptions: [BlockerSiteException]
    ) throws {
        guard Set(imported.profiles.map(\.id)).isDisjoint(with: Set(privateProfiles.map(\.id))) else {
            throw XanhPortableBackupError.invalidReference("profile ID collides with private runtime state")
        }
        guard Set(imported.spaces.map(\.id)).isDisjoint(with: Set(privateSpaces.map(\.id))) else {
            throw XanhPortableBackupError.invalidReference("space ID collides with private runtime state")
        }
        guard Set(imported.tabs.map(\.id)).isDisjoint(with: Set(privateTabs.map(\.id))) else {
            throw XanhPortableBackupError.invalidReference("tab ID collides with private runtime state")
        }
        guard Set(imported.blockerSiteExceptions.map(\.id)).isDisjoint(
            with: Set(privateSiteExceptions.map(\.id))
        ) else {
            throw XanhPortableBackupError.invalidReference(
                "site-exception ID collides with private runtime state"
            )
        }
    }

    @discardableResult
    func restoreArchivedTab(_ archivedTabID: ArchivedTabID) -> BrowserTab? {
        guard let archived = archivedTabs.first(where: { $0.id == archivedTabID }),
              profiles.contains(where: { $0.id == archived.profileID && $0.storageMode == .persistent }) else {
            return nil
        }
        let destination = spaces.first {
            $0.id == archived.sourceSpaceID
                && $0.profileID == archived.profileID
                && $0.storageMode == .persistent
        } ?? sorted(spaces.filter {
            $0.profileID == archived.profileID && $0.storageMode == .persistent
        }).first
        guard let destination else { return nil }

        archivedTabs.removeAll { $0.id == archivedTabID }
        guard let restored = createTab(url: archived.url, in: destination.id, pinnedAt: archived.pinnedAt) else {
            archivedTabs.append(archived)
            return nil
        }
        return restored
    }

    func removeArchivedTab(_ archivedTabID: ArchivedTabID) {
        archivedTabs.removeAll { $0.id == archivedTabID }
        tryPersist()
    }

    func clearArchivedTabs(for profileID: ProfileID) {
        archivedTabs.removeAll { $0.profileID == profileID }
        tryPersist()
    }

    func pauseDownload(_ id: DownloadID) {
        downloadCenter.pause(id)
    }

    func resumeDownload(_ id: DownloadID) {
        do {
            let context = try downloadCenter.resumeContext(for: id)
            guard let profileID = context.item.profileID,
                  let tab = downloadHostTab(for: context.item, profileID: profileID),
                  let session = session(for: tab) else {
                throw BrowserDownloadError.itemUnavailable
            }
            downloadCenter.markResumeStarted(id)
            session.resumeDownload(from: context.data, id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeDownload(_ id: DownloadID) {
        downloadCenter.remove(id)
    }

    func setHistorySyncEnabled(_ enabled: Bool) {
        settings.historySyncEnabled = enabled
        settings.modifiedAt = .now
        tryPersist()
    }

    func setAutomaticArchiveInterval(_ interval: AutomaticArchiveInterval?) {
        settings.automaticArchiveInterval = interval
        settings.modifiedAt = .now
        _ = archiveStaleTabs(now: .now)
        tryPersist()
    }

    @discardableResult
    func performAutomaticArchive(now: Date = .now) -> [TabID] {
        let archived = archiveStaleTabs(now: now)
        if !archived.isEmpty {
            tryPersist()
        }
        return archived
    }

    func updateSearchProvider(_ provider: SearchProvider, for profileID: ProfileID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].searchProvider = provider
        profiles[index].modifiedAt = .now
        stagePolicyChange(for: profileID)
        tryPersist()
    }

    func setBlockerEnabled(_ enabled: Bool, for profileID: ProfileID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].blockerEnabled = enabled
        profiles[index].modifiedAt = .now
        stagePolicyChange(for: profileID)
        tryPersist()
    }

    func setShieldsEnabledForActiveSite(_ enabled: Bool) {
        guard let profile = activeProfile,
              profile.blockerEnabled,
              let host = activeBlockerHost else { return }
        let now = Date.now
        if enabled {
            blockerSiteExceptions.removeAll { $0.profileID == profile.id && $0.host == host }
        } else if !blockerSiteExceptions.contains(where: { $0.profileID == profile.id && $0.host == host }) {
            blockerSiteExceptions.append(
                BlockerSiteException(
                    id: BlockerSiteExceptionID(),
                    profileID: profile.id,
                    host: host,
                    createdAt: now,
                    modifiedAt: now
                )
            )
            blockerSiteExceptions = sanitizedBlockerSiteExceptions(blockerSiteExceptions)
        }
        stagePolicyChange(for: profile.id)
        tryPersist()
    }

    func setBiometricLockEnabled(_ enabled: Bool, for profileID: ProfileID) async {
        do {
            if enabled {
                try profileLocks.enable(for: profileID)
                unlockedProfiles.remove(profileID)
            } else {
                try await ownerAuthenticator.authenticate(reason: "Disable protection for this Xanh profile")
                try profileLocks.disable(for: profileID)
                unlockedProfiles.insert(profileID)
            }
        } catch {
            errorMessage = "Profile protection was not changed: \(error.localizedDescription)"
        }
    }

    func biometricLockEnabled(for profileID: ProfileID) -> Bool {
        profileLocks.isEnabled(for: profileID)
    }

    func unlockActiveProfileIfNeeded() async {
        guard let profile = activeProfile else { return }
        if profile.storageMode == .ephemeral, privateSpaceLocked {
            do {
                try await ownerAuthenticator.authenticate(reason: "Unlock the private Xanh space")
                privateSpaceLocked = false
            } catch {
                errorMessage = "The private space remains locked."
            }
            return
        }
        guard profileLocks.isEnabled(for: profile.id),
              !unlockedProfiles.contains(profile.id) else { return }
        do {
            try await profileLocks.unlock(profileID: profile.id, reason: "Unlock \(profile.name) in Xanh")
            unlockedProfiles.insert(profile.id)
        } catch {
            errorMessage = "Profile remains locked."
        }
    }

    func recoverActiveProfileAccess() async {
        guard let profile = activeProfile, profileLocks.isEnabled(for: profile.id) else { return }
        do {
            try await ownerAuthenticator.authenticate(reason: "Recover access to \(profile.name) in Xanh")
            do {
                try profileLocks.enable(for: profile.id)
            } catch {
                try profileLocks.disable(for: profile.id)
            }
            unlockedProfiles.insert(profile.id)
        } catch {
            errorMessage = "Device-owner authentication failed. The profile remains locked."
        }
    }

    func lockProtectedContent() {
        if activeProfile?.storageMode == .ephemeral {
            privateSpaceLocked = true
        }
        unlockedProfiles.removeAll()
        privacyShieldVisible = true
    }

    func revealAfterForeground() async {
        privacyShieldVisible = false
        await retryProfileDeletionCleanups()
        await unlockActiveProfileIfNeeded()
    }

    func releaseBackgroundSessions() {
        trimBackgroundSessions(keepingMostRecent: 0)
    }

    @discardableResult
    func trimBackgroundSessions(keepingMostRecent retainedCount: Int) -> [TabID] {
        let activeID = selectedTabID
        let loadedBackgroundTabs = tabs
            .filter { $0.id != activeID && sessions[$0.id] != nil }
            .sorted { lhs, rhs in
                if lhs.lastActiveAt == rhs.lastActiveAt {
                    return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                }
                return lhs.lastActiveAt > rhs.lastActiveAt
            }
        let evictedIDs = loadedBackgroundTabs
            .dropFirst(max(0, retainedCount))
            .map(\.id)
        for tabID in evictedIDs {
            guard let session = sessions[tabID] else { continue }
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            session.webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                if let image {
                    self?.thumbnails[tabID] = image
                }
            }
            session.webView.stopLoading()
            sessions.removeValue(forKey: tabID)
        }
        return evictedIDs
    }

    func thumbnail(for tabID: TabID) -> UIImage? {
        thumbnails[tabID]
    }

    func isSessionLoaded(for tabID: TabID) -> Bool {
        sessions[tabID] != nil
    }

    func applyUpdatedContentRules(_ rules: [WKContentRuleList], status: String) {
        contentRules = rules
        blockerStatus = status
        for session in sessions.values {
            guard let profile = profiles.first(where: { $0.id == session.profile.id }) else { continue }
            session.stagePolicy(
                profile: profile,
                contentRules: rules,
                blockerAllowlistedHosts: blockerAllowlistedHosts(for: profile.id)
            )
        }
    }

    func refreshBlockerRules(force: Bool = true) async {
        guard let blockerUpdater, let blockerManifestURL else {
            blockerStatus = contentRules.isEmpty ? "UNAVAILABLE" : "BUNDLED RULES"
            return
        }
        do {
            let result = try await blockerUpdater.update(from: blockerManifestURL, force: force)
            let installed = try await blockerUpdater.installedRules()
            if !installed.isEmpty {
                applyUpdatedContentRules(installed, status: blockerStatus(for: result))
            }
        } catch {
            blockerStatus = contentRules.isEmpty ? "UPDATE FAILED" : "LAST-KNOWN-GOOD"
        }
    }

    private func loadContentRules() async throws {
        guard loadBundledRules else { return }
        if let resource = Bundle.main.url(forResource: "content-rules", withExtension: "json") {
            let encoded = try String(contentsOf: resource, encoding: .utf8)
            contentRules = [try await ruleCompiler.compile(identifier: "xanh-bundled-v1", encodedRules: encoded)]
        }
        if let installed = try await blockerUpdater?.installedRules(), !installed.isEmpty {
            contentRules = installed
            blockerStatus = "INSTALLED RULES"
        }
    }

    private func mergeExternalChanges() async {
        do {
            let snapshot = try await repository.load()
            let incomingPersistentProfileIDs = Set(snapshot.profiles.map(\.id))
            let privateProfiles = profiles.filter { $0.storageMode == .ephemeral }
            let privateSpaces = spaces.filter { $0.storageMode == .ephemeral }
            let privateTabs = tabs.filter { $0.storageMode == .ephemeral }
            let privateProfileIDs = Set(privateProfiles.map(\.id))
            let privateBlockerSiteExceptions = blockerSiteExceptions.filter {
                privateProfileIDs.contains($0.profileID)
            }
            let incomingTabIDs = Set(snapshot.tabs.map(\.id))
            for tab in tabs where tab.storageMode == .persistent && !incomingTabIDs.contains(tab.id) {
                sessions.removeValue(forKey: tab.id)?.webView.stopLoading()
                thumbnails.removeValue(forKey: tab.id)
            }
            profiles = snapshot.profiles + privateProfiles
            spaces = sorted(snapshot.spaces + privateSpaces)
            tabs = SessionRestoration().restorableTabs(from: snapshot.tabs) + privateTabs
            archivedTabs = snapshot.archivedTabs
            blockerSiteExceptions = sanitizedBlockerSiteExceptions(
                snapshot.blockerSiteExceptions + privateBlockerSiteExceptions
            )
            bookmarks = snapshot.bookmarks.sorted { $0.createdAt > $1.createdAt }
            history = snapshot.history
            let mergedCleanups = mergedProfileDeletionCleanups(
                snapshot.profileDeletionCleanups,
                excluding: incomingPersistentProfileIDs
            )
            let cleanupLedgerChanged = Set(mergedCleanups) != Set(snapshot.profileDeletionCleanups)
            profileDeletionCleanups = mergedCleanups
            settings = snapshot.settings
            purgeExpiredArchive(now: .now)
            syncStatus = repository.syncStatus
            ensureSelectionAndTab()
            for profile in profiles {
                stagePolicyChange(for: profile.id)
            }
            if !archiveStaleTabs(now: .now).isEmpty || cleanupLedgerChanged {
                tryPersist()
            }
            await retryProfileDeletionCleanups()
        } catch {
            syncStatus = .degraded(error.localizedDescription)
        }
    }

    private func mergedProfileDeletionCleanups(
        _ incoming: [ProfileDeletionCleanup],
        excluding activeProfileIDs: Set<ProfileID>
    ) -> [ProfileDeletionCleanup] {
        var byProfile: [ProfileID: ProfileDeletionCleanup] = [:]
        for candidate in profileDeletionCleanups + incoming {
            if let existing = byProfile[candidate.profileID] {
                byProfile[candidate.profileID] = ProfileDeletionCleanup(
                    profileID: candidate.profileID,
                    websiteDataRemoved: existing.websiteDataRemoved || candidate.websiteDataRemoved,
                    keychainLockRemoved: existing.keychainLockRemoved || candidate.keychainLockRemoved,
                    createdAt: min(existing.createdAt, candidate.createdAt),
                    modifiedAt: max(existing.modifiedAt, candidate.modifiedAt)
                )
            } else {
                byProfile[candidate.profileID] = candidate
            }
        }
        return byProfile.values
            .filter { !activeProfileIDs.contains($0.profileID) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.profileID.rawValue.uuidString < rhs.profileID.rawValue.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private func blockerStatus(for result: BlockerUpdateResult) -> String {
        switch result {
        case .notDue: "UP TO DATE"
        case .unchanged: "UP TO DATE"
        case let .installed(version): "RULES \(version)"
        }
    }

    private func session(for tab: BrowserTab) -> BrowserSession? {
        if let existing = sessions[tab.id] {
            return existing
        }
        guard let space = spaces.first(where: { $0.id == tab.spaceID }),
              let profile = profiles.first(where: { $0.id == space.profileID }) else { return nil }
        let session = BrowserSession(
            tabID: tab.id,
            profile: profile,
            dataStore: dataStores.store(for: profile),
            contentRules: contentRules,
            blockerAllowlistedHosts: blockerAllowlistedHosts(for: profile.id),
            initialURL: tab.url
        )
        session.onStateChange = { [weak self] session in
            self?.syncTabState(from: session)
        }
        session.onNavigationFinished = { [weak self] session in
            self?.recordHistory(from: session)
        }
        session.onOpenNewTab = { [weak self] url in
            _ = self?.createTab(url: url, in: tab.spaceID)
        }
        session.onExternalURL = { [weak self] url in
            self?.pendingExternalURL = url
        }
        session.onWebContentProcessTerminated = { [weak self] session in
            self?.handleWebContentProcessTermination(for: session)
        }
        session.onDownloadStarted = { [weak self] download, existingID in
            guard let self else { return }
            self.downloadCenter.accept(
                download,
                tabID: tab.id,
                profileID: profile.id,
                isPrivate: profile.storageMode == .ephemeral,
                resuming: existingID
            )
        }
        sessions[tab.id] = session
        if let url = tab.url {
            session.load(url)
        }
        return session
    }

    private func handleWebContentProcessTermination(for session: BrowserSession) {
        let isActive = session.tabID == selectedTabID
        switch session.recoverFromWebContentProcessTermination(isActive: isActive) {
        case .reload:
            break
        case .discard:
            sessions.removeValue(forKey: session.tabID)
        case .reportFailure:
            webContentFailureTabID = session.tabID
            errorMessage = Self.webContentFailureMessage
        }
    }

    private func clearWebContentFailure(for tabID: TabID) {
        guard webContentFailureTabID == tabID else { return }
        webContentFailureTabID = nil
        if errorMessage == Self.webContentFailureMessage {
            errorMessage = nil
        }
    }

    private func syncTabState(from session: BrowserSession) {
        guard let index = tabs.firstIndex(where: { $0.id == session.tabID }) else { return }
        tabs[index].url = session.currentURL
        tabs[index].title = session.pageTitle ?? session.currentURL?.host() ?? "New Tab"
        tabs[index].modifiedAt = .now
        tryPersist()
    }

    private func recordHistory(from session: BrowserSession) {
        guard session.profile.storageMode == .persistent,
              let url = session.currentURL,
              URLPolicy(searchProvider: session.profile.searchProvider).allowsNavigation(to: url) else { return }
        let now = Date.now
        history.insert(
            HistoryVisit(
                id: HistoryVisitID(),
                profileID: session.profile.id,
                url: url,
                title: session.pageTitle ?? url.host() ?? url.absoluteString,
                visitedAt: now,
                modifiedAt: now
            ),
            at: 0
        )
        purgeExpiredHistory(now: now)
        tryPersist()
    }

    private func purgeExpiredHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.historyLifetime)
        history.removeAll { $0.visitedAt < cutoff }
    }

    @discardableResult
    private func archiveTabIfEligible(_ tab: BrowserTab, now: Date) -> Bool {
        guard tab.storageMode == .persistent,
              let url = tab.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let space = spaces.first(where: { $0.id == tab.spaceID && $0.storageMode == .persistent }),
              let profile = profiles.first(where: { $0.id == space.profileID && $0.storageMode == .persistent }),
              URLPolicy(searchProvider: profile.searchProvider).allowsNavigation(to: url) else { return false }
        archivedTabs.append(
            ArchivedTab(
                id: ArchivedTabID(),
                profileID: profile.id,
                sourceSpaceID: space.id,
                url: url,
                title: String((tab.title.isEmpty ? url.host() ?? url.absoluteString : tab.title).prefix(256)),
                archivedAt: now,
                pinnedAt: tab.pinnedAt,
                modifiedAt: now
            )
        )
        purgeExpiredArchive(now: now)
        return true
    }

    private func archiveStaleTabs(now: Date) -> [TabID] {
        guard let interval = settings.automaticArchiveInterval else { return [] }
        let cutoff = now.addingTimeInterval(-interval.timeInterval)
        var protectedTabIDs: Set<TabID> = []
        if let selectedTabID {
            protectedTabIDs.insert(selectedTabID)
        }
        let candidates = tabs.filter { tab in
            tab.storageMode == .persistent
                && tab.pinnedAt == nil
                && tab.lastActiveAt <= cutoff
                && !protectedTabIDs.contains(tab.id)
        }
        var archivedIDs: [TabID] = []
        for tab in candidates where archiveTabIfEligible(tab, now: now) {
            sessions.removeValue(forKey: tab.id)?.webView.stopLoading()
            thumbnails.removeValue(forKey: tab.id)
            archivedIDs.append(tab.id)
        }
        guard !archivedIDs.isEmpty else { return [] }
        let archivedIDSet = Set(archivedIDs)
        tabs.removeAll { archivedIDSet.contains($0.id) }
        for index in spaces.indices {
            guard let selected = spaces[index].selectedTabID, archivedIDSet.contains(selected) else { continue }
            spaces[index].selectedTabID = sorted(tabs.filter { $0.spaceID == spaces[index].id }).last?.id
            spaces[index].modifiedAt = now
        }
        return archivedIDs
    }

    private func purgeExpiredArchive(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.archiveLifetime)
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let valid = archivedTabs.filter { archived in
            guard archived.archivedAt >= cutoff,
                  let profile = profilesByID[archived.profileID],
                  profile.storageMode == .persistent else { return false }
            return URLPolicy(searchProvider: profile.searchProvider).allowsNavigation(to: archived.url)
        }
        var retained: [ArchivedTab] = []
        for profileID in Set(valid.map(\.profileID)) {
            retained.append(contentsOf: sorted(valid.filter { $0.profileID == profileID })
                .prefix(Self.maximumArchivedTabsPerProfile))
        }
        archivedTabs = sorted(retained)
    }

    private func updateTab(_ tabID: TabID, url: URL?, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].url = url
        tabs[index].title = title
        tabs[index].modifiedAt = .now
        tabs[index].lastActiveAt = .now
        tryPersist()
    }

    private func setSelectedTab(_ tabID: TabID?, in spaceID: SpaceID) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[index].selectedTabID = tabID
        spaces[index].modifiedAt = .now
    }

    private func ensureSelectionAndTab() {
        if profiles.isEmpty {
            apply(.initial())
        }
        if spaces.filter({ $0.storageMode == .persistent }).isEmpty, let profile = regularProfiles.first {
            createSpace(name: "Main", profileID: profile.id)
            return
        }
        if selectedSpaceID == nil || !spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = settings.lastSelectedSpaceID
                .flatMap { remembered in spaces.first(where: { $0.id == remembered && $0.storageMode == .persistent })?.id }
                ?? sorted(spaces).first?.id
        }
        guard let space = selectedSpace else { return }
        rememberSelectedRegularSpace(space.id)
        selectedTabID = space.selectedTabID
            ?? sorted(tabs.filter { $0.spaceID == space.id }).last?.id
        if selectedTabID == nil {
            _ = createTab(in: space.id)
        }
    }

    private func closePrivateSpace(_ spaceID: SpaceID) {
        guard let space = spaces.first(where: { $0.id == spaceID }), space.storageMode == .ephemeral else { return }
        downloadCenter.removePrivateDownloads(for: space.profileID)
        blockerSiteExceptions.removeAll { $0.profileID == space.profileID }
        spaces.removeAll { $0.id == spaceID }
        profiles.removeAll { $0.id == space.profileID }
        dataStores.removeEphemeralStore(for: space.profileID)
        selectedSpaceID = sorted(spaces).first?.id
        selectedTabID = selectedSpace?.selectedTabID
        if let selectedSpaceID {
            rememberSelectedRegularSpace(selectedSpaceID)
        }
        ensureSelectionAndTab()
    }

    private func downloadHostTab(for item: BrowserDownloadItem, profileID: ProfileID) -> BrowserTab? {
        let profileSpaceIDs = Set(spaces.filter { $0.profileID == profileID }.map(\.id))
        if let original = item.tabID
            .flatMap({ id in tabs.first(where: { $0.id == id && profileSpaceIDs.contains($0.spaceID) }) }) {
            return original
        }
        if let existing = tabs.first(where: { profileSpaceIDs.contains($0.spaceID) }) {
            return existing
        }
        guard let spaceID = spaces.first(where: { $0.profileID == profileID })?.id else { return nil }
        return createTab(in: spaceID, activate: false)
    }

    private func stagePolicyChange(for profileID: ProfileID) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let affectedSpaces = Set(spaces.filter { $0.profileID == profileID }.map(\.id))
        let affectedTabs = tabs.filter { affectedSpaces.contains($0.spaceID) }
        for tab in affectedTabs {
            sessions[tab.id]?.stagePolicy(
                profile: profile,
                contentRules: contentRules,
                blockerAllowlistedHosts: blockerAllowlistedHosts(for: profileID)
            )
        }
    }

    private func blockerAllowlistedHosts(for profileID: ProfileID) -> Set<String> {
        Set(blockerSiteExceptions.lazy.filter { $0.profileID == profileID }.map(\.host))
    }

    private func sanitizedBlockerSiteExceptions(
        _ candidates: [BlockerSiteException]
    ) -> [BlockerSiteException] {
        let profileIDs = Set(profiles.map(\.id))
        var newestByProfileAndHost: [String: BlockerSiteException] = [:]
        for candidate in candidates {
            guard profileIDs.contains(candidate.profileID),
                  let host = BlockerSitePolicy.normalizedHost(candidate.host) else { continue }
            let normalized = BlockerSiteException(
                id: candidate.id,
                profileID: candidate.profileID,
                host: host,
                createdAt: candidate.createdAt,
                modifiedAt: candidate.modifiedAt
            )
            let key = "\(candidate.profileID.rawValue.uuidString)|\(host)"
            if let current = newestByProfileAndHost[key],
               current.modifiedAt > normalized.modifiedAt
                || (current.modifiedAt == normalized.modifiedAt
                    && current.id.rawValue.uuidString < normalized.id.rawValue.uuidString) {
                continue
            }
            newestByProfileAndHost[key] = normalized
        }
        return profiles.flatMap { profile in
            newestByProfileAndHost.values
                .filter { $0.profileID == profile.id }
                .sorted { lhs, rhs in
                    if lhs.modifiedAt == rhs.modifiedAt {
                        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                    }
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                .prefix(Self.maximumBlockerSiteExceptionsPerProfile)
        }
    }

    private func persist() throws {
        try repository.save(persistedSnapshot())
    }

    private func tryPersist() {
        do {
            try persist()
        } catch {
            syncStatus = .degraded(error.localizedDescription)
        }
    }

    private func persistedSnapshot() -> BrowserSnapshot {
        BrowserSnapshot(
            profiles: profiles.filter { $0.storageMode == .persistent },
            spaces: spaces.filter { $0.storageMode == .persistent },
            tabs: tabs.filter { $0.storageMode == .persistent },
            archivedTabs: archivedTabs,
            blockerSiteExceptions: blockerSiteExceptions.filter { exception in
                profiles.contains {
                    $0.id == exception.profileID && $0.storageMode == .persistent
                }
            },
            bookmarks: bookmarks,
            history: history,
            profileDeletionCleanups: profileDeletionCleanups.filter { cleanup in
                !profiles.contains { $0.id == cleanup.profileID && $0.storageMode == .persistent }
            },
            settings: settings
        )
    }

    private func apply(_ snapshot: BrowserSnapshot) {
        profiles = snapshot.profiles
        spaces = sorted(snapshot.spaces)
        tabs = SessionRestoration().restorableTabs(from: snapshot.tabs)
        archivedTabs = snapshot.archivedTabs
        blockerSiteExceptions = sanitizedBlockerSiteExceptions(snapshot.blockerSiteExceptions)
        bookmarks = snapshot.bookmarks
        history = snapshot.history
        profileDeletionCleanups = snapshot.profileDeletionCleanups
        settings = snapshot.settings
    }

    private func sorted(_ spaces: [BrowserSpace]) -> [BrowserSpace] {
        spaces.sorted { lhs, rhs in
            if lhs.sortIndex == rhs.sortIndex {
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            }
            return lhs.sortIndex < rhs.sortIndex
        }
    }

    private func sorted(_ tabs: [BrowserTab]) -> [BrowserTab] {
        tabs.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            if let lhsPinned = lhs.pinnedAt, let rhsPinned = rhs.pinnedAt, lhsPinned != rhsPinned {
                return lhsPinned < rhsPinned
            }
            if lhs.sortIndex == rhs.sortIndex {
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            }
            return lhs.sortIndex < rhs.sortIndex
        }
    }

    private func sorted(_ archivedTabs: [ArchivedTab]) -> [ArchivedTab] {
        archivedTabs.sorted { lhs, rhs in
            if lhs.archivedAt == rhs.archivedAt {
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            }
            return lhs.archivedAt > rhs.archivedAt
        }
    }

    private func normalizedName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(48))
    }

    private func rememberSelectedRegularSpace(_ spaceID: SpaceID) {
        guard let space = spaces.first(where: { $0.id == spaceID }),
              space.storageMode == .persistent,
              settings.lastSelectedSpaceID != spaceID else { return }
        settings.lastSelectedSpaceID = spaceID
        settings.modifiedAt = .now
    }
}
