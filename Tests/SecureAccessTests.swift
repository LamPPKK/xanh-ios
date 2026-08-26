import Foundation
import Security
import XCTest
@testable import XanhIOS

@MainActor
final class SecureAccessTests: XCTestCase {
    func testOnlyConfirmedKeychainDeletionStatusesAreTerminal() {
        XCTAssertTrue(KeychainProfileLockStore.isTerminalDeletionStatus(errSecSuccess))
        XCTAssertTrue(KeychainProfileLockStore.isTerminalDeletionStatus(errSecItemNotFound))
        XCTAssertFalse(KeychainProfileLockStore.isTerminalDeletionStatus(errSecInteractionNotAllowed))
        XCTAssertFalse(KeychainProfileLockStore.isTerminalDeletionStatus(errSecAuthFailed))
    }

    func testAuthenticationCancellationIsPropagated() async {
        let authenticator = FakeOwnerAuthenticator(result: .failure(CancellationError()))
        do {
            try await authenticator.authenticate(reason: "Unlock private profile")
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

struct FakeOwnerAuthenticator: OwnerAuthenticating {
    let result: Result<Void, any Error>

    func authenticate(reason: String) async throws {
        _ = reason
        try result.get()
    }
}
