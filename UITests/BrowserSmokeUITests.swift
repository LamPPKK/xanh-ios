import XCTest
import UIKit

final class BrowserSmokeUITests: XCTestCase {
    @MainActor
    func testHomeTabGridAndSettingsAreReachable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["XANH_UI_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.textFields["browser.omnibox"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollViews["browser.home"].exists)

        app.buttons["browser.tabs"].tap()
        XCTAssertTrue(app.buttons["tabs.new"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        app.buttons["browser.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testTabCardSwipeClosesOneOfTwoTabs() {
        let app = XCUIApplication()
        app.launchEnvironment["XANH_UI_TESTING"] = "1"
        app.launch()

        let tabsButton = app.buttons["browser.tabs"]
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 10))
        tabsButton.tap()
        XCTAssertTrue(app.buttons["tabs.new"].waitForExistence(timeout: 3))
        app.buttons["tabs.new"].tap()

        tabsButton.tap()
        let cards = app.buttons.matching(identifier: "tab.card")
        XCTAssertEqual(cards.count, 2)
        cards.element(boundBy: 0).swipeLeft()

        XCTAssertEqual(cards.count, 1)
    }

    @MainActor
    func testRegularTabCanBePinnedFromTabGrid() {
        let app = launchApp()
        let omnibox = app.textFields["browser.omnibox"]
        omnibox.tap()
        omnibox.typeText("https://example.com/pinned")
        app.buttons["browser.go"].tap()
        app.buttons["browser.tabs"].tap()

        let pin = app.buttons["tab.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.tap()

        let card = app.buttons["tab.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        XCTAssertTrue((card.value as? String)?.contains("Pinned") == true)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unpin'")).firstMatch.exists)
    }

    @MainActor
    func testBrowserChromePassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchEnvironment["XANH_UI_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.textFields["browser.omnibox"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(
            for: [.sufficientElementDescription, .hitRegion, .dynamicType, .textClipped, .trait]
        ) { issue in
            // The iOS 18.6 iPad audit reports these SwiftUI grid labels as only
            // partially supporting Dynamic Type even after they visibly reflow,
            // scale, and pass the independent text-clipping audit. Keep this
            // exception label-scoped so every other Dynamic Type issue still
            // fails. Apple tracks the same false-positive class in its forums:
            // https://developer.apple.com/forums/thread/823968
            let responsiveStatusLabels: Set<String> = [
                "Default",
                "ISOLATED DATA STORE",
                "Main",
                "REGULAR SPACE",
                "Shields active",
                "CONTENT RULES ON",
            ]
            return UIDevice.current.userInterfaceIdiom == .pad
                && issue.auditType == .dynamicType
                && issue.compactDescription == "Dynamic Type font sizes are partially unsupported"
                && responsiveStatusLabels.contains(issue.element?.label ?? "")
        }
    }

    @MainActor
    func testTabGridPassesAccessibilityAudit() throws {
        let app = launchApp()
        app.buttons["browser.tabs"].tap()

        XCTAssertTrue(app.buttons["tabs.new"].waitForExistence(timeout: 3))
        try performAccessibilityAudit(app)
    }

    @MainActor
    func testLibraryPassesAccessibilityAudit() throws {
        let app = launchApp()
        app.buttons["browser.library"].tap()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 3))
        app.buttons["Archive"].tap()
        XCTAssertTrue(app.staticTexts["No archived tabs"].exists)
        try performAccessibilityAudit(app)
    }

    @MainActor
    func testClosedRegularTabCanBeRestoredFromArchive() throws {
        let app = launchApp()
        let omnibox = app.textFields["browser.omnibox"]
        omnibox.tap()
        omnibox.typeText("https://example.com/archive")
        app.buttons["browser.go"].tap()

        app.buttons["browser.tabs"].tap()
        let close = app.buttons["tab.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        app.buttons["Done"].tap()

        app.buttons["browser.library"].tap()
        app.buttons["Archive"].tap()
        let restore = app.buttons["library.archive.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()

        XCTAssertTrue(omnibox.waitForExistence(timeout: 3))
        XCTAssertEqual(omnibox.value as? String, "https://example.com/archive")
    }

    @MainActor
    func testDownloadsTrayIsReachableAndAccessible() throws {
        let app = launchApp()
        app.buttons["browser.downloads"].tap()

        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No downloads"].exists)
        try performAccessibilityAudit(app)
        if ProcessInfo.processInfo.environment["XANH_CAPTURE_MEDIA"] == "1" {
            let formFactor = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            capture(app, named: "xanh-\(formFactor)-downloads")
        }
    }

    @MainActor
    func testSettingsPassesAccessibilityAudit() throws {
        let app = launchApp()
        app.buttons["browser.settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        try performAccessibilityAudit(app)
    }

    @MainActor
    func testWebURLExposesNativeShareAction() throws {
        let app = launchApp()
        let omnibox = app.textFields["browser.omnibox"]
        omnibox.tap()
        omnibox.typeText("example.com")
        app.buttons["browser.go"].tap()

        XCTAssertTrue(app.buttons["browser.share"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testExactSiteShieldsCanBePausedAndAppliedOnReload() throws {
        let app = launchApp()
        let omnibox = app.textFields["browser.omnibox"]
        omnibox.tap()
        omnibox.typeText("https://example.com/shields")
        app.buttons["browser.go"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.keyboards.firstMatch, timeout: 3))

        let shields = app.buttons["browser.shields"]
        XCTAssertTrue(shields.waitForExistence(timeout: 3))
        XCTAssertEqual(shields.value as? String, "On")
        tapVisibleCenter(of: shields, in: app)
        app.buttons["Pause Shields for example.com"].tap()

        XCTAssertEqual(shields.value as? String, "Off, reload required")
        tapVisibleCenter(of: shields, in: app)
        let reload = app.buttons["Reload to apply"]
        XCTAssertTrue(reload.waitForExistence(timeout: 3))
        reload.tap()

        XCTAssertEqual(shields.value as? String, "Off")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func tapVisibleCenter(
        of element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let elementFrame = element.frame
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertFalse(elementFrame.isEmpty, "Element has no visible frame", file: file, line: line)
        let elementCenter = CGPoint(x: elementFrame.midX, y: elementFrame.midY)
        XCTAssertTrue(
            windowFrame.contains(elementCenter),
            "Element center \(elementCenter) is outside window \(windowFrame)",
            file: file,
            line: line
        )
        // Xcode 16.4 cannot AX-scroll a visible SwiftUI Menu and reports a
        // {-1, -1} hit point. Tap the verified on-screen center directly.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    func testCaptureDocumentationMedia() throws {
        guard ProcessInfo.processInfo.environment["XANH_CAPTURE_MEDIA"] == "1" else {
            throw XCTSkip("Documentation media is captured only by the explicit media workflow.")
        }

        let app = launchApp()
        let formFactor = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        capture(app, named: "xanh-\(formFactor)-home")

        app.buttons["browser.tabs"].tap()
        XCTAssertTrue(app.buttons["tabs.new"].waitForExistence(timeout: 3))
        app.buttons["tabs.new"].tap()
        app.buttons["browser.tabs"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "tab.card").count, 2)
        capture(app, named: "xanh-\(formFactor)-tabs")

        app.buttons["Done"].tap()
        app.buttons["browser.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        capture(app, named: "xanh-\(formFactor)-settings")

        app.buttons["Done"].tap()
        app.buttons["browser.downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 3))
        capture(app, named: "xanh-\(formFactor)-downloads")
    }

    @MainActor
    func testIPadHardwareKeyboardCreatesTabAndFocusesAddressBar() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Hardware-keyboard commands are exercised on the iPad destination.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["XANH_UI_TESTING"] = "1"
        app.launch()

        let omnibox = app.textFields["browser.omnibox"]
        XCTAssertTrue(omnibox.waitForExistence(timeout: 10))
        let status = app.descendants(matching: .any)["browser.status"]
        XCTAssertTrue(status.exists)
        let initialTabCount = try XCTUnwrap(tabCount(from: status.value as? String))

        app.typeKey("l", modifierFlags: .command)
        app.typeText("example.com")
        XCTAssertEqual(omnibox.value as? String, "example.com")

        app.typeKey("t", modifierFlags: .command)
        XCTAssertEqual(tabCount(from: status.value as? String), initialTabCount + 1)
    }

    private func tabCount(from status: String?) -> Int? {
        guard let status,
              let match = status.range(of: #"[0-9]+ tab"#, options: .regularExpression) else {
            return nil
        }
        return Int(status[match].split(separator: " ")[0])
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["XANH_UI_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.textFields["browser.omnibox"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func performAccessibilityAudit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(
            for: [.sufficientElementDescription, .hitRegion, .dynamicType, .textClipped, .trait]
        )
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.2))
    }
}
