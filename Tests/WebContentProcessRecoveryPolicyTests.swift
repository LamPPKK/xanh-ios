import XCTest
@testable import XanhIOS

final class WebContentProcessRecoveryPolicyTests: XCTestCase {
    func testActivePageGetsOneAutomaticReloadUntilNavigationFinishes() {
        var policy = WebContentProcessRecoveryPolicy()

        XCTAssertEqual(policy.decision(isActive: true, hasRestorableURL: true), .reload)
        XCTAssertEqual(policy.decision(isActive: true, hasRestorableURL: true), .reportFailure)

        policy.navigationDidFinish()
        XCTAssertEqual(policy.decision(isActive: true, hasRestorableURL: true), .reload)
    }

    func testBackgroundPageIsDiscardedInsteadOfReloaded() {
        var policy = WebContentProcessRecoveryPolicy()

        XCTAssertEqual(policy.decision(isActive: false, hasRestorableURL: true), .discard)
    }

    func testMissingSafeURLFailsClosed() {
        var policy = WebContentProcessRecoveryPolicy()

        XCTAssertEqual(policy.decision(isActive: true, hasRestorableURL: false), .reportFailure)
    }

    func testManualReloadReopensAutomaticRecoveryBudget() {
        var policy = WebContentProcessRecoveryPolicy()
        XCTAssertEqual(policy.decision(isActive: true, hasRestorableURL: true), .reload)
        XCTAssertEqual(policy.decision(isActive: true, hasRestorableURL: true), .reportFailure)

        policy.userRequestedReload()
        XCTAssertEqual(policy.decision(isActive: true, hasRestorableURL: true), .reload)
    }
}
