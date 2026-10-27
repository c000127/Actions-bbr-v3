#!/usr/bin/env python3
"""Test release discovery and retry decisions without contacting GitHub."""

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("pair_plan", ROOT / "scripts/plan-pair-build.py")
pair_plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair_plan)


def release(kernel_release, *, image=True, headers=True, draft=False):
    assets = []
    for kind, included in (("image", image), ("headers", headers)):
        if included:
            assets.append({
                "name": f"linux-{kind}-{kernel_release}_1_amd64.deb",
                "state": "uploaded",
                "size": 10,
            })
    return {"draft": draft, "assets": assets}


class PairBuildTest(unittest.TestCase):
    def test_new_upstream_tag_builds_both_profiles(self):
        result = pair_plan.plan("7.3.0-xanmod1", None, None)
        self.assertEqual(result["build_standard"], "true")
        self.assertEqual(result["build_aggressive"], "true")
        self.assertEqual(result["tag"], "7.3.0-xanmod1")

    def test_retries_only_the_missing_or_incomplete_profile(self):
        standard = release("7.3.0-xanmod1")
        aggressive = release("7.3.0-aggressive-xanmod1", headers=False)
        result = pair_plan.plan("7.3.0-xanmod1", standard, aggressive)
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("false", "true"))

    def test_both_complete_are_skipped_unless_forced(self):
        standard = release("7.3.0-xanmod1")
        aggressive = release("7.3.0-aggressive-xanmod1")
        result = pair_plan.plan("7.3.0-xanmod1", standard, aggressive)
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("false", "false"))
        result = pair_plan.plan("7.3.0-xanmod1", standard, aggressive, force=True)
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("true", "true"))

    def test_new_xanmod_revision_is_not_mistaken_for_the_old_release(self):
        standard = release("7.3.0-xanmod1")
        aggressive = release("7.3.0-aggressive-xanmod1")
        result = pair_plan.plan("7.3.0-xanmod2", standard, aggressive)
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("true", "true"))

    def test_two_part_and_rc_versions_match_kernel_package_names(self):
        standard = release("7.3.0-rc2-xanmod1")
        aggressive = release("7.3.0-rc2-aggressive-xanmod1")
        result = pair_plan.plan("7.3-rc2-xanmod1", standard, aggressive)
        self.assertEqual(result["version"], "7.3-rc2")
        self.assertEqual((result["build_standard"], result["build_aggressive"]), ("false", "false"))

    def test_incomplete_asset_and_draft_are_not_treated_as_complete(self):
        standard = release("7.3.0-xanmod1")
        standard["assets"][0]["size"] = 0
        self.assertTrue(pair_plan.plan("7.3.0-xanmod1", standard, None)["build_standard"] == "true")
        with self.assertRaises(ValueError):
            pair_plan.plan("7.3.0-xanmod1", release("7.3.0-xanmod1", draft=True), None)

    def test_invalid_upstream_or_api_data_fails_closed(self):
        for tag in ("7.3.0-xanmod1\ninjected=true", "7.3.0", "7.3.0-xanmodx"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                pair_plan.plan(tag, None, None)
        with self.assertRaises(ValueError):
            pair_plan.plan("7.3.0-xanmod1", {"message": "bad credentials"}, None)


if __name__ == "__main__":
    unittest.main()
