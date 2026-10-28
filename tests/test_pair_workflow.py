#!/usr/bin/env python3
"""Exercise the actual pair-workflow discovery step with fake upstream APIs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/build-pair.yml"
SOURCE = "a" * 40
import sys
sys.path.insert(0, str(ROOT / "scripts"))
from build_provenance import fingerprint


def discovery_step():
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "id: plan")
    start = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |")
    result = []
    for line in lines[start + 1:]:
        if not line.strip():
            result.append("")
        elif line.startswith("          "):
            result.append(line[10:])
        else:
            break
    return "\n".join(result) + "\n"


def published(kernel_release):
    build_id = fingerprint("7.3.0-xanmod1", SOURCE)
    if "-aggressive-xanmod" in kernel_release:
        kernel_release = kernel_release.replace("-aggressive-xanmod", f"-b{build_id[:10]}r123a1-aggressive-xanmod")
    else:
        kernel_release = kernel_release.replace("-xanmod", f"-b{build_id[:10]}r123a1-xanmod")
    assets = [{"name": f"linux-{kind}-{kernel_release}_1_amd64.deb", "state": "uploaded", "size": 1}
              for kind in ("image", "headers")]
    manifest = {"schema": 1, "profile": "aggressive" if "-aggressive-" in kernel_release else "standard",
                "source_tag": "7.3.0-xanmod1", "source_commit": SOURCE, "project_commit": "b" * 40,
                "fingerprint": build_id, "kernel_release": kernel_release,
                "assets": {kind: {"name": assets[i]["name"], "size": 1, "sha256": "c" * 64}
                           for i, kind in enumerate(("image", "headers"))}}
    return {"draft": False, "assets": assets, "body": f"<!-- BBR_BUILD_V1 {json.dumps(manifest)} -->"}


class PairWorkflowTest(unittest.TestCase):
    def run_discovery(self, *, standard=None, aggressive=None, status="200", force=False, tag="7.3.0-xanmod1"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mock_bin = root / "bin"
            mock_bin.mkdir()
            (root / "standard.json").write_text(json.dumps(standard))
            (root / "aggressive.json").write_text(json.dumps(aggressive))
            scripts = {
                "git": "#!/bin/sh\ncase \"$*\" in *'^{}'*) exit 0;; esac\nprintf '%s refs/tags/%s\\n' \"$MOCK_SHA\" \"$MOCK_TAG\"\n",
                "sleep": "#!/bin/sh\nexit 0\n",
                "curl": """#!/bin/sh
out= url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    */aggressive-x86_64-*) cp "$MOCK_AGGRESSIVE" "$out" ;;
    */x86_64-*) cp "$MOCK_STANDARD" "$out" ;;
    *) exit 2 ;;
esac
printf '%s' "$MOCK_STATUS"
""",
            }
            for name, text in scripts.items():
                path = mock_bin / name
                path.write_text(text)
                path.chmod(0o755)
            output = root / "github_output"
            env = os.environ.copy()
            env.update(
                PATH=str(mock_bin) + os.pathsep + env["PATH"],
                MOCK_TAG=tag,
                MOCK_SHA=SOURCE,
                MOCK_STATUS=status,
                MOCK_STANDARD=str(root / "standard.json"),
                MOCK_AGGRESSIVE=str(root / "aggressive.json"),
                RUNNER_TEMP=str(root),
                GITHUB_OUTPUT=str(output),
                GITHUB_API_URL="https://api.github.test",
                GITHUB_REPOSITORY="owner/repository",
                GH_TOKEN="test-only",
                FORCE_BUILD="true" if force else "false",
            )
            result = subprocess.run(["bash", "-c", discovery_step()], cwd=ROOT, env=env,
                                    text=True, capture_output=True, timeout=15)
            lines = output.read_text().splitlines() if output.exists() else []
            return result, dict(line.split("=", 1) for line in lines)

    def test_both_missing_builds_both_at_the_same_tag(self):
        result, values = self.run_discovery(status="404")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["tag"], "7.3.0-xanmod1")
        self.assertEqual((values["build_standard"], values["build_aggressive"]), ("true", "true"))

    def test_existing_standard_release_only_builds_the_missing_variant(self):
        result, values = self.run_discovery(standard=published("7.3.0-xanmod1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((values["build_standard"], values["build_aggressive"]), ("false", "true"))

    def test_force_rebuilds_both_complete_releases(self):
        result, values = self.run_discovery(standard=published("7.3.0-xanmod1"),
                                            aggressive=published("7.3.0-aggressive-xanmod1"), force=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((values["build_standard"], values["build_aggressive"]), ("true", "true"))

    def test_api_error_and_invalid_tag_fail_closed(self):
        result, values = self.run_discovery(status="403")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("build_standard", values)
        result, values = self.run_discovery(tag="7.3.0-malformed")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("build_standard", values)


if __name__ == "__main__":
    unittest.main()
