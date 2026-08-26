#!/usr/bin/env python3

import argparse
import hashlib
import json
import re
import urllib.request
from pathlib import Path


RESOURCE_TYPES = {
    "document": "document",
    "font": "font",
    "image": "image",
    "media": "media",
    "object": "raw",
    "ping": "raw",
    "script": "script",
    "stylesheet": "style-sheet",
    "xmlhttprequest": "raw",
}


def domain_pattern(domain: str) -> str:
    escaped = re.escape(domain.lower().strip("."))
    # WKContentRuleList rejects regular-expression disjunctions. HTTP(S) URLs
    # serialize a delimiter after the host, so a character class keeps the
    # host boundary exact without the unsupported `([/:]|$)` branch.
    return rf"^https?://([^/]+\.)?{escaped}[/:?#]"


def translate(line: str):
    line = line.strip()
    if not line or line.startswith("!") or line.startswith("["):
        return None, "metadata"
    if line.startswith("@@"):
        return None, "exception"
    if "##" in line or "#?#" in line or "#$#" in line:
        return None, "cosmetic"

    pattern, separator, options_text = line.partition("$")
    trigger = {}
    if pattern.startswith("||") and pattern.endswith("^"):
        domain = pattern[2:-1]
        if not re.fullmatch(r"[A-Za-z0-9._-]+", domain):
            return None, "complex-network-pattern"
        trigger["url-filter"] = domain_pattern(domain)
    elif pattern.startswith("|") and pattern.endswith("|"):
        literal = pattern[1:-1]
        if not literal.startswith(("http://", "https://")):
            return None, "non-http-literal"
        trigger["url-filter"] = "^" + re.escape(literal) + "$"
    else:
        return None, "complex-network-pattern"

    if separator:
        resource_types = []
        include_domains = []
        for option in options_text.split(","):
            if option in RESOURCE_TYPES:
                resource_types.append(RESOURCE_TYPES[option])
            elif option.startswith("domain="):
                domains = option.removeprefix("domain=").split("|")
                if any(domain.startswith("~") for domain in domains):
                    return None, "excluded-domain-option"
                include_domains.extend(domain for domain in domains if domain)
            elif option in {"important", "match-case", "third-party"}:
                continue
            elif option.startswith("~") or option:
                return None, "unsupported-option"
        if resource_types:
            trigger["resource-type"] = sorted(set(resource_types))
        if include_domains:
            trigger["if-domain"] = sorted(set(include_domains))

    return {"trigger": trigger, "action": {"type": "block"}}, None


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "XanhBlockerBuilder/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8")


def expand_template(url: str, repository: str, commit: str) -> str:
    template = fetch(url)
    raw_base = f"https://raw.githubusercontent.com/{repository.removeprefix('https://github.com/').strip('/')}/{commit}"
    lines = []
    for line in template.splitlines():
        match = re.fullmatch(r"%include easylist:(.+)%", line.strip())
        if match:
            lines.extend(fetch(f"{raw_base}/{match.group(1)}").splitlines())
        else:
            lines.append(line)
    return "\n".join(lines)


def write_shards(rules, output: Path, max_rules: int):
    artifacts = []
    for index in range(0, len(rules), max_rules):
        shard = rules[index:index + max_rules]
        name = f"content-rules-{index // max_rules + 1:03d}.json"
        data = json.dumps(shard, ensure_ascii=False, separators=(",", ":")).encode()
        (output / name).write_bytes(data)
        artifacts.append({
            "identifier": name.removesuffix(".json"),
            "file": name,
            "sha256": hashlib.sha256(data).hexdigest(),
            "rules": len(shard),
            "bytes": len(data),
        })
    return artifacts


def build(sources_path: Path, output: Path, max_rules: int):
    sources = json.loads(sources_path.read_text())
    output.mkdir(parents=True, exist_ok=True)
    rules = []
    unsupported = {}
    seen = set()
    per_source = []
    for source in sources["files"]:
        accepted = 0
        total = 0
        source_text = expand_template(
            source["url"],
            sources["repository"],
            sources["commit"],
        ) if source["url"].endswith(".template") else fetch(source["url"])
        for line in source_text.splitlines():
            total += 1
            rule, reason = translate(line)
            if rule is None:
                if reason != "metadata":
                    unsupported[reason] = unsupported.get(reason, 0) + 1
                continue
            key = json.dumps(rule, sort_keys=True, separators=(",", ":"))
            if key not in seen:
                seen.add(key)
                rules.append(rule)
                accepted += 1
        per_source.append({"name": source["name"], "totalLines": total, "acceptedRules": accepted})

    artifacts = write_shards(rules, output, max_rules)
    index = {
        "sourceRepository": sources["repository"],
        "sourceCommit": sources["commit"],
        "license": sources["license"],
        "artifacts": artifacts,
    }
    report = {
        "sources": per_source,
        "acceptedRules": len(rules),
        "unsupported": dict(sorted(unsupported.items())),
    }
    (output / "artifact-index.json").write_text(json.dumps(index, indent=2) + "\n")
    (output / "conversion-report.json").write_text(json.dumps(report, indent=2) + "\n")
    return index, report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-rules", type=int, default=20_000)
    args = parser.parse_args()
    build(args.sources, args.output, args.max_rules)


if __name__ == "__main__":
    main()
