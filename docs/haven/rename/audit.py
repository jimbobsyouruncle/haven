#!/usr/bin/env python3
"""Reproduce the public, immutable #147 rename inventory; never inspect local state."""
from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit

BASELINE = "c2286bcd266e1924797fc787a677e6f8aa2d94da"
ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
PATTERN = re.compile(r"hybrid[-_ ]ai|\bhybrid\b", re.IGNORECASE)
FIELDS = ["id", "kind", "path", "line", "column", "token", "classification", "rule", "rationale", "proposed_action", "owner_issue", "phase", "line_sha256"]


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def has_ghcr_reference(line: str) -> bool:
    """Recognize HTTPS/OCI references by parsed hostname, never a URL substring.

    Source lines may wrap references in Markdown, quotes or Compose syntax.
    Candidate extraction keeps userinfo and deceptive host suffixes intact so
    parsing can reject them instead of finding a trusted-looking inner string.
    This is audit classification only; it performs no network requests.
    """
    candidates = re.findall(
        r"(?<![\w./:@-])(?:https?://)?[\w.:%@-]+/[^\s`\"'<>()[\]{},;]+",
        line, re.IGNORECASE,
    )
    for candidate in candidates:
        try:
            parsed = urlsplit(candidate if "://" in candidate else "https://" + candidate)
            if (parsed.scheme == "https" and parsed.hostname == "ghcr.io"
                    and parsed.username is None and parsed.password is None
                    and parsed.port in (None, 443) and parsed.path != "/"):
                return True
        except ValueError:
            # Malformed authorities/ports are not registry evidence.
            continue
    return False


def classify(path: str, line: str, match: re.Match[str], kind: str) -> tuple[str, str, str, str, str, str]:
    """Ordered conservative triage. Manual review is an unresolved decision, not approval."""
    token = match.group()
    lower = line.lower()
    pos = match.start()
    if kind == "filename":
        return ("compatibility alias", "P01", "Tracked path has imports, unit references or installed consumers.", "Retain path; any later move needs a consumer migration.", "149", "preserve")
    if "runpod-hybrid-worker" in lower:
        return ("preserve", "P02", "Separate worker repository or image identity; outside rename scope.", "Keep identity; obtain separately authorized integration evidence.", "149", "external gate")
    if path in ("REPO_MAP.md", "CODE_INDEX.md"):
        return ("preserve", "P03", "Generated navigation reflects real source paths and symbols.", "Regenerate with the pinned generator; never mass-edit names.", "148", "prepare")
    if path == "docs/haven/ARCHITECTURE.md" and line.startswith("**Baseline:"):
        return ("preserve", "P04", "Historical source attribution describes the pre-migration baseline.", "Retain historical name and date.", "148", "preserve")
    if re.search(r"jimbobsyouruncle/hybrid-ai(?:\.git|[/\s`\"']|$)", line, re.IGNORECASE):
        return ("rename", "R01", "Canonical main-repository URL or slug has a cutover consumer.", "Prepare old/new identity support; activate canonical URL only at cutover; update related fixtures.", "149" if path.startswith(("scripts/", "deploy/", ".github/")) else "148", "150 cutover")
    # A lexeme embedded in a longer identifier, path, image name or runtime name
    # must not be mistaken for a stand-alone product heading.
    left = line[:pos]
    right = line[match.end():]
    adjacent = (left[-1:] in ("/", "_", "-", ".")) or bool(re.match(r"[_/.-][A-Za-z0-9]", right))
    if token.lower().replace("-", "_") == "hybrid_ai" and re.match(r"_[A-Za-z0-9]", right):
        return ("compatibility alias", "P05", "Environment setting, function or symbol is an existing interface.", "Retain spelling and precedence; deprecate only with consumer evidence.", "149", "preserve")
    if token.lower() == "hybrid":
        if "image" in lower or has_ghcr_reference(line) or "hybrid." in lower:
            return ("preserve", "P06", "Derived image identity/tag is not the main repository name.", "Keep package/tag; test publisher and pull consumers without renaming.", "149", "preserve")
        if any(x in lower for x in ("architecture", "local", "cloud", "inference", "hybrid mode", "hybrid setup")):
            return ("preserve", "P07", "Semantic hybrid terminology describes architecture or behavior.", "Retain technical meaning; reviewer checks context at pinned line.", "148", "preserve")
        return ("manual review", "M01", "Standalone hybrid may be terminology, image identity or branding.", "Owner/reviewer determines meaning from pinned source before any edit.", "148", "prepare decision")
    if path.startswith("scripts/test-") or path.startswith("status/test_") or path.startswith("auth/test_"):
        return ("preserve", "P08", "Fixture or assertion models current compatibility behavior.", "Retain unless its production consumer changes; then update and prove both directions.", "149", "prepare")
    if path.startswith(("backup/", "deploy/")) or adjacent or any(x in lower for x in ("container_name:", "name: hybrid-ai", "-p hybrid-ai", "cookie_name", "logger =", "user_agent=", "tag=", "--tag hybrid-ai", "readonly tag=", "app_networks=")):
        return ("compatibility alias", "P09", "Operational name/path, package, log identity or backup selector has consumers.", "Retain for this epic; trace coupled consumers in the dependency register.", "149", "preserve")
    if path.startswith(("scripts/", ".github/")) or path.endswith((".sh", ".yml", ".tmpl", ".service", ".timer")):
        return ("manual review", "M02", "Executable/configuration reference may drive behavior even inside a message or example.", "Review with operational consumer; change display text only after ruling out interface use.", "149", "prepare decision")
    if path == "status/app.py":
        if any(x in lower for x in ("<title>", "<h1>", "<footer>", "diagnostic bundle")):
            return ("rename", "R02", "Rendered product branding does not select an operational resource.", "Change visible product label in #148 with rendering validation.", "148", "prepare")
        return ("manual review", "M03", "Diagnostic filename, header, unit hint or lookup can be an interface.", "Identify download/monitoring consumer before changing.", "148", "prepare decision")
    if path.endswith(".md"):
        return ("manual review", "M04", "Documentation mixes branding, historical records and executable instructions.", "Classify intended edit from pinned context; preserve operational examples until their consumers migrate.", "148", "prepare decision")
    return ("manual review", "M05", "No narrow safe rename rule applies to this source reference.", "Review consumer and compatibility before editing; no automatic replacement.", "149", "prepare decision")


def render() -> dict[str, bytes]:
    tree = git("ls-tree", "-rz", "--full-tree", BASELINE).split(b"\0")
    entries = []
    for item in tree:
        if not item:
            continue
        meta, raw_path = item.split(b"\t", 1)
        mode, kind, oid = meta.decode().split()
        if mode not in ("100644", "100755") or kind != "blob":
            raise ValueError("Refuse symlink/submodule/nonregular entry: " + raw_path.decode())
        entries.append((raw_path.decode(), oid))
    rows = []
    hashes = []
    content_lines = set()
    lexical_count = 0
    legacy_count = 0
    binary = []
    for path, oid in entries:
        data = git("cat-file", "blob", oid)
        hashes.append({"path": path, "blob": oid, "sha256": hashlib.sha256(data).hexdigest()})
        if b"\0" in data:
            binary.append(path)
            continue
        text = data.decode("utf-8")
        for kind, lines in (("filename", [path]), ("content", text.splitlines())):
            for number, line in enumerate(lines, 1):
                for match in PATTERN.finditer(line):
                    classification, rule, reason, action, issue, phase = classify(path, line, match, kind)
                    if kind == "content":
                        lexical_count += 1
                        legacy_count += match.group().lower() != "hybrid"
                        content_lines.add((path, number))
                    rows.append({"id": "A%05d" % (len(rows) + 1), "kind": kind, "path": path,
                                 "line": number if kind == "content" else 0, "column": match.start() + 1,
                                 "token": match.group(), "classification": classification, "rule": rule,
                                 "rationale": reason, "proposed_action": action, "owner_issue": issue,
                                 "phase": phase, "line_sha256": hashlib.sha256(line.encode()).hexdigest()})
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=FIELDS, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    summary = {"baseline": BASELINE, "pattern": PATTERN.pattern, "tracked_files": len(entries),
               "excluded_binary_files": binary, "content_occurrences": lexical_count,
               "legacy_content_occurrences": legacy_count, "matched_content_lines": len(content_lines),
               "matched_content_files": len({r["path"] for r in rows if r["kind"] == "content"}),
               "filename_occurrences": sum(r["kind"] == "filename" for r in rows),
               "classifications": dict(sorted(collections.Counter(r["classification"] for r in rows).items())),
               "rules": dict(sorted(collections.Counter(r["rule"] for r in rows).items())),
               "scope": "Immutable public baseline only; local/untracked/external state excluded."}
    return {"inventory.csv": output.getvalue().encode(),
            "summary.json": (json.dumps(summary, indent=2, sort_keys=True) + "\n").encode(),
            "source-manifest.json": (json.dumps(hashes, indent=2) + "\n").encode()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true", help="write only the three audit artifacts beside this script")
    group.add_argument("--check", action="store_true", help="verify artifacts without writes")
    args = parser.parse_args()
    artifacts = render()
    failures = []
    for name, data in artifacts.items():
        target = HERE / name
        if args.write:
            target.write_bytes(data)
        elif not target.is_file() or target.read_bytes() != data:
            failures.append(name)
    if failures:
        print("FAIL: stale/missing audit artifacts: " + ", ".join(failures))
        return 1
    print("PASS: " + ("wrote" if args.write else "verified") + " immutable baseline inventory, summary and manifest")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
