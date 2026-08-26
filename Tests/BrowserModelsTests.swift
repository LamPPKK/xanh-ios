import XCTest
@testable import XanhIOS

final class BrowserModelsTests: XCTestCase {
    func testDefaultProfileUsesStableUUIDAndBraveSearch() {
        let first = BrowserProfile.regularDefault()
        let second = BrowserProfile.regularDefault()

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.searchProvider, .brave)
        XCTAssertEqual(first.storageMode, .persistent)
    }

    func testSpacesAndProfilesRemainSeparateConcepts() {
        let profile = BrowserProfile.regularDefault()
        let first = BrowserSpace(
            id: SpaceID(),
            profileID: profile.id,
            name: "Work",
            sortIndex: 0,
            selectedTabID: nil,
            storageMode: .persistent,
            modifiedAt: .now
        )
        let second = BrowserSpace(
            id: SpaceID(),
            profileID: profile.id,
            name: "Research",
            sortIndex: 1,
            selectedTabID: nil,
            storageMode: .persistent,
            modifiedAt: .now
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.profileID, second.profileID)
    }

    func testLegacyTabAndSettingsPayloadsDecodeWithoutPinOrAutomaticArchiveFields() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let tab = BrowserTab(
            id: TabID(),
            spaceID: SpaceID(),
            url: try XCTUnwrap(URL(string: "https://legacy.example")),
            title: "Legacy",
            sortIndex: 0,
            lastActiveAt: .now,
            pinnedAt: .now,
            storageMode: .persistent,
            modifiedAt: .now
        )
        var tabObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(tab)) as? [String: Any]
        )
        tabObject.removeValue(forKey: "pinnedAt")

        let decodedTab = try decoder.decode(
            BrowserTab.self,
            from: JSONSerialization.data(withJSONObject: tabObject)
        )

        XCTAssertNil(decodedTab.pinnedAt)
        XCTAssertFalse(decodedTab.isPinned)

        var settingsObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(BrowserSettings())) as? [String: Any]
        )
        settingsObject.removeValue(forKey: "automaticArchiveInterval")

        let decodedSettings = try decoder.decode(
            BrowserSettings.self,
            from: JSONSerialization.data(withJSONObject: settingsObject)
        )

        XCTAssertNil(decodedSettings.automaticArchiveInterval)
    }

    func testBlockerSitePolicyNormalizesAndMatchesOnlyTheExactHost() throws {
        XCTAssertEqual(BlockerSitePolicy.normalizedHost(" Example.COM. "), "example.com")
        XCTAssertEqual(
            BlockerSitePolicy.normalizedHost(for: URL(string: "https://[::1]/status")),
            "::1"
        )
        XCTAssertNil(BlockerSitePolicy.normalizedHost("example.com/path"))
        XCTAssertNil(BlockerSitePolicy.normalizedHost(for: URL(string: "file:///tmp/index.html")))

        let allowlist: Set<String> = ["example.com"]
        XCTAssertFalse(
            BlockerSitePolicy.rulesEnabled(
                profileEnabled: true,
                for: try XCTUnwrap(URL(string: "https://example.com/article")),
                allowlistedHosts: allowlist
            )
        )
        XCTAssertTrue(
            BlockerSitePolicy.rulesEnabled(
                profileEnabled: true,
                for: try XCTUnwrap(URL(string: "https://news.example.com/article")),
                allowlistedHosts: allowlist
            )
        )
    }

    func testLegacySnapshotDecodesWithoutNewLocalCollections() throws {
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(BrowserSnapshot.initial())) as? [String: Any]
        )
        object.removeValue(forKey: "blockerSiteExceptions")
        object.removeValue(forKey: "profileDeletionCleanups")

        let decoded = try JSONDecoder().decode(
            BrowserSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.blockerSiteExceptions.isEmpty)
        XCTAssertTrue(decoded.profileDeletionCleanups.isEmpty)
    }
}
