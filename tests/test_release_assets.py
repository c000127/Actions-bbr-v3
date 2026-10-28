#!/usr/bin/env python3
"""Exercise the installer asset selector with real jq and Release fixtures."""

import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = (ROOT / "install.sh").read_text(encoding="utf-8")
SELECTOR = SCRIPT[SCRIPT.index("get_release_assets() {"):SCRIPT.index("\nconfigure_aggressive_bbr() {")]
TAG = "x86_64-7.3.0"


def asset(name, size=10):
    return {"name": name, "state": "uploaded", "size": size, "browser_download_url": "https://example.test/" + name}


def select(release, arch="x86_64"):
    return subprocess.run(["bash", "-c", 'UI_RED="" UI_RESET="" ARCH="$3"\n' + SELECTOR + '\nget_release_assets "$1" "$2"',
                           "_", release["tag_name"], json.dumps([release]), arch], capture_output=True, text=True)


class ReleaseAssetsTest(unittest.TestCase):
    def test_legacy_arm64_release_keeps_its_architecture(self):
        names = ["linux-image-7.3.0-xanmod1_1_arm64.deb", "linux-headers-7.3.0-xanmod1_1_arm64.deb",
                 "linux-image-7.3.0-xanmod2_1_amd64.deb"]
        result = select({"tag_name": "arm64-7.3.0", "body": "legacy", "assets": [asset(name) for name in names]}, "aarch64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(names[0], result.stdout)
        self.assertIn(names[1], result.stdout)
        self.assertNotIn(names[2], result.stdout)

    def test_legacy_release_ignores_incomplete_staged_uploads(self):
        names = ["linux-image-7.3.0-xanmod1_1_amd64.deb", "linux-headers-7.3.0-xanmod1_1_amd64.deb",
                 "linux-image-7.3.0-xanmod2_1-build99a1_amd64.deb"]
        result = select({"tag_name": TAG, "body": "old notes", "assets": [asset(name) for name in names]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(names[0], result.stdout)
        self.assertIn(names[1], result.stdout)
        self.assertNotIn(names[2], result.stdout)

    def test_manifest_selects_only_the_verified_pair(self):
        image = "linux-image-7.3.0-xanmod1_1-build99a1_amd64.deb"
        headers = "linux-headers-7.3.0-xanmod1_1-build99a1_amd64.deb"
        manifest = {"schema": 1, "assets": {
            "image": {"name": image, "size": 10, "sha256": "a" * 64},
            "headers": {"name": headers, "size": 10, "sha256": "b" * 64},
        }}
        release = {"tag_name": TAG, "body": f"<!-- BBR_BUILD_V1 {json.dumps(manifest)} -->",
                   "assets": [asset(image), asset(headers), asset("linux-image-7.3.0-xanmod1_1_amd64.deb"),
                              asset("linux-image-7.3.0-xanmod1_1-build100a1_amd64.deb")]}
        result = select(release)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [f"https://example.test/{image}\t" + "a" * 64,
                                                       f"https://example.test/{headers}\t" + "b" * 64])
        release["assets"].pop(1)
        self.assertNotEqual(select(release).returncode, 0)


if __name__ == "__main__":
    unittest.main()
