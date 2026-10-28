#!/usr/bin/env python3
"""Verify incomplete uploads cannot replace a usable release selection."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_provenance as provenance


class BuildProvenanceTest(unittest.TestCase):
    def test_release_body_changes_only_after_both_new_assets_verify(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tag, source = "7.3.0-xanmod1", "a" * 40
            fingerprint = provenance.fingerprint(tag, source)
            kernel_release = f"7.3.0-b{fingerprint[:10]}r123a1-xanmod1"
            for kind in ("image", "headers"):
                (root / f"linux-{kind}-{kernel_release}_1-build99a1_amd64.deb").write_bytes(kind.encode())
            config = root / "config"
            config.write_text("CONFIG_TCP_CONG_BBR=y\n")
            command = [sys.executable, str(ROOT / "scripts/build_provenance.py"), "manifest",
                       "--profile", "standard", "--tag", tag, "--source-commit", source,
                       "--project-commit", "b" * 40, "--fingerprint", fingerprint,
                       "--kernel-release", kernel_release, "--compiler", "gcc test",
                       "--config", str(config), "--package-dir", str(root)]
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            manifest = json.loads(result.stdout)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(result.stdout)
            release_path = root / "release.json"
            default_body = root / "default.txt"
            default_body.write_text("default")
            release = {"body": "Existing notes", "assets": [
                {"name": value["name"], "size": value["size"], "state": "uploaded",
                 "digest": "sha256:" + value["sha256"]} for value in manifest["assets"].values()
            ]}
            release["assets"] = [asset for asset in release["assets"] if asset["name"] == manifest["assets"]["image"]["name"]]
            release_path.write_text(json.dumps(release))
            args = [sys.executable, str(ROOT / "scripts/build_provenance.py"), "release-body",
                    "--manifest", str(manifest_path), "--release", str(release_path), "--default-body", str(default_body)]
            incomplete = subprocess.run(args, capture_output=True, text=True)
            self.assertNotEqual(incomplete.returncode, 0)
            self.assertEqual(incomplete.stdout, "")
            entry = manifest["assets"]["headers"]
            release["assets"].append({"name": entry["name"], "size": entry["size"], "state": "uploaded",
                                      "digest": "sha256:" + entry["sha256"]})
            release_path.write_text(json.dumps(release))
            complete = subprocess.run(args, capture_output=True, text=True, check=True)
            self.assertIn("Existing notes", complete.stdout)
            self.assertEqual(provenance.manifest_from_release({"body": complete.stdout}), manifest)
            release["body"] = complete.stdout
            release_path.write_text(json.dumps(release))
            again = subprocess.run(args, capture_output=True, text=True, check=True)
            self.assertEqual(again.stdout.count(provenance.MARKER), 1)
            self.assertEqual(again.stdout.count("<!-- BBR_BUILD_INFO_START -->"), 1)


if __name__ == "__main__":
    unittest.main()
