import XCTest
@testable import XanhIOS

final class XanhWebViewContractTests: XCTestCase {
    @MainActor
    func testAppleAdapterReportsSystemBackendTruthfully() {
        let engine = XanhWebView.engineInfo

        XCTAssertEqual(engine.contractVersion, "0.1.0-alpha.1")
        XCTAssertEqual(engine.adapter, "xanh-webview/apple")
        XCTAssertEqual(engine.backend, "WKWebView")
        XCTAssertEqual(engine.backendOwner, "Apple system WebKit")
        XCTAssertEqual(engine.fallback, "Apple system WebKit")
    }
}
