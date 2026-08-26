import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private struct BackupNotice: Identifiable {
        let id = UUID()
        let message: String
    }

    @Bindable var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var showHistoryConsent = false
    @State private var showDeleteProfile = false
    @State private var backupDocument: XanhBackupDocument?
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var backupNotice: BackupNotice?
    @State private var pendingBackupData: Data?
    @State private var pendingBackupSummary = ""
    @State private var showImportConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.xanhBackground.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 22) {
                        profileSection
                        privacySection
                        tabsSection
                        backupSection
                        syncSection
                        aboutSection
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .confirmationDialog(
                "Sync browsing history with iCloud?",
                isPresented: $showHistoryConsent,
                titleVisibility: .visible
            ) {
                Button("Enable 90-day history sync") { store.setHistorySyncEnabled(true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Visited URLs, page titles and visit times will be stored in your private iCloud database. Cookies, passwords and private tabs are never included.")
            }
            .confirmationDialog(
                "Delete this profile?",
                isPresented: $showDeleteProfile,
                titleVisibility: .visible
            ) {
                if let profile = store.activeProfile {
                    Button("Delete \(profile.name)", role: .destructive) {
                        Task { await store.deleteProfile(profile.id) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Xanh will remove the profile's tabs, Archive entries, bookmarks, history, Keychain lock and local WebKit website data.")
            }
            .fileExporter(
                isPresented: $isExportingBackup,
                document: backupDocument,
                contentType: .xanhPortableBackup,
                defaultFilename: "Xanh-Backup"
            ) { result in
                switch result {
                case let .success(url):
                    backupNotice = BackupNotice(message: "Backup exported to \(url.lastPathComponent).")
                case let .failure(error):
                    backupNotice = BackupNotice(message: "Export failed: \(error.localizedDescription)")
                }
            }
            .fileImporter(
                isPresented: $isImportingBackup,
                allowedContentTypes: [.xanhPortableBackup, .json],
                allowsMultipleSelection: false
            ) { result in
                prepareBackupImport(result)
            }
            .confirmationDialog(
                "Replace regular browser metadata?",
                isPresented: $showImportConfirmation,
                titleVisibility: .visible
            ) {
                Button("Import and replace", role: .destructive) {
                    confirmBackupImport()
                }
                Button("Cancel", role: .cancel) {
                    pendingBackupData = nil
                    pendingBackupSummary = ""
                }
            } message: {
                Text("\(pendingBackupSummary) The validated backup replaces regular metadata and may synchronize through iCloud. Private runtime state and website data are not changed.")
            }
            .alert(item: $backupNotice) { notice in
                Alert(
                    title: Text("Xanh backup"),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private var profileSection: some View {
        settingsSection("Active profile", index: "01") {
            if let profile = store.activeProfile {
                settingsValue("Name", value: profile.name)
                settingsValue(
                    "Storage",
                    value: profile.storageMode == .persistent
                        ? "Persistent / isolated"
                        : "Private / memory"
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Search engine")
                        .font(.body.weight(.semibold))
                    Menu {
                        ForEach(SearchProvider.allCases, id: \.self) { provider in
                            Button {
                                store.updateSearchProvider(provider, for: profile.id)
                            } label: {
                                if profile.searchProvider == provider {
                                    Label(provider.displayName, systemImage: "checkmark")
                                } else {
                                    Text(provider.displayName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(profile.searchProvider.displayName)
                                .font(.body)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(Color.xanhGreen)
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .background(
                            Color.xanhRaised,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                    .accessibilityLabel("Search engine")
                    .accessibilityValue(profile.searchProvider.displayName)
                }
                .disabled(profile.storageMode == .ephemeral)

                if profile.storageMode == .persistent && store.regularProfiles.count > 1 {
                    settingsButton("Delete profile", systemImage: "trash", role: .destructive) {
                        showDeleteProfile = true
                    }
                }
            }
        }
    }

    private var privacySection: some View {
        settingsSection("Privacy", index: "02") {
            if let profile = store.activeProfile {
                Toggle("Content blocker", isOn: blockerBinding(profile))
                    .font(.body)
                    .frame(minHeight: 48)
                    .disabled(profile.storageMode == .ephemeral)

                settingsValue("Rules", value: store.blockerStatus)
                settingsButton("Update rules", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await store.refreshBlockerRules() }
                }

                if profile.storageMode == .persistent {
                    Toggle("Biometric lock", isOn: biometricBinding(profile))
                        .font(.body)
                        .frame(minHeight: 48)
                }
            }
            settingsValue("Private tabs", value: "Never restored")
            settingsValue("Telemetry", value: "None")
        }
    }

    private var syncSection: some View {
        settingsSection("iCloud private database", index: "05") {
            settingsValue("Status", value: store.syncStatus.label)
            Text(store.syncStatus.detail)
                .font(.body)
                .foregroundStyle(Color.xanhMuted)
                .fixedSize(horizontal: false, vertical: true)
            settingsButton(
                store.settings.historySyncEnabled ? "Disable history sync" : "History sync",
                systemImage: "icloud"
            ) {
                if store.settings.historySyncEnabled {
                    store.setHistorySyncEnabled(false)
                } else {
                    showHistoryConsent = true
                }
            }
            Text("Profiles, spaces, regular tabs, Archive metadata and bookmarks sync when iCloud is available. History is opt-in and retained for 90 days.")
                .font(.body)
                .foregroundStyle(Color.xanhMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var backupSection: some View {
        settingsSection("Portable backup", index: "04") {
            settingsButton("Export backup", systemImage: "square.and.arrow.up") {
                do {
                    backupDocument = XanhBackupDocument(data: try store.makePortableBackupData())
                    isExportingBackup = true
                } catch {
                    backupNotice = BackupNotice(message: "Export failed: \(error.localizedDescription)")
                }
            }
            .accessibilityIdentifier("settings.backup.export")
            settingsButton("Import backup", systemImage: "square.and.arrow.down") {
                isImportingBackup = true
            }
            .accessibilityIdentifier("settings.backup.import")
            Text("The export is unencrypted JSON and contains browsing data such as URLs, page titles and history. Keep the file secure. It is a Xanh iOS backup, not an Android or general browser interchange format.")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.xanhLeaf)
                .fixedSize(horizontal: false, vertical: true)
            Text("Included: regular profiles, spaces, tabs, Archive, bookmarks, history, settings and Shields exceptions. Excluded: private data, credentials, cookies, cache, website data and downloads.")
                .font(.body)
                .foregroundStyle(Color.xanhMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tabsSection: some View {
        settingsSection("Tab lifecycle", index: "03") {
            Picker("Automatic Archive", selection: automaticArchiveBinding) {
                Text("Off").tag(AutomaticArchiveInterval?.none)
                ForEach(AutomaticArchiveInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(Optional(interval))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .accessibilityIdentifier("settings.auto-archive")

            Text("Inactive regular tabs move to Archive on launch or when Xanh enters the background. Active, pinned, Home and private tabs are never moved automatically.")
                .font(.body)
                .foregroundStyle(Color.xanhMuted)
                .fixedSize(horizontal: false, vertical: true)
            settingsValue("Archive retention", value: "30 days / 200 tabs per profile")
        }
    }

    private var aboutSection: some View {
        settingsSection("About", index: "06") {
            settingsValue("Application", value: "Xanh Browser")
            settingsValue("Version", value: "0.1.0")
            settingsValue("Web engine", value: XanhWebView.engineInfo.displayValue)
            settingsValue("Engine owner", value: XanhWebView.engineInfo.backendOwner)
            settingsLink(
                "Privacy policy",
                systemImage: "hand.raised",
                destination: URL(string: "https://lamppkk.github.io/xanh-ios/privacy.html")!
            )
            settingsLink(
                "Support",
                systemImage: "questionmark.circle",
                destination: URL(string: "https://lamppkk.github.io/xanh-ios/support.html")!
            )
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        index: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            XanhSectionLabel(title: title, index: index)
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.xanhPanel,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.1))
            }
        }
    }

    private func settingsValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(value)
                .font(.body)
                .foregroundStyle(Color.xanhMuted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func settingsButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private func settingsLink(_ title: String, systemImage: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private func blockerBinding(_ profile: BrowserProfile) -> Binding<Bool> {
        Binding(
            get: { store.profiles.first(where: { $0.id == profile.id })?.blockerEnabled ?? false },
            set: { store.setBlockerEnabled($0, for: profile.id) }
        )
    }

    private func biometricBinding(_ profile: BrowserProfile) -> Binding<Bool> {
        Binding(
            get: { store.biometricLockEnabled(for: profile.id) },
            set: { enabled in
                Task { await store.setBiometricLockEnabled(enabled, for: profile.id) }
            }
        )
    }

    private var automaticArchiveBinding: Binding<AutomaticArchiveInterval?> {
        Binding(
            get: { store.settings.automaticArchiveInterval },
            set: { store.setAutomaticArchiveInterval($0) }
        )
    }

    private func prepareBackupImport(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else {
                throw XanhPortableBackupError.emptyDocument
            }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let snapshot = try XanhPortableBackup.decode(data)
            pendingBackupData = data
            pendingBackupSummary = "\(snapshot.profiles.count) profiles, \(snapshot.spaces.count) spaces and \(snapshot.tabs.count) tabs are ready to import."
            showImportConfirmation = true
        } catch {
            backupNotice = BackupNotice(message: "Import failed: \(error.localizedDescription)")
        }
    }

    private func confirmBackupImport() {
        guard let pendingBackupData else { return }
        defer {
            self.pendingBackupData = nil
            pendingBackupSummary = ""
        }
        do {
            try store.importPortableBackupData(pendingBackupData)
            backupNotice = BackupNotice(message: "Regular browser metadata was imported. Private browsing state and website data were not changed.")
        } catch {
            backupNotice = BackupNotice(message: "Import failed: \(error.localizedDescription)")
        }
    }
}
