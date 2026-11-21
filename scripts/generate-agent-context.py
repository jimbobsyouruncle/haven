#!/usr/bin/env python3
"""Generate Haven's architectural maps with the pinned shared generator."""

import argparse
from pathlib import Path
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("generator", type=Path)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--output-dir", type=Path, default=Path("."))
    args = parser.parse_args()

    subprocess.run(
        [sys.executable, str(args.generator), "--root", str(args.root),
         "--output-dir", str(args.output_dir), "--max-bytes", "30720"],
        check=True,
    )

    index = args.output_dir / "CODE_INDEX.md"
    # Dockerfile entries start with "- FROM". Keep the image name (including
    # any registry port), platform flag, stage alias and remainder of the line.
    reference = re.compile(
        r"^(- FROM\s+(?:--platform=\S+\s+)?)([^\s@]+)(?:@[^\s]+)?",
        re.IGNORECASE | re.MULTILINE,
    )

    def strip_pin(match):
        prefix, image = match.groups()
        if "$" in match[0]:
            return match[0]
        repository, slash, name = image.rpartition("/")
        return prefix + repository + slash + name.split(":", 1)[0]

    original = index.read_text(encoding="utf-8")
    index.write_text(reference.sub(strip_pin, original), encoding="utf-8")


if __name__ == "__main__":
    main()
