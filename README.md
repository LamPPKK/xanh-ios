<p align="center">
  <img src="Brand/XanhBrowserLogo.png" width="112" alt="Xanh Browser four-arrow mark">
</p>

<h1 align="center">Xanh iOS</h1>

<p align="center">
  A private, native browser for iPhone and iPad, built with SwiftUI and Apple WebKit.
</p>

<p align="center">
  <a href="https://github.com/LamPPKK/xanh-ios/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/LamPPKK/xanh-ios/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://developer.apple.com/ios/"><img alt="iOS and iPadOS 18 or newer" src="https://img.shields.io/badge/iOS%20%2F%20iPadOS-18%2B-67F58A"></a>
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-F05138">
  <a href="Release/TESTFLIGHT.md"><img alt="Version 0.1.0" src="https://img.shields.io/badge/version-0.1.0-4DD46B"></a>
</p>

Xanh iOS is the Apple-platform member of the Xanh Browser family. It combines
native SwiftUI controls with isolated browsing profiles, ephemeral private
spaces, content blocking, downloads, portable metadata backup, and optional
CloudKit metadata sync. The app contains no proprietary telemetry SDK.

> **Pre-release status:** the current `main` branch passes its hosted iPhone,
> iPad, accessibility, configuration, and tooling CI lanes. App Store signing,
> production CloudKit behavior, physical-device testing, and external TestFlight
> review remain separate release gates.

Marketing version `0.1.0` · Bundle identifier
`io.github.lamppkk.xanhbrowser.ios` · Deployment target iOS/iPadOS 18+

## Preview

The former Fireball screenshots were removed during the Xanh rebrand. Verified
Xanh iPhone and iPad captures have not yet been published, and legacy images
will not be relabelled as current product evidence.

The visual system uses the centered four-arrow mark, a forest-green palette,
native sheets and controls, a floating bottom address bar, and an adaptive iPad
layout. See the [design system](design-system/xanh-ios/MASTER.md) and
[browser-shell specification](design-system/xanh-ios/pages/browser-shell.md).

## Highlights

### Profiles, spaces, and tabs

- Separate persistent `WKWebsiteDataStore` instances for regular profiles.
- Non-persistent private spaces that do not enter restore, CloudKit, backup, or
  browser history.
- Regular and pinned tabs, iPhone tab grid, adaptive iPad sidebar/grid, popup
  handling, bookmarks, history, and relaunch restoration.
- A bounded Archive for closed regular tabs: up to 200 entries per profile,
  retained for 30 days, with optional automatic archiving after 1, 7, or 30
  inactive days. Active, pinned, Home, and private tabs are excluded from
  automatic archiving; manually closing a regular pinned tab can archive it
  while preserving its pinned state.
- Release of background WebViews when the app receives a memory warning.

### Browsing and recovery

- Brave Search by default, with DuckDuckGo, Google, and Bing available per
  profile.
- Back, Forward, Reload, Home, native URL sharing, and focused-scene iPad
  keyboard commands.
- HTTP and HTTPS navigation under Apple Transport Security. `mailto:` and
  `tel:` require confirmation; script, data, file, and custom schemes are
  rejected.
- Bounded WebKit process recovery: one automatic retry for the active page,
  followed by explicit Reload or Open Home actions if failure repeats.

### Downloads

- Native `WKDownload` support for HTTP(S), page-scoped `blob:` links,
  attachment responses, and non-displayable MIME types.
- Live progress, pause, resume when WebKit provides resume data, sharing, and
  deletion from the transfer tray.
- Regular files are kept in `Xanh Downloads` and exposed through Files.
  Private downloads use cache-only storage and are removed when the private
  space closes or the app next launches.

### Privacy and content blocking

- Optional profile protection with Keychain and LocalAuthentication, a private
  foreground lock, and an app-switcher privacy cover.
- Signed content-rule manifests derived from pinned EasyList and EasyPrivacy
  revisions, independently compiled before activation, with last-known-good
  rollback.
- Per-profile Shields controls and exact-host exceptions. Policy changes apply
  on navigation or an explicit reload, avoiding silent destruction of active
  forms or media sessions.
- No default analytics upload, password-vault bridge, or Firefox Sync
  implementation.

## Engine boundary

`XanhWebView` is the app-facing embedding boundary. Its backend and fallback are
both Apple system `WKWebView`; this repository does **not** bundle or claim a
custom iOS browser engine.

The compatibility contract is pinned in [`XANH_WEBVIEW.lock`](XANH_WEBVIEW.lock),
while [`XANH_WEBKIT.lock`](XANH_WEBKIT.lock) records the Xanh product reference
used for behavior alignment. CI verifies both locks and the Apple adapter
contract. The detailed decisions and exclusions live in the
[Xanh compatibility reference](docs/XANH_REFERENCE.md).

## CloudKit boundary

Release builds can sync regular browser metadata through a private
`NSPersistentCloudKitContainer` replica. The sync surface includes profiles,
spaces, regular tabs, pinned state, Archive metadata, bookmarks, settings, and
exact-host Shields exceptions. History sync is opt-in and limited to 90 days.

Cookies, cache, credentials, Keychain material, biometric state, snapshots,
downloads, private tabs, private exceptions, and local website-data cleanup
state never enter CloudKit. Debug and CI builds keep CloudKit disabled so
unsigned Simulator runs remain deterministic.

## Portable backup

Settings can export and import a versioned Xanh iOS JSON document containing
regular profiles, spaces, tabs, Archive entries, bookmarks, history, settings,
and exact-host Shields exceptions. Imports validate product and schema identity,
size and collection limits, URLs, hosts, storage modes, and UUID relationships
before changing browser state.

> **Sensitive-data warning:** a `.xanhbackup` file is human-readable,
> **unencrypted JSON** and can contain URLs, page titles, and visit history.
> Store and share it accordingly. Schema version 1 is a user-controlled Xanh
> iOS backup; it is not an Android backup, Firefox Sync payload, encrypted vault,
> or general browser interchange format.

Private state, credentials, cookies, cache, downloads, website data, and local
deletion-cleanup ledgers are excluded. Unknown or prohibited fields are rejected
rather than silently accepted.

## Build and test

Requirements:

- macOS with Xcode 16 or newer and an iOS 18+ Simulator runtime
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer
- Python 3 for verification and release tooling

Generate the project and run the same combined unit/UI scheme used by CI:

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
```

Run the portable tooling and contract checks separately:

```sh
python3 -m unittest discover -s Tools/tests
python3 Tools/verify_engine_locks.py
python3 Tools/release_evidence.py validate-corpus \
  --input Release/evidence-v1.corpus.json
```

The [CI workflow](.github/workflows/ci.yml) also builds the adaptive iPad target
and runs its accessibility and hardware-keyboard UI checks.

## Accessibility

Xanh iOS uses Dynamic Type-aware layouts, VoiceOver labels and actions,
44-point-or-larger touch targets, and iPad hardware-keyboard navigation.
Automated audits cover browser chrome, tab grid, Library, and Settings on
iPhone and iPad Simulator lanes. Physical-device VoiceOver, Dynamic Type, and
keyboard checks remain part of the release gate.

## Blocker and TestFlight releases

[`Blocker/sources.json`](Blocker/sources.json) pins EasyList and EasyPrivacy.
The converter supports a reviewed subset of Adblock Plus syntax and reports
unsupported rules instead of approximating them. Protected automation signs the
canonical manifest and publishes source, checksum, signature, and unsupported-
rule provenance. See [Blocker/README.md](Blocker/README.md).

The protected TestFlight workflow verifies distribution signing, production
entitlements, IPA identity, checksum, validation, upload, and candidate evidence
for one exact artifact. A successful workflow upload does not itself prove App
Store processing or Beta App Review. Before presenting a public beta, follow the
full [external TestFlight gate](Release/TESTFLIGHT.md), including two-device
iCloud isolation and physical iPhone/iPad verification.

## Repository map

| Path | Responsibility |
| --- | --- |
| `App/` | SwiftUI app lifecycle, browser shell, adaptive views, and commands |
| `Sources/Browser/` | WebKit sessions, downloads, blocker application, recovery, and coordination |
| `Sources/Domain/` | Browser models, URL policy, and session restoration |
| `Sources/Persistence/` | Core Data, CloudKit metadata replica, and portable backup |
| `Sources/Security/` | Keychain and LocalAuthentication boundaries |
| `Blocker/` | Blocker source pins, manifest schema, and bundled rules |
| `Tests/`, `UITests/` | Unit, integration, accessibility, and keyboard tests |
| `Tools/` | Contract, blocker, Simulator, entitlement, IPA, and release verification |
| `docs/` | Compatibility notes, support, privacy, and GitHub Pages content |

## Xanh Browser family

| Repository | Role |
| --- | --- |
| [xanh-webkit](https://github.com/LamPPKK/xanh-webkit) | Multi-platform reference hosts, shared engine policies, and release gates |
| [xanh-android](https://github.com/LamPPKK/xanh-android) | Native Android browser |
| [xanh-ios](https://github.com/LamPPKK/xanh-ios) | Native iPhone and iPad browser — this repository |
| [xanh-webview](https://github.com/LamPPKK/xanh-webview) | Cross-platform embedding API and backend contract |
| [xanh-docker](https://github.com/LamPPKK/xanh-docker) | Containerized WPE remote-browser runtime |
| [xanh-tab](https://github.com/LamPPKK/xanh-tab) | WPE-based appliance and tab surface |

Each repository has its own platform boundary and release evidence. A passing
Docker, Android, or Xanh Tab workflow is not evidence that the iOS TestFlight
gate has passed.

## License

This repository does not currently include a project-wide license file. Until
one is added, no general permission to copy, modify, or redistribute the Xanh
iOS application code is granted. EasyList, EasyPrivacy, and their derived
artifacts retain their GPL-3.0-or-later attribution and terms; see the
[blocker license notes](Blocker/README.md).
