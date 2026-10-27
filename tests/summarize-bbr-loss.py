#!/usr/bin/env python3
"""Summarize receiver goodput and retransmissions from an isolated loss run."""

import csv
import json
from pathlib import Path
import statistics
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} <results directory>")
    root = Path(sys.argv[1])
    groups = {}
    with (root / "results.tsv").open(encoding="utf-8", newline="") as file:
        for row in csv.DictReader(file, delimiter="\t"):
            key = (row["scenario"], row["algo"])
            group = groups.setdefault(key, {"goodput": [], "retrans": [], "rtt": [], "failed": 0})
            try:
                result = json.loads((root / row["json"]).read_text(encoding="utf-8"))
                if row["exit_code"] != "0" or result.get("error"):
                    raise ValueError(result.get("error", "iperf3 failed"))
                end = result["end"]
                if end.get("sender_tcp_congestion") != row["algo"]:
                    raise ValueError("iperf3 did not use the requested sender congestion control")
                group["goodput"].append(end["sum_received"]["bits_per_second"] / 1_000_000)
                group["retrans"].append(end["sum_sent"]["retransmits"])
                rtts = [stream["sender"].get("mean_rtt") for stream in end.get("streams", [])]
                group["rtt"].extend(value / 1000 for value in rtts if value is not None)
            except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
                group["failed"] += 1

    print("scenario\talgorithm\tsuccesses\tfailed\tmedian_receiver_Mbps\tmedian_retransmissions\tmedian_RTT_ms")
    for (scenario, algorithm), group in groups.items():
        def median_or_na(values):
            return f"{statistics.median(values):.3f}" if values else "n/a"

        print(
            f"{scenario}\t{algorithm}\t{len(group['goodput'])}\t{group['failed']}\t"
            f"{median_or_na(group['goodput'])}\t{median_or_na(group['retrans'])}\t{median_or_na(group['rtt'])}"
        )


if __name__ == "__main__":
    main()
