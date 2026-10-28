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
    samples = []
    with (root / "results.tsv").open(encoding="utf-8", newline="") as file:
        for row in csv.DictReader(file, delimiter="\t"):
            sample = None
            try:
                result = json.loads((root / row["json"]).read_text(encoding="utf-8"))
                if row["exit_code"] != "0" or result.get("error"):
                    raise ValueError(result.get("error", "iperf3 failed"))
                end = result["end"]
                if end.get("sender_tcp_congestion") != row["algo"]:
                    raise ValueError("iperf3 did not use the requested sender congestion control")
                sent = end["sum_sent"]
                received = end["sum_received"]
                goodput = received["bits_per_second"] / 1_000_000
                retrans = sent["retransmits"]
                if received["bytes"] > 0 and sent["bytes"] == 0:
                    raise ValueError("received data without sender bytes in the measurement interval")
                rtts = [stream["sender"].get("mean_rtt") for stream in end.get("streams", [])]
                valid_rtts = [value / 1000 for value in rtts if value is not None]
                sample = (goodput, retrans, valid_rtts)
            except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
                pass
            samples.append([row, sample])

    # A shared test only represents competition if both connections completed.
    # Exclude both sides of an incomplete or inconsistent pair.
    shared = {}
    for item in samples:
        row = item[0]
        if row["scenario"].startswith("shared"):
            shared.setdefault((row["scenario"], row.get("repeat")), []).append(item)
    for pair in shared.values():
        if len(pair) != 2 or any(item[1] is None for item in pair):
            for item in pair:
                item[1] = None

    for row, sample in samples:
        key = (row["scenario"], row["algo"])
        group = groups.setdefault(key, {"goodput": [], "retrans": [], "rtt": [], "failed": 0})
        if sample is None:
            group["failed"] += 1
        else:
            goodput, retrans, rtts = sample
            group["goodput"].append(goodput)
            group["retrans"].append(retrans)
            group["rtt"].extend(rtts)

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
