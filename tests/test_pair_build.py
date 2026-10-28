#!/usr/bin/env python3
"""Test release discovery and retry decisions without contacting GitHub."""

import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("pair_plan", ROOT / "scripts/plan-pair-build.py")
pair_plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair_plan)
SOURCE = "a" * 40
FINGERPRINT = "b" * 64
TAG = "7.3.0-xanmod1"


def plan(tag, standard, aggressive, force=False):
    return pair_plan.plan(tag, standard, aggressive, SOURCE, FINGERPRINT, force)


def release(kernel_release, *, image=True, headers=True, draft=False, tag=TAG):
    if "-aggressive-xanmod" in kernel_release:
        kernel_release = kernel_release.replace("-aggressive-xanmod", f"-b{FINGERPRINT[:10]}r123a1-aggressive-xanmod")
    else:
        kernel_release = kernel_release.replace("-xanmod", f"-b{FINGERPRINT[:10]}r123a1-xanmod")
    assets = []
    entries = {}
    for kind, included in (("image", image), ("headers", headers)):
        name = f"linux-{kind}-{kernel_release}_1_amd64.deb"
        entries[kind] = {"name": name, "size": 10, "sha256": "c" * 64}
        if included:
            assets.append({
                "name": name,
                "state": "uploaded",
                "size": 10,
            })
    manifest = {"schema": 1, "profile": "aggressive" if "-aggressive-" in kernel_release else "standard",
                "source_tag": tag, "source_commit": SOURCE, "project_commit": "d" * 40,
                "fingerprint": FINGERPRINT, "kernel_release": kernel_release, "assets": entries}
    return {"draft": draft, "assets": assets, "body": f"<!-- BBR_BUILD_V1 {json.dumps(manifest)} -->"}


class PairBuildTest(unittest.TestCase):
    def test_new_upstream_tag_builds_both_profiles(self):
        result = plan("7.3.0-xanmod1", None, None)
        self.assertEqual(result["build_standard"], "true")
        self.assertEqual(result["build_aggressive"], "true")
        self.assertEqual(result["tag"], "7.3.0-xanmod1")

    def test_retries_only_the_missing_or_incomplete_profile(self):
        standard = release("7.3.0-xanmod1")
        aggressive = release("7.3.0-aggressive-xanmod1", headers=False)
        result = plan("7.3.0-xanmod1", standard, aggressive)
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("false", "true"))

    def test_both_complete_are_skipped_unless_forced(self):
        standard = release("7.3.0-xanmod1")
        aggressive = release("7.3.0-aggressive-xanmod1")
        result = plan("7.3.0-xanmod1", standard, aggressive)
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("false", "false"))
        result = plan("7.3.0-xanmod1", standard, aggressive, force=True)
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("true", "true"))

    def test_new_xanmod_revision_is_not_mistaken_for_the_old_release(self):
        standard = release("7.3.0-xanmod1")
        aggressive = release("7.3.0-aggressive-xanmod1")
        result = plan("7.3.0-xanmod2", standard, aggressive)
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("true", "true"))

    def test_two_part_and_rc_versions_match_kernel_package_names(self):
        standard = release("7.3.0-rc2-xanmod1", tag="7.3-rc2-xanmod1")
        aggressive = release("7.3.0-rc2-aggressive-xanmod1", tag="7.3-rc2-xanmod1")
        result = plan("7.3-rc2-xanmod1", standard, aggressive)
        self.assertEqual(result["version"], "7.3-rc2")
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("false", "false"))

    def test_incomplete_asset_and_draft_are_not_treated_as_complete(self):
        standard = release("7.3.0-xanmod1")
        standard["assets"][0]["size"] = 0
        self.assertTrue(plan("7.3.0-xanmod1", standard, None)["build_standard"] == "true")
        with self.assertRaises(ValueError):
            plan("7.3.0-xanmod1", release("7.3.0-xanmod1", draft=True), None)

    def test_invalid_upstream_or_api_data_fails_closed(self):
        for tag in ("7.3.0-xanmod1\ninjected=true", "7.3.0", "7.3.0-xanmodx"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                plan(tag, None, None)
        with self.assertRaises(ValueError):
            plan("7.3.0-xanmod1", {"message": "bad credentials"}, None)

    def test_legacy_and_changed_build_inputs_are_rebuilt(self):
        legacy = release("7.3.0-xanmod1")
        legacy["body"] = "old release without a build identity"
        result = plan(TAG, legacy, release("7.3.0-aggressive-xanmod1"))
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("true", "false"))
        result = pair_plan.plan(TAG, release("7.3.0-xanmod1"), release("7.3.0-aggressive-xanmod1"), SOURCE, "e" * 64)
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("true", "true"))


if __name__ == "__main__":
    unittest.main()
