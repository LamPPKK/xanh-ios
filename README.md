# Xanh iOS

[![CI](https://github.com/LamPPKK/xanh-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/LamPPKK/xanh-ios/actions/workflows/ci.yml)
[![iOS 18+](https://img.shields.io/badge/iOS%20%2F%20iPadOS-18%2B-67F58A)](https://developer.apple.com/ios/)
[![Version](https://img.shields.io/badge/version-0.1.0-4DD46B)](Release/TESTFLIGHT.md)

Xanh iOS is the native SwiftUI member of the Xanh Browser family for iPhone and iPad. It keeps WebKit's sandboxed process model, separates website data by profile, leaves private spaces out of restore, and ships without a telemetry SDK.

<img src="Brand/XanhBrowserLogo.png" width="104" alt="Xanh Browser arrow mark">

The centered four-arrow mark and a deep forest palette form the shared Xanh
identity. The iOS app uses native SwiftUI sheets and controls, a floating bottom
omnibox, adaptive iPad composition, Dynamic Type and 44-point-or-larger touch
targets. Product tokens and component rules are recorded in
[`design-system/xanh-ios/MASTER.md`](design-system/xanh-ios/MASTER.md)
and [`pages/browser-shell.md`](design-system/xanh-ios/pages/browser-shell.md).

Marketing version `0.1.0` · Bundle identifier `io.github.lamppkk.xanhbrowser.ios` · Default search Brave Search · External TestFlight candidate

The previous product screenshots were intentionally removed during the Xanh iOS
rebrand. New previews must be captured from a verified Xanh build; this README
does not relabel legacy captures as current evidence.

## What is implemented

### Profiles, spaces, and tabs

- Stable UUIDs for profiles, spaces, tabs, archived tabs, bookmarks, and history visits.
- A profile owns one persistent `WKWebsiteDataStore(forIdentifier:)`; multiple spaces may share that profile.
- A private space uses `WKWebsiteDataStore.nonPersistent()` and never persists tabs, history, or snapshots.
- Adaptive iPhone tab grid and iPad sidebar/grid, swipe-to-close, popup-to-tab handling, native home, bookmarks, and history.
- Arc-style pinned tabs sort ahead of regular tabs and are protected from automatic Archive. Pin state follows the tab through regular persistence and iCloud metadata sync; private pin state remains memory-only.
- Arc-inspired Archive: closing a regular web tab keeps bounded URL/title metadata for 30 days (up to 200 entries per profile), with one-tap restore from Library. Automatic Archive can be disabled or set to 1, 7, or 30 inactive days; active, pinned, Home, and private tabs are never moved automatically.
- Regular tab restoration after relaunch and LRU release of background WebViews under memory pressure.

### Browsing and resilience

- `XanhWebView` is the application embedding boundary and implements the Apple adapter contract from Xanh WebView `0.1.0-alpha.1`.
- The backend and fallback are both truthfully reported as Apple system `WKWebView`; Xanh iOS does not claim to bundle a custom iOS browser engine.
- Bottom omnibox with Brave Search by default and DuckDuckGo, Google, or Bing per profile.
- Back, Forward, Reload, Home, bookmarks managed from Library, native URL sharing, and focused-scene iPad keyboard commands.
- URL policy admits HTTP and HTTPS while Apple Transport Security remains enforced. `mailto:` and `tel:` require confirmation; script, data, file, and custom schemes are blocked.
- If WebKit terminates the active content process, Xanh retries once. A repeated failure stops the loop and offers explicit Reload or Open Home recovery for that exact tab. A terminated background session is discarded and recreated only when needed.

### Downloads

- Native `WKDownload` handling for HTTP(S) and page-scoped `blob:` download links, `Content-Disposition: attachment`, and MIME types WebKit cannot display.
- A Xanh transfer tray shows live system progress and supports pause, resume when the server supplies resume data, native sharing, and deletion.
- Regular files live in `Xanh Downloads`, remain visible after relaunch, and are exposed through the iOS Files integration. Filename normalization and collision suffixes keep destinations inside that directory.
- Private downloads use a cache-only directory, never enter browser persistence or CloudKit, and are removed when their private space closes or Xanh next launches.
- Media-link discovery and BitTorrent are desktop Blink workstreams; this WebKit beta does not claim either feature.

### Privacy and sync

- Private CloudKit metadata sync through `NSPersistentCloudKitContainer` with a local replica, last-writer-wins UUID conflict handling, and 30-day tombstones.
- Profiles, spaces, regular tabs, regular-tab Archive metadata, bookmarks, settings, and exact-host Shields exceptions may sync; cookies, cache, credentials, biometric state, snapshots, private tabs, and private-space exceptions never do.
- Profile deletion commits its synced metadata tombstone before destructive work. Each device then uses a local-only retry ledger to remove that profile's `WKWebsiteDataStore` and Keychain lock on launch/foreground, including after an offline device later receives the tombstone; cleanup progress, cookies, cache, and lock material never enter CloudKit.
- History sync is opt-in, disclosed before enabling, and limited to 90 days.
- Per-profile signed content-blocker policy with last-known-good rollback and a Shields control in the omnibox. Site exceptions match only the exact hostname, remain isolated by profile, and apply on the next navigation or explicit reload so Xanh never destroys a form or media session without the user's action.
- Optional profile lock through Keychain and LocalAuthentication, private-space foreground lock, and an app-switcher privacy cover.
- No proprietary telemetry SDK and no default analytics upload.

### Portable backup

- Settings can export and import a versioned, portable JSON document containing regular profiles, spaces, tabs, Archive entries, bookmarks, history, settings and exact-host Shields exceptions.
- The file is human-readable, unencrypted JSON and contains sensitive browsing data such as URLs, page titles and visit history. Keep exported files secure. “Portable” means a user-controlled Xanh iOS file; schema version 1 is not an Android backup or a general browser interchange format.
- Import validates product/schema identity, engine-contract version, size and collection limits, UUID relationships, storage modes, canonical hostnames and HTTP(S) URLs before any state changes.
- Unknown fields and fields associated with private, credential, cookie, cache or download data are rejected instead of being silently ignored.
- Private and ephemeral state, Keychain credentials, URL credentials, cookies, cache, downloads, website data and local deletion-cleanup ledgers are excluded. Removing a regular profile from metadata during import uses a non-destructive synced tombstone, so it does not schedule deletion of that profile's existing website data or Keychain lock. A failed persistence write rolls the in-memory import back.

### Accessibility

- 48-point minimum controls, Dynamic Type-aware layouts, VoiceOver labels and actions, and iPad hardware-keyboard navigation.
- Automated accessibility audits cover browser chrome, tab grid, library, and settings on iPhone and iPad Simulator lanes.

## Xanh reference audit

The latest GitHub state of [`xanh-android`](https://github.com/LamPPKK/xanh-android) and [`xanh-webkit`](https://github.com/LamPPKK/xanh-webkit) was reviewed as reference material, not copied as implementation instructions.

This pass adopted native URL sharing, explicit WebKit content-process recovery and a separately validated Xanh portable-backup format. It did not import Firefox Sync/password-vault code, the iOS 26 `WebPage` API, or Android System WebView/WPE adapters.

The exact source commits, decision ledger, and post-beta candidates are recorded in [the Xanh reference audit](docs/XANH_REFERENCE.md).
CI validates both engine lock files against those pinned repositories and the truthful Apple adapter contract.

## Build and test

Requirements:

- macOS with Xcode 16 or newer and an iOS 18+ Simulator runtime.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer.
- Python 3 for release and blocker tooling tests.

```sh
xcodegen generate

XANH_IPHONE_UDID="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 Tools/select_simulator.py --family iphone)"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
  -project XanhIOS.xcodeproj \
  -scheme XanhIOS \
  -destination "platform=iOS Simulator,id=$XANH_IPHONE_UDID" \
  CODE_SIGNING_ALLOWED=NO

python3 -m unittest discover -s Tools/tests
```

Debug and CI builds keep CloudKit and remote blocker downloads disabled so unsigned Simulator tests remain deterministic. Release builds enable both through generated Info.plist flags.

## Blocker releases

`Blocker/sources.json` pins EasyList and EasyPrivacy to exact upstream commits. `Tools/build_blocker.py` converts the supported network-rule subset and emits an unsupported-rule report. The protected `blocker-rules` workflow verifies the Ed25519 key pair, signs the canonical manifest, and publishes immutable source and artifact provenance.

Required protected secrets:

- `BLOCKER_SIGNING_KEY_BASE64`
- `BLOCKER_PUBLIC_KEY_BASE64`

EasyList, EasyPrivacy, and derived artifacts retain GPL-3.0-or-later attribution. See [Blocker/README.md](Blocker/README.md).

## External TestFlight gate

The protected `testflight` environment requires:

- `APPLE_TEAM_ID`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY`, and `BLOCKER_PUBLIC_KEY_BASE64`;
- `CLOUDKIT_SCHEMA_PROMOTED=true` only after the development schema is promoted to production;
- manual approval before archive and upload.

Release CI archives once, verifies the signature and production entitlements,
exports exactly one safe-named regular IPA, inspects it, records its SHA-256
checksum, validates it with App Store Connect, and uploads that same path only
after rechecking the checksum. A successful upload also emits a strict
[`release-evidence-v1.json`](Release/evidence-v1.schema.json) candidate that
binds the IPA digest and size to the exact commit, workflow run, attempt, build
number, validation result, and upload result. Candidate creation must rehash the
IPA after upload and match both the digest and size locked before upload. The v1
record always remains `candidate`; it never infers App Store processing or Beta
App Review. The JSON Schema is structural, while the executable validator and
[published invariant corpus](Release/evidence-v1.invariants.md) are normative
for cross-field identity. This is a consistency record, not a standalone
cryptographic attestation; trust it only with the referenced protected workflow
artifact and separate Apple-side processing/review evidence.

External Beta App Review, two-device iCloud isolation, physical-device accessibility, IPv6-only, memory-pressure, and stability checks remain release gates. Follow [Release/TESTFLIGHT.md](Release/TESTFLIGHT.md) and attach evidence to the exact uploaded IPA.

WebKit remains the portfolio's release priority until this gate passes. Blink
may continue protected-builder, provenance, policy, and other foundation work,
but its Linux product promotion does not replace this TestFlight gate. XanhTab
and `xanh-docker` follow their own hardware and OCI gates; their evidence
must not be presented as WebKit beta progress.

## Repository map

| Path | Responsibility |
| --- | --- |
| `App/` | SwiftUI shell, adaptive surfaces, commands, and app lifecycle |
| `Sources/Browser/` | `WKWebView` sessions, navigation, native downloads, blocker application, recovery, and coordination |
| `Sources/Domain/` | Stable browser models, URL policy, and session restoration |
| `Sources/Persistence/` | Core Data and private CloudKit metadata replica |
| `Sources/Security/` | Keychain and LocalAuthentication boundaries |
| `Blocker/` | Signed blocker manifest schema, provenance, and bundled rules |
| `Tests/`, `UITests/` | Unit, integration, accessibility, and documentation-media tests |
| `Tools/` | Blocker, release, entitlement, IPA, and Simulator verification tools |
| `docs/` | GitHub Pages and architecture notes; current screenshots are pending verified recapture |
