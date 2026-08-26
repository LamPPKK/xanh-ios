import CryptoKit
import Foundation
import WebKit

@MainActor
protocol ContentRuleCompiling {
    func compile(identifier: String, encodedRules: String) async throws -> WKContentRuleList
    func lookup(identifier: String) async throws -> WKContentRuleList?
}

@MainActor
struct ContentRuleService: ContentRuleCompiling {
    private let store: WKContentRuleListStore

    init(store: WKContentRuleListStore = .default()) {
        self.store = store
    }

    func compile(identifier: String, encodedRules: String) async throws -> WKContentRuleList {
        guard encodedRules.utf8.count <= 8 * 1024 * 1024 else {
            throw ContentRuleError.rulesTooLarge
        }
        let compiled = try await store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: encodedRules
        )
        guard let compiled else { throw ContentRuleError.compilationReturnedNoRule }
        return compiled
    }

    func lookup(identifier: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { rule, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: rule)
                }
            }
        }
    }
}

struct BlockerArtifact: Codable, Equatable, Sendable {
    let identifier: String
    let url: URL
    let sha256: String
}

struct BlockerManifestPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let version: String
    let sourceCommits: [String: String]
    let artifacts: [BlockerArtifact]
    let minimumAppVersion: String
    let createdAt: Date

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct BlockerManifest: Codable, Equatable, Sendable {
    let payload: BlockerManifestPayload
    let signature: String
}

struct BlockerVerifier: Sendable {
    let publicKey: Curve25519.Signing.PublicKey

    init(rawPublicKey: Data) throws {
        publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
    }

    func verifyManifest(_ manifest: BlockerManifest, appVersion: String) throws {
        guard manifest.payload.schemaVersion == 1 else { throw ContentRuleError.unsupportedManifest }
        guard !manifest.payload.artifacts.isEmpty,
              manifest.payload.artifacts.count <= 64,
              Set(manifest.payload.artifacts.map(\.identifier)).count == manifest.payload.artifacts.count,
              Set(manifest.payload.artifacts.map(\.url)).count == manifest.payload.artifacts.count,
              manifest.payload.artifacts.allSatisfy({
                  !$0.identifier.isEmpty && $0.identifier.count <= 64
                      && $0.identifier.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").inverted) == nil
              }) else {
            throw ContentRuleError.invalidArtifactList
        }
        guard manifest.payload.artifacts.allSatisfy({ $0.url.scheme == "https" }) else {
            throw ContentRuleError.insecureArtifactURL
        }
        guard Self.isNumericVersion(manifest.payload.version, minimumComponents: 2),
              manifest.payload.version.count <= 64,
              Self.isNumericVersion(manifest.payload.minimumAppVersion, exactComponents: 3),
              manifest.payload.sourceCommits.values.allSatisfy({
                  $0.count == 40 && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdef").inverted) == nil
              }) else {
            throw ContentRuleError.invalidManifestMetadata
        }
        guard appVersion.compare(
            manifest.payload.minimumAppVersion,
            options: .numeric
        ) != .orderedAscending else {
            throw ContentRuleError.minimumVersionNotMet
        }
        guard let signature = Data(base64Encoded: manifest.signature),
              publicKey.isValidSignature(signature, for: try manifest.payload.canonicalData()) else {
            throw ContentRuleError.signatureInvalid
        }
    }

    private static func isNumericVersion(
        _ version: String,
        minimumComponents: Int? = nil,
        exactComponents: Int? = nil
    ) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        if let minimumComponents, components.count < minimumComponents { return false }
        if let exactComponents, components.count != exactComponents { return false }
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { 48 ... 57 ~= $0 }
        }
    }

    func verifyArtifacts(_ manifest: BlockerManifest, artifacts: [URL: Data]) throws {
        for descriptor in manifest.payload.artifacts {
            guard descriptor.sha256.count == 64,
                  let artifact = artifacts[descriptor.url],
                  descriptor.sha256 == SHA256.hash(data: artifact).hexString else {
                throw ContentRuleError.checksumMismatch
            }
        }
    }

    func verify(_ manifest: BlockerManifest, artifacts: [URL: Data], appVersion: String) throws {
        try verifyManifest(manifest, appVersion: appVersion)
        try verifyArtifacts(manifest, artifacts: artifacts)
    }
}

protocol BlockerHTTPClient: Sendable {
    func data(from url: URL, maximumBytes: Int) async throws -> Data
}

struct URLSessionBlockerHTTPClient: BlockerHTTPClient {
    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https" else {
            throw ContentRuleError.downloadFailed
        }
        if response.expectedContentLength > maximumBytes {
            throw ContentRuleError.downloadTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw ContentRuleError.downloadTooLarge }
            data.append(byte)
        }
        return data
    }
}

enum BlockerUpdateResult: Equatable, Sendable {
    case notDue
    case unchanged
    case installed(version: String)
}

@MainActor
final class BlockerUpdateService {
    private static let maximumArtifactBytes = 8 * 1024 * 1024
    private static let maximumTotalArtifactBytes = 32 * 1024 * 1024
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "blocker.lastCheck"
    private static let activeIdentifiersKey = "blocker.activeIdentifiers"
    private static let activeVersionKey = "blocker.activeVersion"

    private let compiler: any ContentRuleCompiling
    private let httpClient: any BlockerHTTPClient
    private let verifier: BlockerVerifier
    private let defaults: UserDefaults
    private let appVersion: String

    init(
        compiler: any ContentRuleCompiling,
        httpClient: any BlockerHTTPClient,
        verifier: BlockerVerifier,
        defaults: UserDefaults = .standard,
        appVersion: String
    ) {
        self.compiler = compiler
        self.httpClient = httpClient
        self.verifier = verifier
        self.defaults = defaults
        self.appVersion = appVersion
    }

    func installedRules() async throws -> [WKContentRuleList] {
        guard let identifiers = defaults.stringArray(forKey: Self.activeIdentifiersKey) else { return [] }
        var rules: [WKContentRuleList] = []
        for identifier in identifiers {
            guard let rule = try await compiler.lookup(identifier: identifier) else { return [] }
            rules.append(rule)
        }
        return rules
    }

    func update(from manifestURL: URL, force: Bool = false, now: Date = .now) async throws -> BlockerUpdateResult {
        guard manifestURL.scheme == "https" else { throw ContentRuleError.insecureArtifactURL }
        if !force,
           let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now.timeIntervalSince(lastCheck) < Self.checkInterval {
            return .notDue
        }

        let manifestData = try await httpClient.data(from: manifestURL, maximumBytes: 64 * 1024)
        guard manifestData.count <= 64 * 1024 else { throw ContentRuleError.manifestTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BlockerManifest.self, from: manifestData)
        try verifier.verifyManifest(manifest, appVersion: appVersion)

        if let activeVersion = defaults.string(forKey: Self.activeVersionKey) {
            let ordering = manifest.payload.version.compare(activeVersion, options: .numeric)
            guard ordering != .orderedAscending else {
                throw ContentRuleError.rollbackRejected
            }
            if ordering == .orderedSame {
                defaults.set(now, forKey: Self.lastCheckKey)
                return .unchanged
            }
        }

        var downloaded: [URL: Data] = [:]
        var totalArtifactBytes = 0
        for descriptor in manifest.payload.artifacts {
            let artifact = try await httpClient.data(from: descriptor.url, maximumBytes: Self.maximumArtifactBytes)
            guard artifact.count <= Self.maximumArtifactBytes else { throw ContentRuleError.rulesTooLarge }
            totalArtifactBytes += artifact.count
            guard totalArtifactBytes <= Self.maximumTotalArtifactBytes else { throw ContentRuleError.downloadTooLarge }
            downloaded[descriptor.url] = artifact
        }
        try verifier.verifyArtifacts(manifest, artifacts: downloaded)

        var candidateIdentifiers: [String] = []
        for descriptor in manifest.payload.artifacts {
            guard let artifact = downloaded[descriptor.url],
                  let encodedRules = String(data: artifact, encoding: .utf8) else {
                throw ContentRuleError.invalidEncoding
            }
            let candidateIdentifier = "xanh-\(manifest.payload.version)-\(descriptor.identifier)"
            _ = try await compiler.compile(identifier: candidateIdentifier, encodedRules: encodedRules)
            candidateIdentifiers.append(candidateIdentifier)
        }
        defaults.set(candidateIdentifiers, forKey: Self.activeIdentifiersKey)
        defaults.set(manifest.payload.version, forKey: Self.activeVersionKey)
        defaults.set(now, forKey: Self.lastCheckKey)
        return .installed(version: manifest.payload.version)
    }
}

enum ContentRuleError: LocalizedError, Equatable {
    case rulesTooLarge
    case manifestTooLarge
    case checksumMismatch
    case signatureInvalid
    case unsupportedManifest
    case insecureArtifactURL
    case minimumVersionNotMet
    case invalidEncoding
    case downloadFailed
    case compilationReturnedNoRule
    case invalidArtifactList
    case invalidManifestMetadata
    case downloadTooLarge
    case rollbackRejected

    var errorDescription: String? {
        switch self {
        case .rulesTooLarge: "The blocker rules artifact is too large."
        case .manifestTooLarge: "The blocker manifest is too large."
        case .checksumMismatch: "The blocker rules checksum does not match."
        case .signatureInvalid: "The blocker manifest signature is invalid."
        case .unsupportedManifest: "The blocker manifest version is not supported."
        case .insecureArtifactURL: "Blocker updates must use HTTPS."
        case .minimumVersionNotMet: "This blocker update requires a newer Xanh build."
        case .invalidEncoding: "The blocker rules are not valid UTF-8."
        case .downloadFailed: "The blocker update could not be downloaded."
        case .compilationReturnedNoRule: "WebKit did not compile the blocker rules."
        case .invalidArtifactList: "The blocker manifest artifact list is empty or contains duplicate identifiers."
        case .invalidManifestMetadata: "The blocker manifest metadata is malformed."
        case .downloadTooLarge: "The blocker download exceeded its size limit."
        case .rollbackRejected: "The blocker update is older than the installed rules."
        }
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
