import XCTest
@testable import XanhIOS

final class SessionRestorationTests: XCTestCase {
    func testPrivateTabsAreNeverRestored() throws {
        let spaceID = SpaceID()
        let regular = BrowserTab(
            id: TabID(),
            spaceID: spaceID,
            url: try XCTUnwrap(URL(string: "https://example.com")),
            title: "Example",
            sortIndex: 0,
            lastActiveAt: .now,
            storageMode: .persistent,
            modifiedAt: .now
        )
        let privateTab = BrowserTab(
            id: TabID(),
            spaceID: spaceID,
            url: try XCTUnwrap(URL(string: "https://private.example")),
            title: "Private",
            sortIndex: 1,
            lastActiveAt: .now,
            storageMode: .ephemeral,
            modifiedAt: .now
        )

        XCTAssertEqual(SessionRestoration().restorableTabs(from: [regular, privateTab]), [regular])
    }

    func testStableSortUsesUUIDWhenIndexesMatch() throws {
        let spaceID = SpaceID()
        let first = BrowserTab(
            id: TabID(rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))),
            spaceID: spaceID,
            url: nil,
            title: "First",
            sortIndex: 0,
            lastActiveAt: .now,
            storageMode: .persistent,
            modifiedAt: .now
        )
        let second = BrowserTab(
            id: TabID(rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))),
            spaceID: spaceID,
            url: nil,
            title: "Second",
            sortIndex: 0,
            lastActiveAt: .now,
            storageMode: .persistent,
            modifiedAt: .now
        )

        XCTAssertEqual(SessionRestoration().restorableTabs(from: [second, first]), [first, second])
    }

    func testPinnedTabsRestoreBeforeRegularTabs() throws {
        let spaceID = SpaceID()
        let regular = BrowserTab(
            id: TabID(),
            spaceID: spaceID,
            url: try XCTUnwrap(URL(string: "https://regular.example")),
            title: "Regular",
            sortIndex: 0,
            lastActiveAt: .now,
            storageMode: .persistent,
            modifiedAt: .now
        )
        let pinned = BrowserTab(
            id: TabID(),
            spaceID: spaceID,
            url: try XCTUnwrap(URL(string: "https://pinned.example")),
            title: "Pinned",
            sortIndex: 99,
            lastActiveAt: .now,
            pinnedAt: .now,
            storageMode: .persistent,
            modifiedAt: .now
        )

        XCTAssertEqual(SessionRestoration().restorableTabs(from: [regular, pinned]), [pinned, regular])
    }
}
