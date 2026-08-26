import WebKit
import XCTest
@testable import XanhIOS

@MainActor
final class BlockerArtifactCompilationTests: XCTestCase {
    func testGeneratedArtifactsCompile() async throws {
        guard let directory = ProcessInfo.processInfo.environment["XANH_RULE_ARTIFACT_DIRECTORY"],
              !directory.isEmpty else {
            throw XCTSkip("Generated blocker artifacts are compiled only in the protected blocker release workflow.")
        }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let artifacts = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("content-rules-") && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(artifacts.isEmpty)

        let compiler = ContentRuleService()
        for artifact in artifacts {
            let encoded = try String(contentsOf: artifact, encoding: .utf8)
            _ = try await compiler.compile(
                identifier: "release-test-\(artifact.deletingPathExtension().lastPathComponent)",
                encodedRules: encoded
            )
        }
    }
}
