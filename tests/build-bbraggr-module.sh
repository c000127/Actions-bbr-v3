#!/usr/bin/env bash
set -euo pipefail

# Build a temporary comparison module; it never installs or loads the module.
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <matching tcp_bbr.c> <matching tcp_dctcp.h> <new output directory>" >&2
    exit 2
fi
source_bbr=$1
source_dctcp=$2
output=$3
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
headers="/lib/modules/$(uname -r)/build"
[[ -f "$source_bbr" && -f "$source_dctcp" && -f "$headers/Module.symvers" ]] || {
    echo "Matching source files and the running kernel's headers are required." >&2
    exit 1
}
[[ ! -e "$output" ]] || { echo "Output path already exists: $output" >&2; exit 1; }
mkdir -p "$output"
output=$(cd "$output" && pwd)
cp "$source_bbr" "$output/tcp_bbr_aggr.c"
cp "$source_dctcp" "$output/tcp_dctcp.h"
python3 "$root_dir/scripts/apply-aggressive-bbr.py" "$output/tcp_bbr_aggr.c"

# Register a separate name, so test sockets can compare against the built-in
# bbr without changing the host's default congestion control.
python3 - "$output/tcp_bbr_aggr.c" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
source, count = re.subn(r'(\.name\s*=\s*)"bbr"', r'\1"bbraggr"', source)
if count != 1:
    raise SystemExit("Expected exactly one bbr congestion-control registration")
path.write_text(source, encoding="utf-8")
PY

printf 'obj-m := tcp_bbr_aggr.o\n' > "$output/Makefile"
make -C "$headers" M="$output" -j1 modules
echo "Comparison module: $output/tcp_bbr_aggr.ko"
echo "Loading it requires root and affects the running kernel; it does not change the default algorithm."
