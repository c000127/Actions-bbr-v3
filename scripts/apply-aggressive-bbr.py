#!/usr/bin/env python3
"""Apply the isolated aggressive BBRv3 profile to a XanMod source file.

Fail closed if upstream changes any of the expected BBRv3 constructs; a build
must not publish a kernel with only some of the intended changes applied.
"""

import argparse
from pathlib import Path
import re
import sys


def replace_once(source: str, pattern: str, replacement: str, label: str) -> str:
    result, count = re.subn(pattern, replacement, source, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"{label}: expected one matching BBRv3 definition, found {count}")
    return result


def apply_profile(source: str) -> str:
    if not re.search(r"(?m)^#define\s+BBR_VERSION\s+3\s*$", source):
        raise ValueError("BBR_VERSION 3 was not found")
    if not re.search(r"(?m)^#define[ \t]+BBR_SCALE[ \t]+8(?:[ \t]*/\*[^\n]*\*/)?[ \t]*$", source):
        raise ValueError("unsupported BBR fixed-point scale")
    gain_bits = re.search(r"\bpacing_gain\s*:\s*(\d+)", source)
    if not gain_bits or 3 * (1 << 8) >= (1 << int(gain_bits.group(1))):
        raise ValueError("3x startup gain does not fit in the pacing_gain field")
    if not re.search(r"if\s*\(\s*bbr_param\(sk,\s*full_loss_cnt\)\s*&&", source):
        raise ValueError("cannot verify that a zero full_loss_cnt disables the STARTUP loss exit")

    source = replace_once(
        source,
        r"/\* We use a startup_pacing_gain of 4\*ln\(2\)[\s\S]*?\n \*/(?=\nstatic const int bbr_startup_pacing_gain)",
        "/* Aggressive profile: use a 3.0x STARTUP pacing gain. */",
        "startup pacing explanation",
    )
    source = replace_once(
        source,
        r"^static const int bbr_startup_pacing_gain\s*=\s*BBR_UNIT\s*\*\s*277\s*/\s*100\s*\+\s*1\s*;",
        "static const int bbr_startup_pacing_gain = BBR_UNIT * 3; /* aggressive: 3.0x */",
        "startup pacing gain",
    )
    source = replace_once(
        source,
        r"^(\s*)BBR_UNIT\s*,\s*/\* CRUISE:[^\n]*\*/",
        r"\1BBR_UNIT * 120 / 100,\t/* CRUISE: aggressive 1.2x */",
        "cruise pacing gain",
    )
    source = replace_once(
        source,
        r"^static const u32 bbr_loss_thresh\s*=\s*BBR_UNIT\s*\*\s*2\s*/\s*100\s*;[^\n]*",
        "static const u32 bbr_loss_thresh = BBR_UNIT * 25 / 100; /* aggressive: 25% */",
        "loss threshold",
    )
    source = replace_once(
        source,
        r"^static const u32 bbr_full_loss_cnt\s*=\s*6\s*;",
        "static const u32 bbr_full_loss_cnt = 0; /* disable loss-triggered STARTUP exit */",
        "STARTUP loss exit",
    )
    source = replace_once(
        source,
        r"^(#define\s+BBR_VERSION\s+3\s*)$",
        r"\1\n/* BBRV3_AGGRESSIVE_PROFILE: startup 3.0x, cruise 1.2x, loss 25% */",
        "profile marker",
    )
    return source


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="path to net/ipv4/tcp_bbr.c")
    args = parser.parse_args()
    try:
        original = args.source.read_text(encoding="utf-8")
        updated = apply_profile(original)
        args.source.write_text(updated, encoding="utf-8")
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"Aggressive BBRv3 profile was not applied: {exc}", file=sys.stderr)
        return 1
    print(f"Applied aggressive BBRv3 profile to {args.source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
