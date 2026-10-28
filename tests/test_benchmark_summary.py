#!/usr/bin/env python3
"""Exercise real benchmark-summary parsing with incomplete and valid runs."""

import csv
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SUMMARY = Path(__file__).resolve().parent / "summarize-bbr-loss.py"


class BenchmarkSummaryTest(unittest.TestCase):
    def test_partial_and_inconsistent_samples_do_not_enter_medians(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid = {
                "end": {
                    "sender_tcp_congestion": "bbr",
                    "sum_sent": {"bytes": 100, "retransmits": 2},
                    "sum_received": {"bytes": 90, "bits_per_second": 1_000_000},
                    "streams": [{"sender": {"mean_rtt": 100_000}}],
                }
            }
            partial = json.loads(json.dumps(valid))
            del partial["end"]["sum_sent"]["retransmits"]
            inconsistent = json.loads(json.dumps(valid))
            inconsistent["end"]["sum_sent"]["bytes"] = 0
            for name, result in (("valid", valid), ("partial", partial), ("inconsistent", inconsistent)):
                (root / f"{name}.json").write_text(json.dumps(result), encoding="utf-8")
            with (root / "results.tsv").open("w", newline="", encoding="utf-8") as file:
                writer = csv.writer(file, delimiter="\t")
                writer.writerow(["scenario", "algo", "exit_code", "json"])
                for name in ("valid", "partial", "inconsistent"):
                    writer.writerow(["single", "bbr", 0, f"{name}.json"])
            result = subprocess.run(["python3", str(SUMMARY), str(root)], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines()[1], "single\tbbr\t1\t2\t1.000\t2.000\t100.000")

    def test_incomplete_shared_pair_is_not_reported_as_competition(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = {"end": {"sender_tcp_congestion": "bbr", "sum_sent": {"bytes": 100, "retransmits": 2},
                              "sum_received": {"bytes": 90, "bits_per_second": 1_000_000}}}
            (root / "one.json").write_text(json.dumps(result), encoding="utf-8")
            (root / "two.json").write_text(json.dumps({"error": "connection failed"}), encoding="utf-8")
            with (root / "results.tsv").open("w", newline="", encoding="utf-8") as file:
                writer = csv.writer(file, delimiter="\t")
                writer.writerow(["scenario", "algo", "repeat", "exit_code", "json"])
                writer.writerow(["shared_total_50", "bbr", 1, 0, "one.json"])
                writer.writerow(["shared_total_50", "reno", 1, 1, "two.json"])
            output = subprocess.run(["python3", str(SUMMARY), str(root)], capture_output=True, text=True, check=True).stdout
            self.assertIn("shared_total_50\tbbr\t0\t1\tn/a", output)
            self.assertIn("shared_total_50\treno\t0\t1\tn/a", output)


if __name__ == "__main__":
    unittest.main()
