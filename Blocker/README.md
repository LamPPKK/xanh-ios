# Xanh content-rule artifacts

Xanh derives its blocker data from EasyList and EasyPrivacy at the exact commit in `sources.json`. Both source lists are distributed under GPL-3.0-or-later; generated artifacts are published separately with their source commit, attribution, unsupported-rule report, checksum and signature.

The converter intentionally implements only a reviewed subset of Adblock Plus syntax. Unsupported exceptions, cosmetic filters and complex option combinations are reported rather than approximated. Each output shard is independently compiled by `WKContentRuleListStore`; the app activates a release only after every shard passes signature, checksum and compilation checks.

Build locally:

```sh
python3 Tools/build_blocker.py --sources Blocker/sources.json --output build/blocker
python3 -m unittest discover -s Tools/tests
```

The signing key is never stored in this repository. Release automation receives an Ed25519 private PEM through a protected GitHub environment and publishes only the signed manifest and public artifacts.

Upstream attribution and license: [EasyList and EasyPrivacy](https://easylist.to/pages/licence.html).
