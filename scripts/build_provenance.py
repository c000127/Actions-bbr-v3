#!/usr/bin/env python3
"""Identify paired kernel inputs and safely commit a Release asset selection."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
INPUTS = (
    "x86-64.config",
    "x86-64-aggressive.config",
    "scripts/apply-aggressive-bbr.py",
    "scripts/build_provenance.py",
    ".github/workflows/build.yml",
)
MARKER = "<!-- BBR_BUILD_V1 "
MARKER_RE = re.compile(r"<!-- BBR_BUILD_V1 ([^\r\n]*?) -->")
INFO_RE = re.compile(r"<!-- BBR_BUILD_INFO_START -->[\s\S]*?<!-- BBR_BUILD_INFO_END -->")
SHA = re.compile(r"[0-9a-f]{40,64}")
TAG = re.compile(r"([0-9]+)\.([0-9]+)(?:\.([0-9]+))?(-rc[0-9]+)?-xanmod([0-9]+)")


def fingerprint(tag, source_commit):
    if not SHA.fullmatch(source_commit):
        raise ValueError("invalid upstream commit")
    result = hashlib.sha256()
    for name, data in [("tag", tag.encode()), ("source_commit", source_commit.encode())] + [
        (name, (ROOT / name).read_bytes()) for name in INPUTS
    ]:
        result.update(name.encode() + b"\0" + str(len(data)).encode() + b"\0" + data)
    return result.hexdigest()


def manifest_from_release(release):
    body = release.get("body") or ""
    if not isinstance(body, str):
        raise ValueError("release body is not text")
    matches = MARKER_RE.findall(body)
    if MARKER in body and len(matches) != 1:
        raise ValueError("invalid or duplicated build manifest")
    if not matches:
        return None
    value = json.loads(matches[0])
    if not isinstance(value, dict):
        raise ValueError("invalid build manifest")
    return value


def valid_kernel_release(tag, profile, build_fingerprint, kernel_release):
    match = TAG.fullmatch(tag)
    if not match or profile not in ("standard", "aggressive") or not re.fullmatch(r"[0-9a-f]{64}", build_fingerprint):
        return False
    major, minor, patch, rc, revision = match.groups()
    version = f"{major}.{minor}.{patch or '0'}{rc or ''}"
    variant = "-aggressive" if profile == "aggressive" else ""
    pattern = re.escape(version) + "-b" + build_fingerprint[:10] + r"r[0-9a-f]+a[0-9]+" + re.escape(variant + "-xanmod" + revision)
    return isinstance(kernel_release, str) and re.fullmatch(pattern, kernel_release) is not None


def verified_assets(release, manifest, kernel_release):
    """Check that the published manifest names one intact image and headers."""
    assets = release.get("assets")
    entries = manifest.get("assets")
    if not isinstance(assets, list) or not isinstance(entries, dict):
        return False
    for kind in ("image", "headers"):
        entry = entries.get(kind)
        if not isinstance(entry, dict):
            return False
        name, digest, size = entry.get("name"), entry.get("sha256"), entry.get("size")
        if not isinstance(name, str) or not name.startswith(f"linux-{kind}-{kernel_release}_") or not name.endswith("_amd64.deb"):
            return False
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest) or not isinstance(size, int) or size <= 0:
            return False
        matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == name]
        if len(matches) != 1 or matches[0].get("state") != "uploaded" or matches[0].get("size") != size:
            return False
        remote_digest = matches[0].get("digest")
        if remote_digest is not None and remote_digest != f"sha256:{digest}":
            return False
    return True


def create_manifest(args):
    if not valid_kernel_release(args.tag, args.profile, args.fingerprint, args.kernel_release):
        raise ValueError("kernel release does not identify this profile and build")
    entries = {}
    for path in sorted(args.package_dir.glob("linux-*.deb")):
        for kind in ("image", "headers"):
            if path.name.startswith(f"linux-{kind}-{args.kernel_release}_") and path.name.endswith("_amd64.deb"):
                if kind in entries:
                    raise ValueError(f"multiple {kind} packages")
                with path.open("rb") as file:
                    digest = hashlib.file_digest(file, "sha256").hexdigest()
                entries[kind] = {"name": path.name, "size": path.stat().st_size, "sha256": digest}
    if set(entries) != {"image", "headers"}:
        raise ValueError("expected one image and one matching headers package")
    if not SHA.fullmatch(args.project_commit) or fingerprint(args.tag, args.source_commit) != args.fingerprint:
        raise ValueError("build identity does not match the checked-out sources")
    return {
        "schema": 1,
        "profile": args.profile,
        "source_tag": args.tag,
        "source_commit": args.source_commit,
        "project_commit": args.project_commit,
        "fingerprint": args.fingerprint,
        "config_sha256": hashlib.sha256(args.config.read_bytes()).hexdigest(),
        "patch_sha256": hashlib.sha256((ROOT / "scripts/apply-aggressive-bbr.py").read_bytes()).hexdigest(),
        "compiler": args.compiler,
        "kernel_release": args.kernel_release,
        "assets": entries,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    identity = commands.add_parser("fingerprint")
    identity.add_argument("tag")
    identity.add_argument("source_commit")
    create = commands.add_parser("manifest")
    for name in ("profile", "tag", "source-commit", "project-commit", "fingerprint", "compiler", "kernel-release"):
        create.add_argument(f"--{name}", required=True)
    create.add_argument("--package-dir", type=Path, required=True)
    create.add_argument("--config", type=Path, required=True)
    body = commands.add_parser("release-body")
    body.add_argument("--manifest", type=Path, required=True)
    body.add_argument("--release", type=Path, required=True)
    body.add_argument("--default-body", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "fingerprint":
            print(fingerprint(args.tag, args.source_commit))
        elif args.command == "manifest":
            print(json.dumps(create_manifest(args), ensure_ascii=False, separators=(",", ":")))
        else:
            manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
            release = json.loads(args.release.read_text(encoding="utf-8"))
            if not verified_assets(release, manifest, manifest["kernel_release"]):
                raise ValueError("uploaded image and headers do not match the manifest")
            # Never destroy existing release text or expose an incomplete build.
            existing = release.get("body") or args.default_body.read_text(encoding="utf-8")
            manifest_from_release({"body": existing})  # reject malformed pre-existing markers
            existing = INFO_RE.sub("", MARKER_RE.sub("", existing)).rstrip()
            existing = existing.replace("> Debian 11+ / Ubuntu 20.04+ · 安装后需重启",
                                        "> 支持 Debian 13 及以后版本 · 安装后需重启")
            existing = existing.replace("或: `sudo dpkg -i linux-*.deb && sudo update-grub && sudo reboot`",
                                        "手动安装时请仅下载下列当前构建的镜像及配套头文件，并按发行版文档安装。")
            info = (
                "<!-- BBR_BUILD_INFO_START -->\n"
                "### 当前构建来源\n\n"
                f"- 上游：`{manifest['source_tag']}` / `{manifest['source_commit']}`\n"
                f"- 项目提交：`{manifest['project_commit']}`\n"
                f"- 双版本输入摘要：`{manifest['fingerprint']}`\n"
                f"- 最终配置摘要：`{manifest['config_sha256']}`\n"
                f"- 编译器：`{manifest['compiler']}`\n"
                f"- 当前镜像：`{manifest['assets']['image']['name']}`，SHA-256 `{manifest['assets']['image']['sha256']}`\n"
                f"- 当前头文件：`{manifest['assets']['headers']['name']}`，SHA-256 `{manifest['assets']['headers']['sha256']}`\n"
                "<!-- BBR_BUILD_INFO_END -->"
            )
            print(existing + "\n\n" + info + "\n\n" + MARKER + json.dumps(manifest, ensure_ascii=False, separators=(",", ":")) + " -->")
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(f"Cannot create or publish build identity: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
