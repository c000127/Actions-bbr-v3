#!/usr/bin/env python3
"""Choose missing kernel releases for one validated XanMod source tag."""

import argparse
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_provenance import manifest_from_release, valid_kernel_release, verified_assets


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


def complete(release, profile: str, tag: str, source_commit: str, fingerprint: str) -> bool:
    if release is None:
        return False
    if not isinstance(release, dict) or not isinstance(release.get("assets"), list):
        raise ValueError("invalid GitHub release response")
    if release.get("draft"):
        raise ValueError("a matching release is a draft; refusing to overwrite it automatically")

    manifest = manifest_from_release(release)
    kernel_release = manifest.get("kernel_release") if manifest else None
    return bool(
        manifest
        and manifest.get("schema") == 1
        and manifest.get("profile") == profile
        and manifest.get("source_tag") == tag
        and manifest.get("source_commit") == source_commit
        and manifest.get("fingerprint") == fingerprint
        and valid_kernel_release(tag, profile, fingerprint, kernel_release)
        and isinstance(manifest.get("project_commit"), str)
        and verified_assets(release, manifest, kernel_release)
    )


def plan(tag: str, standard, aggressive, source_commit: str, fingerprint: str, force: bool = False) -> dict[str, str]:
    version, _, _ = release_names(tag)
    if not re.fullmatch(r"[0-9a-f]{40,64}", source_commit) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
        raise ValueError("invalid source or build identity")
    # Validate both responses, including drafts, even when a rebuild is forced.
    standard_ready = complete(standard, "standard", tag, source_commit, fingerprint)
    aggressive_ready = complete(aggressive, "aggressive", tag, source_commit, fingerprint)
    return {
        "tag": tag,
        "version": version,
        "source_commit": source_commit,
        "fingerprint": fingerprint,
        "build_standard": str(force or not standard_ready).lower(),
        "build_aggressive": str(force or not aggressive_ready).lower(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("standard", type=Path)
    parser.add_argument("aggressive", type=Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        standard = json.loads(args.standard.read_text(encoding="utf-8"))
        aggressive = json.loads(args.aggressive.read_text(encoding="utf-8"))
        result = plan(args.tag, standard, aggressive, args.source_commit, args.fingerprint, args.force)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Cannot safely plan the kernel releases: {exc}", file=sys.stderr)
        return 1
    for name, value in result.items():
        print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
