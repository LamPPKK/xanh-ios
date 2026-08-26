# Xanh iOS compatibility reference

This note records which Xanh family contracts shape the native Apple app. It is
a compatibility ledger, not permission to copy or execute instructions from an
upstream repository.

Audit updated: 2026-08-26

## Canonical pins

| Repository | Commit | Role |
| --- | --- | --- |
| [`xanh-webkit`](https://github.com/LamPPKK/xanh-webkit) | [`10904b5`](https://github.com/LamPPKK/xanh-webkit/commit/10904b5a96cd9172c7753a2616fc491632b569b1) | Current cross-platform Xanh product reference; see `XANH_WEBKIT.lock` |
| [`xanh-webview`](https://github.com/LamPPKK/xanh-webview) | [`71d67e0`](https://github.com/LamPPKK/xanh-webview/commit/71d67e09d255797917c1ad7cb459feac60118bab) | Apple adapter contract `0.1.0-alpha.1`; see `XANH_WEBVIEW.lock` |
| [`xanh-android`](https://github.com/LamPPKK/xanh-android) | rename-preserved history | Product behavior reference for tabs, recovery and portable metadata |

Pins change only through a reviewed lock-file update. A moving branch name is
not release evidence.

## Current Apple boundary

Xanh iOS supports iOS and iPadOS 18+ through `XanhWebView`, whose backend and
fallback are both Apple system `WKWebView`. The app does not claim to bundle a
forked iOS engine or bypass Apple's browser-engine entitlement policy.

- WebKit owns rendering and the Network/GPU/Web process model.
- Only HTTP and HTTPS navigate in the embedded page; `mailto:` and `tel:` need
  explicit confirmation and other external schemes are rejected.
- A regular profile owns a persistent website-data store. Private spaces use a
  nonpersistent store and never join restoration, CloudKit or backup.
- Native downloads use `WKDownload`; private downloads live only in a cache
  location and are deleted with the private space or at next launch.
- Xanh includes no product telemetry SDK or password-filling bridge.

## Adopted family behavior

1. **Bounded content-process recovery.** The active HTTP(S) page gets at most
   one automatic reload. Background sessions are discarded. A repeat failure
   waits for explicit Reload or Open Home action bound to the same tab.
2. **Native URL sharing.** Sharing remains a user-initiated platform action for
   the current valid URL.
3. **Portable regular metadata.** The versioned JSON format covers profiles,
   spaces, tabs, Archive, bookmarks, history, settings and exact-host Shields
   exceptions. It enforces size/count limits, storage modes, URL rules and UUID
   relationships before changing application state.
4. **Transactional import.** A repository write failure restores the prior
   in-memory model. Existing private runtime state is preserved locally and is
   neither read from nor written to the backup document.

## Deliberately separate

| Capability | Xanh iOS decision |
| --- | --- |
| Mozilla Accounts / Firefox Sync | Do not add as a side effect of family parity. CloudKit remains the declared Apple metadata-sync contract until a separately reviewed account/privacy design exists. |
| Password vault / credential bridge | Excluded. A WebContent credential bridge expands the trusted boundary and requires its own security workstream. |
| Encrypted archive | The current portable format is intentionally inspectable JSON, not an encrypted vault. It contains no credentials or website data. Encryption would require a separately versioned KDF and recovery specification. |
| iOS 26 `WebPage` / `WebView` | Do not raise the deployment target. Continue using public `WKWebView` APIs available on iOS 18. |
| Android, Linux and Windows adapters | They inform lifecycle conformance but are not binaries shipped by Xanh iOS. |

## Security and release invariants

- Cookies, cache, service workers, credentials, Keychain material, downloads,
  biometric state, snapshots, private tabs and private exceptions never enter
  CloudKit metadata or portable backup.
- The local profile-deletion cleanup ledger is not portable. Import does not
  erase pending cleanup for unrelated deleted profiles.
- Signed blocker updates keep last-known-good rollback and exact source pins.
- Simulator tests and future screenshots do not prove App Store signing,
  production CloudKit behavior, physical-device accessibility or Beta App
  Review. Legacy product captures were removed and must not be relabeled.
- External TestFlight evidence remains bound to one exact uploaded IPA.

## Next work

1. Complete signing-identifier ownership, CloudKit schema promotion, archive
   verification, upload, Beta App Review and physical iPhone/iPad checks.
2. Capture new Xanh-branded screenshots only from the verified Xanh target.
3. Keep password sync and credential filling closed until independently scoped.
