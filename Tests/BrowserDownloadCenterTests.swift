import Foundation
@preconcurrency import Network
import XCTest
@testable import XanhIOS

@MainActor
final class BrowserDownloadCenterTests: XCTestCase {
    func testResponsePolicyDownloadsAttachmentsAndUnsupportedMIME() {
        XCTAssertTrue(BrowserDownloadResponsePolicy.allowsDownloadURL(URL(string: "blob:https://example.com/id")))
        XCTAssertTrue(BrowserDownloadResponsePolicy.allowsDownloadURL(URL(string: "https://example.com/file")))
        XCTAssertFalse(BrowserDownloadResponsePolicy.allowsDownloadURL(URL(string: "data:text/plain,secret")))
        XCTAssertFalse(BrowserDownloadResponsePolicy.allowsDownloadURL(URL(fileURLWithPath: "/tmp/secret")))
        XCTAssertTrue(
            BrowserDownloadResponsePolicy.shouldDownload(
                canShowMIMEType: true,
                contentDisposition: "attachment; filename=report.pdf"
            )
        )
        XCTAssertTrue(
            BrowserDownloadResponsePolicy.shouldDownload(
                canShowMIMEType: false,
                contentDisposition: nil
            )
        )
        XCTAssertFalse(
            BrowserDownloadResponsePolicy.shouldDownload(
                canShowMIMEType: true,
                contentDisposition: "inline"
            )
        )
    }

    func testFilenameCannotEscapeDownloadDirectoryAndCollisionGetsSuffix() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let center = fixture.center
        let first = try center.prepare(request(filename: "../../report.pdf"))

        XCTAssertEqual(first.destinationURL.deletingLastPathComponent(), fixture.persistentRoot)
        XCTAssertEqual(first.destinationURL.lastPathComponent, "report.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: first.destinationURL.path, contents: Data("one".utf8)))

        let second = try center.prepare(request(filename: "report.pdf"))
        XCTAssertEqual(second.destinationURL.lastPathComponent, "report (1).pdf")
        XCTAssertEqual(second.destinationURL.deletingLastPathComponent(), fixture.persistentRoot)
    }

    func testFilenameIsCappedByUTF8BytesAndKeepsShortExtension() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let longName = String(repeating: "🔥", count: 200) + ".txt"

        let plan = try fixture.center.prepare(request(filename: longName))

        XCTAssertLessThanOrEqual(plan.destinationURL.lastPathComponent.utf8.count, 180)
        XCTAssertTrue(plan.destinationURL.lastPathComponent.hasSuffix(".txt"))
    }

    func testCompletedFilesAreRestoredOnNextLaunch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let center = fixture.center
        let plan = try center.prepare(request(filename: "archive.zip"))
        XCTAssertTrue(FileManager.default.createFile(atPath: plan.destinationURL.path, contents: Data("payload".utf8)))
        center.markFinished(plan.id)

        let relaunched = BrowserDownloadCenter(
            persistentRoot: fixture.persistentRoot,
            privateRoot: fixture.privateRoot
        )

        XCTAssertEqual(relaunched.items.count, 1)
        XCTAssertEqual(relaunched.items.first?.filename, "archive.zip")
        XCTAssertEqual(relaunched.items.first?.state, .completed)
    }

    func testPrivateDownloadsUseTemporaryRootAndAreRemovedWithProfile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let center = fixture.center
        let profileID = ProfileID()
        let plan = try center.prepare(request(filename: "private.pdf", profileID: profileID, isPrivate: true))
        XCTAssertEqual(plan.destinationURL.deletingLastPathComponent(), fixture.privateRoot)
        XCTAssertTrue(FileManager.default.createFile(atPath: plan.destinationURL.path, contents: Data("private".utf8)))

        center.removePrivateDownloads(for: profileID)

        XCTAssertTrue(center.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destinationURL.path))
    }

    func testPrivateFilesArePurgedWhenDownloadCenterStarts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let residue = fixture.privateRoot.appending(path: "residue.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: residue.path, contents: Data("secret".utf8)))

        _ = BrowserDownloadCenter(
            persistentRoot: fixture.persistentRoot,
            privateRoot: fixture.privateRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: residue.path))
    }

    func testFailureWithResumeDataBecomesPausableTransfer() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let center = fixture.center
        let plan = try center.prepare(request(filename: "large.iso"))
        let resumeData = Data([1, 2, 3])

        center.markFailed(
            plan.id,
            error: URLError(.networkConnectionLost),
            resumeData: resumeData
        )

        let context = try center.resumeContext(for: plan.id)
        XCTAssertEqual(context.item.state, .paused)
        XCTAssertEqual(context.data, resumeData)
    }

    func testRemovedResumeDoesNotCreateAReplacementDownload() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let missingID = DownloadID()

        XCTAssertThrowsError(
            try fixture.center.prepare(
                request(filename: "should-not-return.zip"),
                resuming: missingID
            )
        ) { error in
            XCTAssertEqual(error as? BrowserDownloadError, .itemUnavailable)
        }
        XCTAssertTrue(fixture.center.items.isEmpty)
    }

    func testResumeCannotCrossProfileBoundary() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let originalProfile = ProfileID()
        let plan = try fixture.center.prepare(
            request(filename: "profile-a.zip", profileID: originalProfile)
        )

        XCTAssertThrowsError(
            try fixture.center.prepare(
                request(filename: "profile-b.zip", profileID: ProfileID()),
                resuming: plan.id
            )
        ) { error in
            XCTAssertEqual(error as? BrowserDownloadError, .itemUnavailable)
        }
        XCTAssertEqual(fixture.center.items.count, 1)
        XCTAssertEqual(fixture.center.items.first?.profileID, originalProfile)
    }

    func testWKWebViewDownloadsHTTPAttachmentEndToEnd() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let expected = Data("Xanh download integration".utf8)
        let server = try LocalHTTPDownloadServer(
            body: expected,
            filename: "xanh-fixture.txt"
        )
        defer { server.stop() }
        let port = try await server.start()
        let profile = BrowserProfile.regularDefault()
        let tabID = TabID()
        let session = BrowserSession(
            tabID: tabID,
            profile: profile,
            dataStore: .nonPersistent()
        )
        let downloadStarted = expectation(description: "WKWebView converted the response to a download")
        session.onDownloadStarted = { download, existingID in
            fixture.center.accept(
                download,
                tabID: tabID,
                profileID: profile.id,
                isPrivate: false,
                resuming: existingID
            )
            downloadStarted.fulfill()
        }

        session.load(try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/download")))

        await fulfillment(of: [downloadStarted], timeout: 15)
        for _ in 0 ..< 300 where fixture.center.items.first?.state != .completed {
            try await Task.sleep(for: .milliseconds(50))
        }
        let item = try XCTUnwrap(fixture.center.items.first)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.filename, "xanh-fixture.txt")
        XCTAssertEqual(try Data(contentsOf: item.destinationURL), expected)
        withExtendedLifetime(session) {}
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "XanhDownloadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let persistentRoot = root.appending(path: "Downloads", directoryHint: .isDirectory)
        let privateRoot = root.appending(path: "Private", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            persistentRoot: persistentRoot,
            privateRoot: privateRoot,
            center: BrowserDownloadCenter(
                persistentRoot: persistentRoot,
                privateRoot: privateRoot
            )
        )
    }

    private func request(
        filename: String,
        profileID: ProfileID = ProfileID(),
        isPrivate: Bool = false
    ) -> BrowserDownloadRequest {
        BrowserDownloadRequest(
            sourceURL: URL(string: "https://downloads.example/\(filename)"),
            suggestedFilename: filename,
            tabID: TabID(),
            profileID: profileID,
            isPrivate: isPrivate
        )
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let persistentRoot: URL
    let privateRoot: URL
    let center: BrowserDownloadCenter

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class LocalHTTPDownloadServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.github.lamppkk.xanhbrowser.ios.tests.download-server")
    private let response: Data
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, any Error>?

    init(body: Data, filename: String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        var payload = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(filename)\"\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        payload.append(body)
        response = payload

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] _, _, _, error in
                guard let self else { return }
                if error != nil {
                    connection.cancel()
                    return
                }
                connection.send(content: self.response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else {
                        self.finishStart(.failure(BrowserDownloadError.storageUnavailable))
                        return
                    }
                    self.finishStart(.success(port.rawValue))
                case let .failed(error):
                    self.finishStart(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func finishStart(_ result: Result<UInt16, any Error>) {
        let pending = lock.withLock {
            let value = continuation
            continuation = nil
            return value
        }
        pending?.resume(with: result)
    }
}
