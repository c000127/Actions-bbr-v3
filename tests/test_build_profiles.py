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
    def run_version_step(self, profile, arch="x86_64", requested=""):
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
                REQUESTED_XANMOD_TAG=requested,
                GITHUB_ENV=str(root / "github_env"),
            )
            result = subprocess.run(["bash", "-c", version_step()], env=env, text=True, capture_output=True)
            content = (root / "github_env").read_text(encoding="utf-8") if (root / "github_env").exists() else ""
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

    def test_coordinator_tag_is_used_for_each_profile(self):
        for profile in ("standard", "aggressive"):
            result, values = self.run_version_step(profile, requested="7.2.12-xanmod2")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(values["XANMOD_TAG"], "7.2.12-xanmod2")
            self.assertEqual(values["KERNEL_VERSION"], "7.2.12")

    def test_invalid_coordinator_tag_is_rejected(self):
        result, values = self.run_version_step("standard", requested="7.3.0-xanmod1\nOTHER=value")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("RELEASE_TAG", values)

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

    def test_missing_bbrv3_stops_before_build(self):
        lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
        start = next(i for i, line in enumerate(lines) if "验证 BBRv3 内置" in line)
        start = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |")
        body = []
        for line in lines[start + 1:]:
            if not line.strip():
                body.append("")
            elif line.startswith("          "):
                body.append(line[10:])
            else:
                break
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "net/ipv4/tcp_bbr.c"
            source.parent.mkdir(parents=True)
            env = dict(os.environ, GITHUB_ENV=str(root / "env"))
            source.write_text("#define BBR_VERSION 1\n")
            failed = subprocess.run(["bash", "-c", "\n".join(body)], cwd=root, env=env, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("无法确认 BBRv3", failed.stdout)
            source.write_text("#define BBR_VERSION 3\n")
            passed = subprocess.run(["bash", "-c", "\n".join(body)], cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(passed.returncode, 0, passed.stderr)

    def test_missing_required_effective_config_stops_build(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        start = text.index("          for required in ", text.index("# These are product guarantees"))
        end = text.index("          done", start) + len("          done")
        check = "\n".join(line[10:] for line in text[start:end].splitlines())
        required = ['CONFIG_TCP_CONG_BBR=y', 'CONFIG_DEFAULT_TCP_CONG="bbr"', 'CONFIG_NET_SCH_FQ=y',
                    'CONFIG_DEFAULT_NET_SCH="fq"', 'CONFIG_DEBUG_INFO_BTF=y']
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / ".config"
            config.write_text("\n".join(required) + "\n")
            passed = subprocess.run(["bash", "-c", check], cwd=directory, capture_output=True, text=True)
            self.assertEqual(passed.returncode, 0, passed.stderr)
            config.write_text("\n".join(required[:-1]) + "\n")
            failed = subprocess.run(["bash", "-c", check], cwd=directory, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("CONFIG_DEBUG_INFO_BTF=y", failed.stdout)


if __name__ == "__main__":
    unittest.main()
