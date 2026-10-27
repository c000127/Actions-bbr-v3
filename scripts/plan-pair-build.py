#!/usr/bin/env python3
"""Choose missing kernel releases for one validated XanMod source tag."""

import argparse
import json
from pathlib import Path
import re
import sys


TAG = re.compile(
    r"(?P<major>[0-9]+)\.(?P<minor>[0-9]+)(?:\.(?P<patch>[0-9]+))?"
    r"(?P<rc>-rc[0-9]+)?-xanmod(?P<revision>[0-9]+)"
)


def release_names(tag: str) -> tuple[str, str, str]:
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError(f"unsupported XanMod tag: {tag}")
    raw_version = tag.rsplit("-xanmod", 1)[0]
    release_version = (
        f"{match['major']}.{match['minor']}.{match['patch'] or '0'}"
        f"{match['rc'] or ''}"
    )
    suffix = f"xanmod{match['revision']}"
    return raw_version, f"{release_version}-{suffix}", f"{release_version}-aggressive-{suffix}"


def complete(release, kernel_release: str) -> bool:
    if release is None:
        return False
    if not isinstance(release, dict) or not isinstance(release.get("assets"), list):
        raise ValueError("invalid GitHub release response")
    if release.get("draft"):
        raise ValueError("a matching release is a draft; refusing to overwrite it automatically")

    def present(kind: str) -> bool:
        prefix = f"linux-{kind}-{kernel_release}_"
        return any(
            isinstance(asset, dict)
            and isinstance(asset.get("name"), str)
            and asset["name"].startswith(prefix)
            and asset["name"].endswith("_amd64.deb")
            and asset.get("state") == "uploaded"
            and isinstance(asset.get("size"), int)
            and asset["size"] > 0
            for asset in release["assets"]
        )

    return present("image") and present("headers")


def plan(tag: str, standard, aggressive, force: bool = False) -> dict[str, str]:
    version, standard_release, aggressive_release = release_names(tag)
    # Validate both responses, including drafts, even when a rebuild is forced.
    standard_ready = complete(standard, standard_release)
    aggressive_ready = complete(aggressive, aggressive_release)
    return {
        "tag": tag,
        "version": version,
        "build_standard": str(force or not standard_ready).lower(),
        "build_aggressive": str(force or not aggressive_ready).lower(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("standard", type=Path)
    parser.add_argument("aggressive", type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        standard = json.loads(args.standard.read_text(encoding="utf-8"))
        aggressive = json.loads(args.aggressive.read_text(encoding="utf-8"))
        result = plan(args.tag, standard, aggressive, args.force)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Cannot safely plan the kernel releases: {exc}", file=sys.stderr)
        return 1
    for name, value in result.items():
        print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
