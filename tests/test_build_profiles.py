#!/usr/bin/env python3
"""Exercise the build workflow's release and cache isolation on fixtures."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/build.yml"


def version_step():
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "id: get_kernel_version")
    start = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |")
    result = []
    for line in lines[start + 1 :]:
        if not line.strip():
            result.append("")
        elif line.startswith("          "):
            result.append(line[10:])
        else:
            break
    return "\n".join(result) + "\n"


class BuildProfilesTest(unittest.TestCase):
    def run_version_step(self, profile, arch="x86_64"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mock_bin = root / "bin"
            mock_bin.mkdir()
            git = mock_bin / "git"
            git.write_text("#!/bin/sh\nprintf 'abc refs/tags/7.3.0-xanmod1\\n'\n")
            git.chmod(0o755)
            env = os.environ.copy()
            env.update(
                PATH=str(mock_bin) + os.pathsep + env["PATH"],
                PROFILE=profile,
                ARCH=arch,
                GITHUB_ENV=str(root / "github_env"),
            )
            result = subprocess.run(["bash", "-c", version_step()], env=env, text=True, capture_output=True)
            content = (root / "github_env").read_text(encoding="utf-8")
            values = dict(line.split("=", 1) for line in content.splitlines())
            return result, values

    def test_standard_and_aggressive_release_and_cache_names_do_not_overlap(self):
        standard, normal = self.run_version_step("standard")
        aggressive, experimental = self.run_version_step("aggressive")
        self.assertEqual(standard.returncode, 0, standard.stderr)
        self.assertEqual(aggressive.returncode, 0, aggressive.stderr)
        self.assertEqual(normal["RELEASE_TAG"], "x86_64-7.3.0")
        self.assertEqual(experimental["RELEASE_TAG"], "aggressive-x86_64-7.3.0")
        self.assertEqual(normal["CACHE_PREFIX"], "ccache-x86_64-7.3-")
        self.assertEqual(experimental["CACHE_PREFIX"], "ccache-aggressive-x86_64-7.3-")
        self.assertFalse(experimental["CACHE_PREFIX"].startswith(normal["CACHE_PREFIX"]))

    def test_aggressive_arm_build_is_rejected_before_publication(self):
        result, values = self.run_version_step("aggressive", "arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("RELEASE_TAG", values)
        self.assertNotIn("CACHE_PREFIX", values)

    def test_standalone_config_keeps_the_existing_virtualization_options(self):
        standard = (ROOT / "x86-64.config").read_text(encoding="utf-8")
        aggressive = (ROOT / "x86-64-aggressive.config").read_text(encoding="utf-8")
        self.assertEqual(
            aggressive.splitlines(),
            standard.replace('CONFIG_LOCALVERSION=""', 'CONFIG_LOCALVERSION="-aggressive"', 1).splitlines(),
        )


if __name__ == "__main__":
    unittest.main()
