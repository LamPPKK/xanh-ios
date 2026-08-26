import SwiftUI
import UIKit

struct BrowserShellView: View {
    private enum FocusedControl: Hashable {
        case address
    }

    @Bindable var store: BrowserStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var addressControlHeight: CGFloat = 48
    @State private var address = ""
    @State private var showTabs = false
    @State private var showLibrary = false
    @State private var showDownloads = false
    @State private var showSettings = false
    @State private var commandRouter = BrowserCommandRouter()
    @FocusState private var focusedControl: FocusedControl?

    var body: some View {
        ZStack {
            Color.xanhBackground.ignoresSafeArea()

            if !store.isReady {
                loadingView
            } else if store.selectedProfileIsLocked {
                lockedView
            } else {
                browserChrome
            }

            if store.privacyShieldVisible {
                privacyShield
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showTabs) {
            TabGridView(store: store, isPresented: $showTabs)
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView(store: store, isPresented: $showLibrary)
        }
        .sheet(isPresented: $showDownloads) {
            DownloadsView(store: store, isPresented: $showDownloads)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .alert("Xanh", isPresented: errorBinding) {
            if store.canRecoverFailedPage {
                Button("Reload") { store.retryFailedPage() }
                Button("Open Home") { store.openHomeAfterWebContentFailure() }
            }
            Button("Dismiss", role: .cancel) { store.dismissError() }
        } message: {
            Text(store.errorMessage ?? "The operation could not be completed.")
        }
        .confirmationDialog(
            "Open another app?",
            isPresented: externalURLBinding,
            titleVisibility: .visible
        ) {
            if let url = store.pendingExternalURL {
                Button("Open \(url.scheme?.uppercased() ?? "Link")") {
                    UIApplication.shared.open(url)
                    store.pendingExternalURL = nil
                }
            }
            Button("Cancel", role: .cancel) { store.pendingExternalURL = nil }
        } message: {
            Text(store.pendingExternalURL?.absoluteString ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            store.releaseBackgroundSessions()
        }
        .onChange(of: store.selectedTabID) { _, _ in syncAddress() }
        .onChange(of: store.activeSession?.currentURL) { _, _ in syncAddress() }
        .onChange(of: commandRouter.sequence) { _, _ in handleCommand() }
        .focusedSceneValue(\.browserCommandRouter, commandRouter)
    }

    private var browserChrome: some View {
        VStack(spacing: 0) {
            statusRail
            ZStack(alignment: .top) {
                if let session = store.activeSession {
                    XanhWebView(session: session)
                        .id(session.tabID)
                        .background(Color.xanhBackground)
                    if session.isLoading {
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(Color.xanhGreen)
                                .frame(width: max(2, proxy.size.width * session.estimatedProgress), height: 2)
                                .animation(.easeOut(duration: 0.2), value: session.estimatedProgress)
                        }
                        .frame(height: 2)
                    }
                } else {
                    XanhHomeView(store: store)
                }
            }
            bottomToolbar
        }
    }

    private var statusRail: some View {
        HStack(spacing: 10) {
            XanhBrandMark(size: 30)
            Text("Xanh")
                .font(.headline.weight(.black))
                .foregroundStyle(Color.xanhCream)
            if horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize {
                contextBadge(
                    store.activeProfile?.name.uppercased() ?? "NO PROFILE",
                    systemImage: "person.crop.circle",
                    accent: .xanhGreen
                )
                contextBadge(
                    store.selectedSpace?.name.uppercased() ?? "NO SPACE",
                    systemImage: store.selectedSpace?.storageMode == .ephemeral ? "eye.slash" : "square.stack.3d.up",
                    accent: store.selectedSpace?.storageMode == .ephemeral ? .xanhLeaf : .xanhMuted
                )
            }
            Spacer()
            if horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize {
                Label(store.syncStatus.label, systemImage: "icloud")
                    .foregroundStyle(syncColor)
            }
            Label(
                "\(store.tabsInSelectedSpace.count)",
                systemImage: "square.on.square"
            )
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.xanhMuted)
                .lineLimit(2)
        }
        .font(.caption.weight(.bold))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 48)
        .background(Color.xanhPanel.opacity(0.98))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.xanhBorder).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Browser status")
        .accessibilityValue(statusAccessibilityValue)
        .accessibilityIdentifier("browser.status")
    }

    private var bottomToolbar: some View {
        VStack(spacing: 9) {
            navigationAndAddressRow

            HStack(spacing: 8) {
                Button { showTabs = true } label: {
                    Label("Tabs", systemImage: "square.grid.2x2")
                }
                .accessibilityIdentifier("browser.tabs")
                Spacer()
                if let url = store.activeTab?.url {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("browser.share")
                }
                Button { showLibrary = true } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                .accessibilityIdentifier("browser.library")
                Button { showDownloads = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Label("Downloads", systemImage: "arrow.down.circle")
                        if store.downloadCenter.activeCount > 0 {
                            Text("\(store.downloadCenter.activeCount)")
                                .font(.caption2.monospacedDigit().weight(.black))
                                .foregroundStyle(Color.xanhBackground)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Color.xanhGreen, in: Capsule())
                                .offset(x: 8, y: -8)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityLabel(downloadsAccessibilityLabel)
                .accessibilityIdentifier("browser.downloads")
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("browser.settings")
            }
            .buttonStyle(XanhCompactButtonStyle())
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.xanhBorder)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.xanhBackground)
    }

    @ViewBuilder
    private var navigationAndAddressRow: some View {
        if horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    navigationButtons
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    addressField
                    goButton
                }
            }
        } else {
            HStack(spacing: 6) {
                navigationButtons
                addressField
                goButton
            }
        }
    }

    @ViewBuilder
    private var navigationButtons: some View {
        toolButton("chevron.left", label: "Back", enabled: store.activeSession?.canGoBack == true) {
            store.activeSession?.goBack()
        }
        toolButton("chevron.right", label: "Forward", enabled: store.activeSession?.canGoForward == true) {
            store.activeSession?.goForward()
        }
        toolButton(
            store.activeSession?.isLoading == true ? "xmark" : "arrow.clockwise",
            label: store.activeSession?.isLoading == true ? "Stop" : "Reload"
        ) {
            if store.activeSession?.isLoading == true {
                store.activeSession?.stopLoading()
            } else {
                store.activeSession?.reload()
            }
        }
        toolButton("house", label: "Home") { store.openHome() }
    }

    private var addressField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(focusedControl == .address ? Color.xanhGreen : Color.xanhMuted)
                .accessibilityHidden(true)
            TextField("Address", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(navigate)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .accessibilityLabel("Address and search")
                .accessibilityHint("Enter a website address or search terms")
                .accessibilityIdentifier("browser.omnibox")
                .focused($focusedControl, equals: .address)
            if let host = store.activeBlockerHost {
                shieldsMenu(host: host)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: max(48, addressControlHeight))
        .background(Color.xanhRaised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(focusedControl == .address ? Color.xanhGreen : Color.xanhBorder, lineWidth: 1)
        }
    }

    private func shieldsMenu(host: String) -> some View {
        Menu {
            Section(host) {
                if store.activeProfile?.blockerEnabled == true {
                    Button {
                        store.setShieldsEnabledForActiveSite(!store.shieldsEnabledForActiveSite)
                    } label: {
                        Label(
                            store.shieldsEnabledForActiveSite
                                ? "Pause Shields for \(host)"
                                : "Enable Shields for \(host)",
                            systemImage: store.shieldsEnabledForActiveSite ? "shield.slash" : "shield.checkered"
                        )
                    }
                    if store.activeShieldsPolicyChangePending {
                        Button {
                            store.activeSession?.reload()
                        } label: {
                            Label("Reload to apply", systemImage: "arrow.clockwise")
                        }
                    }
                } else {
                    Label("Shields disabled for this profile", systemImage: "shield.slash")
                }
            }
            Section {
                Text("This setting matches only this exact hostname.")
            }
        } label: {
            Image(systemName: shieldsSymbolName)
                .font(.body.weight(.bold))
                .foregroundStyle(shieldsTint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shields for \(host)")
        .accessibilityValue(shieldsAccessibilityValue)
        .accessibilityHint("Opens privacy controls for this website")
        .accessibilityIdentifier("browser.shields")
    }

    private var shieldsSymbolName: String {
        store.shieldsEnabledForActiveSite ? "shield.lefthalf.filled" : "shield.slash"
    }

    private var shieldsTint: Color {
        store.shieldsEnabledForActiveSite ? .xanhGreen : .xanhLeaf
    }

    private var shieldsAccessibilityValue: String {
        let status = store.shieldsEnabledForActiveSite ? "On" : "Off"
        return store.activeShieldsPolicyChangePending ? "\(status), reload required" : status
    }

    private var goButton: some View {
        Button(action: navigate) {
            Image(systemName: "arrow.up.right")
                .font(.headline.weight(.black))
                .frame(width: 48, height: max(48, addressControlHeight))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.xanhBackground)
        .background(Color.xanhGreen, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityLabel("Go")
        .accessibilityHint("Open the address or search")
        .accessibilityIdentifier("browser.go")
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            XanhBrandMark(size: 72)
            ProgressView().tint(Color.xanhGreen).controlSize(.large)
            Text("INITIALIZING PRIVATE STORES")
                .font(.caption.monospaced().weight(.bold))
                .tracking(1.4)
                .foregroundStyle(Color.xanhMuted)
        }
    }

    private var lockedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(Color.xanhGreen)
            Text("PROFILE LOCKED")
                .font(.title2.monospaced().weight(.black))
            Text("Authenticate to reveal \(store.activeProfile?.name ?? "this profile").")
                .foregroundStyle(Color.xanhMuted)
            Button("Unlock") { Task { await store.unlockActiveProfileIfNeeded() } }
                .buttonStyle(.borderedProminent)
                .tint(Color.xanhGreen)
                .foregroundStyle(Color.xanhBackground)
                .controlSize(.large)
            Button("Recover with device authentication") {
                Task { await store.recoverActiveProfileAccess() }
            }
            .buttonStyle(.bordered)
            .tint(Color.xanhMuted)
        }
        .padding(28)
        .xanhPanel()
        .padding(24)
    }

    private var privacyShield: some View {
        ZStack {
            Color.xanhBackground.ignoresSafeArea()
            XanhSignalField()
            VStack(spacing: 12) {
                XanhBrandMark(size: 104)
                Text("Xanh")
                    .font(.title2.weight(.black))
                Text("CONTENT HIDDEN")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(Color.xanhMuted)
            }
        }
        .accessibilityLabel("Xanh content hidden while the app is inactive")
    }

    private func toolButton(
        _ symbol: String,
        label: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.bold))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        .accessibilityLabel(label)
    }

    private func contextBadge(_ title: String, systemImage: String, accent: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(Color.xanhRaised, in: Capsule())
            .overlay { Capsule().stroke(Color.xanhBorder) }
    }

    private func navigate() {
        do {
            try store.navigate(address)
            focusedControl = nil
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func syncAddress() {
        address = store.activeSession?.currentURL?.absoluteString ?? store.activeTab?.url?.absoluteString ?? ""
    }

    private func handleCommand() {
        guard let request = commandRouter.request else { return }
        switch request {
        case .newTab:
            _ = store.createTab()
            syncAddress()
            focusedControl = .address
        case .closeTab:
            guard let tabID = store.selectedTabID else { return }
            store.closeTab(tabID)
            syncAddress()
        case .focusAddress:
            syncAddress()
            focusedControl = .address
        case .goBack:
            store.activeSession?.goBack()
        case .goForward:
            store.activeSession?.goForward()
        case .reload:
            store.activeSession?.reload()
        case .home:
            store.openHome()
            syncAddress()
        case .showTabs:
            showTabs = true
        case .toggleBookmark:
            store.toggleBookmarkForActiveTab()
        }
    }

    private var statusAccessibilityValue: String {
        let profile = store.activeProfile?.name ?? "No profile"
        let space = store.selectedSpace?.name ?? "No space"
        let tabCount = store.tabsInSelectedSpace.count
        return "Profile \(profile), space \(space), \(tabCount) tab\(tabCount == 1 ? "" : "s"), sync \(store.syncStatus.label)"
    }

    private var syncColor: Color {
        switch store.syncStatus {
        case .available: .xanhGreen
        case .starting, .syncing: .yellow
        case .localOnly: .xanhMuted
        case .degraded: .xanhLeaf
        }
    }

    private var downloadsAccessibilityLabel: String {
        let count = store.downloadCenter.activeCount
        return count == 0 ? "Downloads" : "Downloads, \(count) active"
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )
    }

    private var externalURLBinding: Binding<Bool> {
        Binding(
            get: { store.pendingExternalURL != nil },
            set: { if !$0 { store.pendingExternalURL = nil } }
        )
    }
}

private struct XanhCompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .frame(minWidth: 48, minHeight: 48)
            .contentShape(Rectangle())
            .foregroundStyle(configuration.isPressed ? Color.xanhGreen : Color.xanhCream)
            .background(
                configuration.isPressed ? Color.xanhRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
