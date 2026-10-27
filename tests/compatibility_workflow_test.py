#!/usr/bin/env python3
"""Run the compatibility workflow's reporting steps against small fixtures."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/CompatibilityTest.yml"


def workflow_step(marker):
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == marker)
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


def run_step(script, cwd, env):
    return subprocess.run(
        ["bash", "-c", script], cwd=cwd, env=env, text=True, capture_output=True
    )


class CompatibilityWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env_file = self.root / "github_env"
        self.summary_file = self.root / "summary"
        self.env = os.environ.copy()
        self.env.update(GITHUB_ENV=str(self.env_file), GITHUB_STEP_SUMMARY=str(self.summary_file))

    def test_diff_continues_when_optional_symbols_are_absent(self):
        kernel = self.root / "kernel"
        (kernel / "net/ipv4").mkdir(parents=True)
        (kernel / "net/ipv4/tcp_bbr.c").write_text("int bbr_lt_bw_sampling;\n")
        bbr = self.root / "bbr_v3.c"
        bbr.write_text("/* no optional symbols */\n")
        script = workflow_step("id: diff_analysis").replace("/tmp/tcp_bbr_v3.c", str(bbr))

        result = run_step(script, kernel, self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 file changed", result.stdout)
        self.assertIn("RESULT_REPLACE=✅", self.env_file.read_text(encoding="utf-8"))

    def test_download_failures_are_reported_separately(self):
        mocks = self.root / "bin"
        mocks.mkdir()
        git = mocks / "git"
        git.write_text("#!/usr/bin/env bash\nexit 1\n")
        git.chmod(0o755)
        curl = mocks / "curl"
        curl.write_text(
            "#!/usr/bin/env bash\n"
            "while [[ $# -gt 0 ]]; do\n"
            '  if [[ "$1" == -o ]]; then shift; printf "no feature markers\\n" > "$1"; exit 0; fi\n'
            "  shift\n"
            "done\nexit 1\n"
        )
        curl.chmod(0o755)
        self.env["PATH"] = str(mocks) + os.pathsep + self.env["PATH"]

        kernel_script = workflow_step("id: download_kernel")
        kernel_script = kernel_script.replace("${{ matrix.branch }}", "mainline")
        kernel_script = kernel_script.replace("${{ matrix.version }}", "7.3")
        kernel_script = kernel_script.replace("${{ matrix.repo }}", "torvalds/linux")
        kernel_result = run_step(kernel_script, self.root, self.env)
        self.assertEqual(kernel_result.returncode, 0, kernel_result.stderr)

        bbr_script = workflow_step("id: download_bbr")
        bbr_script = bbr_script.replace("${{ env.GOOGLE_BBR_URL }}", "https://example.invalid/bbr.c")
        bbr_script = bbr_script.replace("/tmp/tcp_bbr_v3.c", str(self.root / "bbr.c"))
        bbr_result = run_step(bbr_script, self.root, self.env)
        self.assertEqual(bbr_result.returncode, 0, bbr_result.stderr)

        values = dict(line.split("=", 1) for line in self.env_file.read_text(encoding="utf-8").splitlines())
        self.assertIn("❌", values["RESULT_KERNEL_DOWNLOAD"])
        self.assertIn("⚠️", values["RESULT_BBR_DOWNLOAD"])
        self.assertEqual(values["BBR_SOURCE_READY"], "true")
        self.assertNotIn("KERNEL_SOURCE_READY", values)

        expressions = {
            "matrix.branch": "mainline",
            "matrix.version": "7.3",
            "env.RESULT_KERNEL_DOWNLOAD": values["RESULT_KERNEL_DOWNLOAD"],
            "env.RESULT_BBR_DOWNLOAD": values["RESULT_BBR_DOWNLOAD"],
            "env.RESULT_REPLACE": "⏭️ 跳过",
            "env.RESULT_COMPILE": "⏭️ 跳过",
            "env.RESULT_API_CHECK": "⏭️ 跳过",
            "env.ISSUES": "",
        }
        summary_script = workflow_step("- name: 📊 生成测试报告")
        summary_script = re.sub(
            r"\$\{\{\s*(.*?)\s*\}\}", lambda match: expressions[match.group(1)], summary_script
        )
        summary_result = run_step(summary_script, self.root, self.env)
        self.assertEqual(summary_result.returncode, 0, summary_result.stderr)
        summary = self.summary_file.read_text(encoding="utf-8")
        self.assertIn("内核源码下载 | ❌ 克隆失败", summary)
        self.assertIn("BBRv3 源码下载 | ⚠️", summary)
        self.assertIn("❌ 源码获取失败", summary)


if __name__ == "__main__":
    unittest.main()
