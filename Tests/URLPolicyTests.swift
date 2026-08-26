import XCTest
@testable import XanhIOS

final class URLPolicyTests: XCTestCase {
    func testAddsHTTPSForHostname() throws {
        XCTAssertEqual(try URLPolicy().resolve("example.com").absoluteString, "https://example.com")
    }

    func testBuildsEncodedSearchURL() throws {
        let url = try URLPolicy().resolve("private browser")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "search.brave.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "private browser")
    }

    func testSearchProviderCanBeChangedPerProfile() throws {
        let url = try URLPolicy(searchProvider: .duckDuckGo).resolve("private browser")
        XCTAssertEqual(url.host, "duckduckgo.com")
    }

    func testExternalSchemesRequireConfirmation() throws {
        let policy = URLPolicy()
        XCTAssertEqual(
            policy.disposition(for: try XCTUnwrap(URL(string: "mailto:security@example.com"))),
            .externalConfirmation
        )
        XCTAssertEqual(
            policy.disposition(for: try XCTUnwrap(URL(string: "tel:+15551212"))),
            .externalConfirmation
        )
    }

    func testRejectsScriptAndFileSchemes() {
        XCTAssertThrowsError(try URLPolicy().resolve("javascript:alert(1)"))
        XCTAssertThrowsError(try URLPolicy().resolve("file:///etc/passwd"))
    }

    func testNavigationDelegatePolicyRejectsNonWebSchemes() throws {
        let policy = URLPolicy()
        XCTAssertTrue(policy.allowsNavigation(to: try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertTrue(policy.allowsNavigation(to: try XCTUnwrap(URL(string: "about:blank"))))
        XCTAssertFalse(policy.allowsNavigation(to: try XCTUnwrap(URL(string: "data:text/html,secret"))))
        XCTAssertFalse(policy.allowsNavigation(to: try XCTUnwrap(URL(string: "xanh://profile"))))
    }
}
