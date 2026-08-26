import Foundation
import XCTest
@testable import XanhIOS

final class BlockerExternalManifestTests: XCTestCase {
    func testExternallySignedManifestMatchesAppCanonicalization() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["XANH_BLOCKER_MANIFEST"],
              !manifestPath.isEmpty,
              let artifactDirectory = environment["XANH_BLOCKER_ARTIFACT_DIRECTORY"],
              !artifactDirectory.isEmpty,
              let encodedKey = environment["XANH_BLOCKER_PUBLIC_KEY_BASE64"],
              !encodedKey.isEmpty else {
            throw XCTSkip("Cross-tool signature verification runs only in the protected blocker release workflow.")
        }
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BlockerManifest.self, from: manifestData)
        let artifacts = try Dictionary(
            uniqueKeysWithValues: manifest.payload.artifacts.map { descriptor in
                let fileURL = URL(fileURLWithPath: artifactDirectory, isDirectory: true)
                    .appendingPathComponent(descriptor.url.lastPathComponent)
                return (descriptor.url, try Data(contentsOf: fileURL))
            }
        )
        let key = try XCTUnwrap(Data(base64Encoded: encodedKey))
        let verifier = try BlockerVerifier(rawPublicKey: key)

        XCTAssertNoThrow(try verifier.verify(manifest, artifacts: artifacts, appVersion: "0.1.0"))
    }
}
