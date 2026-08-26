import SwiftUI

@main
@MainActor
struct XanhIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: BrowserStore

    init() {
        let uiTesting = ProcessInfo.processInfo.environment["XANH_UI_TESTING"] == "1"
        let cloudKitEnabled = Self.infoBoolean("XanhCloudKitEnabled")
        let repository = CoreDataBrowserRepository(inMemory: uiTesting, cloudKitEnabled: cloudKitEnabled)
        let blocker = Self.makeBlockerUpdater()
        _store = State(
            initialValue: BrowserStore(
                repository: repository,
                blockerUpdater: blocker?.service,
                blockerManifestURL: blocker?.manifestURL
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            BrowserShellView(store: store)
                .task { await store.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await store.revealAfterForeground() }
                    case .inactive:
                        store.lockProtectedContent()
                    case .background:
                        store.performAutomaticArchive()
                        store.lockProtectedContent()
                    @unknown default:
                        store.lockProtectedContent()
                    }
                }
        }
        .commands {
            BrowserCommands()
        }
    }

    private static func makeBlockerUpdater() -> (service: BlockerUpdateService, manifestURL: URL)? {
        let updatesEnabled = infoBoolean("XanhBlockerUpdatesEnabled")
        guard updatesEnabled,
              let keyURL = Bundle.main.url(forResource: "blocker-public-key", withExtension: "txt"),
              let encodedKey = try? String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let key = Data(base64Encoded: encodedKey),
              let verifier = try? BlockerVerifier(rawPublicKey: key),
              let manifestString = Bundle.main.object(forInfoDictionaryKey: "XanhBlockerManifestURL") as? String,
              let manifestURL = URL(string: manifestString) else {
            return nil
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return (
            BlockerUpdateService(
                compiler: ContentRuleService(),
                httpClient: URLSessionBlockerHTTPClient(),
                verifier: verifier,
                appVersion: appVersion
            ),
            manifestURL
        )
    }

    private static func infoBoolean(_ key: String) -> Bool {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? Bool {
            return value
        }
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.lowercased()
        return value == "yes" || value == "true" || value == "1"
    }
}
