#!/usr/bin/env python3
"""Set package metadata versions to the GitHub release tag before building."""

import re
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: set-release-version.py <release-tag>")

    match = re.fullmatch(r"v?([0-9]+\.[0-9]+\.[0-9]+)", sys.argv[1])
    if match is None:
        raise SystemExit("Release tag must be a version such as 1.2.3 or v1.2.3")
    version = match.group(1)

    project_dir = Path(__file__).resolve().parent.parent
    patterns = {
        "mix.exs": r'(?m)^(\s+version: ")[^"]+("[,])$',
        "src-tauri/tauri.conf.json": r'(?m)^(  "version": ")[^"]+("[,])$',
        "src-tauri/Cargo.toml": r'(?m)^(\[package\]\nname = "mdt_client"\nversion = ")[^"]+(")$',
        "src-tauri/Cargo.lock": r'(?m)^(\[\[package\]\]\nname = "mdt_client"\nversion = ")[^"]+(")$',
    }

    changes = {}
    for relative_path, pattern in patterns.items():
        path = project_dir / relative_path
        updated, count = re.subn(
            pattern,
            lambda found: f"{found.group(1)}{version}{found.group(2)}",
            path.read_text(),
        )
        if count != 1:
            raise SystemExit(f"Expected one version in {relative_path}, found {count}")
        changes[path] = updated

    for path, content in changes.items():
        path.write_text(content)

    print(version)


if __name__ == "__main__":
    main()
