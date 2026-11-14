#!/usr/bin/env python3
"""Inventory immutable public Git objects; never open deployment/local env files."""
import argparse
import collections
import csv
import hashlib
import io
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

TOKEN = re.compile(r"hybrid(?:[-_ ]ai)?(?:[-_][A-Za-z0-9_.@-]+)?", re.I)
BASE = "bdfbbc6269bf3b5d6430b13cdea587c833ea1832"
WORKER = "cf402976b09d8d155c62f5f4b83d174b35d3521f"


def registry_reference(line):
    # Classify artifact references by parsed authority, never host substrings.
    for candidate in re.findall(r"(?:https?://)?[A-Za-z0-9._@:+-]+/[A-Za-z0-9_./:@+-]+", line):
        try:
            parsed = urlsplit(candidate if "://" in candidate else "https://" + candidate)
            if (parsed.scheme == "https" and parsed.hostname == "ghcr.io"
                    and parsed.username is None and parsed.password is None
                    and parsed.port in (None, 443)):
                return True
        except ValueError:
            continue
    return False


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def classify(repo, path, line):
    # Conservative triage: the dependency register supplies contract decisions.
    if path.startswith("docs/haven/rename/") or path.startswith("docs/haven/adr/"):
        return "4", "historical-decision"
    if path in ("REPO_MAP.md", "CODE_INDEX.md"):
        return "1", "generated-navigation"
    if repo == "worker" or "runpod-hybrid-worker" in line or registry_reference(line):
        return "3", "external-artifact"
    if re.search(r"restic|--tag|cookie|credstore|authorized_keys|polkit|flock|lock|/var/|/etc/|/home/", line, re.I):
        return "2", "persistent-or-security"
    if path == "scripts/lib/repository-identity.sh" or "jimbobsyouruncle/hybrid-ai" in line:
        return "5", "legacy-selector"
    return "1", "active-consumer"


def scan(root, repo, revision):
    rows, manifest = [], []
    tree = git(root, "ls-tree", "-rz", "--full-tree", revision)
    for entry in tree.split(b"\0"):
        if not entry:
            continue
        meta, name = entry.split(b"\t", 1)
        mode, kind, oid = meta.decode().split()
        path = name.decode("utf-8")
        if mode not in ("100644", "100755") or kind != "blob":
            raise ValueError("nonregular tracked entry: " + path)
        data = git(root, "cat-file", "blob", oid)
        content = data.decode("utf-8")
        manifest.append(dict(repository=repo, revision=revision, path=path,
                             blob=oid, sha256=hashlib.sha256(data).hexdigest()))
        for number, line in [(0, path), *enumerate(content.splitlines(), 1)]:
            for match in TOKEN.finditer(line):
                category, contract = classify(repo, path, line)
                rows.append([repo, revision, path, number, match.start() + 1,
                             match.group(), category, contract,
                             hashlib.sha256(line.encode()).hexdigest()])
    return rows, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    records, manifest = [], []
    for repo, source, sha in (("haven", root, BASE), ("worker", args.worker, WORKER)):
        rows, files = scan(source, repo, sha)
        records.extend(rows)
        manifest.extend(files)
    output = io.StringIO(newline="")
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(["repository", "revision", "path", "line", "column", "token",
                     "category", "contract", "line_sha256"])
    writer.writerows(records)
    summary = dict(files=len(manifest), occurrences=len(records),
                   by_repository=dict(collections.Counter(r[0] for r in records)),
                   by_category=dict(sorted(collections.Counter(r[6] for r in records).items())))
    artifacts = {"inventory.csv": output.getvalue(),
                 "manifest.json": json.dumps(manifest, indent=2) + "\n",
                 "summary.json": json.dumps(summary, indent=2) + "\n"}
    for name, value in artifacts.items():
        target = here / name
        if args.check:
            if target.read_text() != value:
                raise SystemExit("inventory mismatch: " + name)
        else:
            target.write_text(value)
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
