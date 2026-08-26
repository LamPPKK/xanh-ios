import SwiftUI
import WebKit

struct XanhWebViewEngineInfo: Equatable, Sendable {
    static let current = XanhWebViewEngineInfo(
        contractVersion: "0.1.0-alpha.1",
        adapter: "xanh-webview/apple",
        backend: "WKWebView",
        backendOwner: "Apple system WebKit",
        fallback: "Apple system WebKit"
    )

    let contractVersion: String
    let adapter: String
    let backend: String
    let backendOwner: String
    let fallback: String

    var displayValue: String {
        "\(backend) · Xanh WebView \(contractVersion)"
    }
}

/// The Xanh WebView embedding boundary for Apple platforms.
///
/// Xanh WebView alpha defines the portable host contract. On iOS this adapter
/// deliberately delegates rendering, storage and process isolation to the
/// system `WKWebView`; it does not claim to ship a forked browser engine.
struct XanhWebView: UIViewRepresentable {
    static let engineInfo = XanhWebViewEngineInfo.current

    let session: BrowserSession

    func makeUIView(context: Context) -> WKWebView {
        session.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
