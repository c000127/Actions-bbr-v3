#!/usr/bin/env python3
"""Verify that the aggressive profile is applied atomically and fail-closed."""

from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent.parent / "scripts/apply-aggressive-bbr.py"
SOURCE = """\
#define BBR_VERSION 3
#define BBR_SCALE 8 /* scaling factor */
struct bbr { u32 pacing_gain:10; };
/* We use a startup_pacing_gain of 4*ln(2) because it is the default.
 */
static const int bbr_startup_pacing_gain = BBR_UNIT * 277 / 100 + 1;
static const int bbr_pacing_gain[] = {
    BBR_UNIT * 5 / 4, /* UP */
    BBR_UNIT * 91 / 100, /* DOWN */
    BBR_UNIT, /* CRUISE: use the pipe */
    BBR_UNIT, /* REFILL */
};
static const u32 bbr_loss_thresh = BBR_UNIT * 2 / 100; /* 2% loss */
static const u32 bbr_full_loss_cnt = 6;
if (bbr_param(sk, full_loss_cnt) && is_loss) { handle_loss(); }
"""


class AggressiveProfileTest(unittest.TestCase):
    def run_profile(self, content):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tcp_bbr.c"
            path.write_text(content, encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), str(path)], text=True, capture_output=True
            )
            return result, path.read_text(encoding="utf-8")

    def test_expected_profile_preserves_other_gains(self):
        result, output = self.run_profile(SOURCE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BBRV3_AGGRESSIVE_PROFILE", output)
        self.assertIn("bbr_startup_pacing_gain = BBR_UNIT * 3;", output)
        self.assertIn("BBR_UNIT * 120 / 100,", output)
        self.assertIn("bbr_loss_thresh = BBR_UNIT * 25 / 100;", output)
        self.assertIn("bbr_full_loss_cnt = 0;", output)
        self.assertIn("BBR_UNIT * 5 / 4, /* UP */", output)
        self.assertIn("BBR_UNIT * 91 / 100, /* DOWN */", output)

    def test_changed_upstream_is_rejected_without_partial_write(self):
        changed = SOURCE.replace("bbr_full_loss_cnt = 6", "bbr_full_loss_cnt = 7")
        result, output = self.run_profile(changed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STARTUP loss exit", result.stderr)
        self.assertEqual(output, changed)

    def test_gain_must_fit_the_kernel_bitfield(self):
        changed = SOURCE.replace("pacing_gain:10", "pacing_gain:9")
        result, output = self.run_profile(changed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not fit", result.stderr)
        self.assertEqual(output, changed)

    def test_non_v3_source_is_rejected_without_a_write(self):
        changed = SOURCE.replace("BBR_VERSION 3", "BBR_VERSION 1")
        result, output = self.run_profile(changed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BBR_VERSION 3 was not found", result.stderr)
        self.assertEqual(output, changed)

    def test_duplicate_cruise_definitions_are_rejected(self):
        changed = SOURCE.replace(
            "    BBR_UNIT, /* REFILL */", "    BBR_UNIT, /* CRUISE: unexpected */"
        )
        result, output = self.run_profile(changed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cruise pacing gain", result.stderr)
        self.assertEqual(output, changed)


if __name__ == "__main__":
    unittest.main()
