"""Startup benchmark statistics, charting, scheduling, and process failures."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import bench_startup as bench


def fixture():
    return {
        "runs": 5, "warmup": 2, "cpu": "Fixture CPU & <test>", "date": "2026-01-02",
        "rows": [{"terminal": key, "label": label, "samples_ms": [10, 11, 12, 13, 100]}
                 for key, label in bench.SERIES.items()],
    }


class Statistics(unittest.TestCase):
    def test_quartiles_whiskers_and_outliers(self):
        summary = bench.summarize([100, 13, 10, 12, 11])
        self.assertEqual([summary[k] for k in ("q1_ms", "median_ms", "q3_ms")], [11, 12, 13])
        self.assertEqual(summary["whisker_low_ms"], 10)
        self.assertEqual(summary["whisker_high_ms"], 13)
        self.assertEqual(summary["outliers_ms"], [100])

    def test_single_and_constant_samples(self):
        for values in ([12], [12] * 100):
            summary = bench.summarize(values)
            self.assertEqual(summary["median_ms"], 12)
            self.assertEqual(summary["outliers_ms"], [])
            ticks = bench.log_ticks(12, 12)
            self.assertLess(ticks[0], 12)
            self.assertGreater(ticks[-1], 12)

    def test_invalid_samples(self):
        for values in ([], [0], [-1], [float("nan")], [float("inf")]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                bench.summarize(values)

    def test_extreme_tick_ranges(self):
        for low, high in ((0.001, 0.002), (1, 100000), (1000, 1000)):
            ticks = bench.log_ticks(low, high)
            self.assertLessEqual(ticks[0], low)
            self.assertGreaterEqual(ticks[-1], high)
            self.assertEqual(ticks, sorted(set(ticks)))


class Charts(unittest.TestCase):
    def test_svg_style_labels_and_escaping(self):
        svg = bench.chart(fixture())
        root = ET.fromstring(svg)
        content = " ".join(root.itertext())
        for label in ("Velocitty", "foot", "Monstar", "Lower is better", "Fixture CPU & <test>"):
            self.assertIn(label, content)
        self.assertIn(bench.style.SURFACE, svg)
        self.assertIn(bench.style.SERIES["velocitty"], svg)
        self.assertIn("not time to first frame", content)
        self.assertNotIn("nan", svg)

    def test_single_sample_chart(self):
        result = fixture()
        for row in result["rows"]:
            row["samples_ms"] = [10]
        ET.fromstring(bench.chart(result))

    def test_chart_only_does_not_launch_or_modify_results(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.json"
            original = json.dumps(fixture())
            path.write_text(original)
            with mock.patch.object(bench, "measure") as measure, \
                    mock.patch.object(bench.shutil, "which", return_value=None), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(bench.main(["--chart-only", "--out", directory]), 0)
            measure.assert_not_called()
            self.assertEqual(path.read_text(), original)
            ET.parse(Path(directory) / "chart.svg")


class Measurement(unittest.TestCase):
    def test_interleaved_rounds_and_excluded_warmups(self):
        args = type("Args", (), dict(velocitty="v", foot="f", monstar="m", runs=4,
                                    warmup=2, seed=0, timeout=10))()
        with mock.patch.object(bench, "resolve_binary", side_effect=lambda path: f"/bin/{path}"), \
                mock.patch.object(bench, "binary_metadata", return_value={}), \
                mock.patch.object(bench, "timed", side_effect=range(1, 19)) as timed, \
                contextlib.redirect_stdout(io.StringIO()):
            result = bench.measure(args)
        self.assertEqual(timed.call_count, 18)
        self.assertEqual(len(result["round_order"]), 4)
        for order in result["round_order"]:
            self.assertEqual(set(order), set(bench.SERIES))
        recorded = [sample for row in result["rows"] for sample in row["samples_ms"]]
        self.assertEqual(sorted(recorded), list(range(7, 19)))
        for row in result["rows"]:
            self.assertEqual(len(row["samples_ms"]), 4)
            self.assertEqual(row["command"][1:], ["-e", "/bin/true"])
        self.assertGreater(len({tuple(order) for order in result["round_order"]}), 1)

    def test_real_child_success_and_failure(self):
        self.assertGreater(bench.timed([sys.executable, "-c", "pass"], 5), 0)
        with self.assertRaisesRegex(RuntimeError, "exited 7: fixture failure"):
            bench.timed([sys.executable, "-c",
                         "import sys; sys.stderr.write('fixture failure'); sys.exit(7)"], 5)

    @unittest.skipUnless(sys.platform.startswith("linux"), "POSIX process groups")
    def test_timeout_kills_process_group(self):
        with mock.patch.object(bench.os, "killpg", wraps=bench.os.killpg) as killpg:
            with self.assertRaises(subprocess.TimeoutExpired):
                bench.timed([sys.executable, "-c", "import time; time.sleep(30)"], 0.05)
        self.assertEqual(killpg.call_count, 1)
        self.assertEqual(killpg.call_args.args[1], bench.signal.SIGKILL)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux measurement harness")
    def test_full_cli_with_fixture_executables(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            terminal = directory / "fixture-terminal"
            terminal.write_text(
                f"#!{sys.executable}\n"
                "import os, sys\n"
                "if sys.argv[1:] == ['--version']:\n"
                "    print('fixture version 1')\n"
                "else:\n"
                "    assert sys.argv[1] == '-e'\n"
                "    os.execv(sys.argv[2], sys.argv[2:])\n"
            )
            terminal.chmod(0o755)
            out = directory / "out"
            arguments = ["--runs", "2", "--warmup", "1", "--out", str(out)]
            for key in bench.SERIES:
                arguments += [f"--{key}", str(terminal)]
            real_which = bench.shutil.which
            with mock.patch.dict(bench.os.environ, {"WAYLAND_DISPLAY": "fixture-no-display"}), \
                    mock.patch.object(bench.shutil, "which", side_effect=lambda value:
                                      None if value == "rsvg-convert" else real_which(value)), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(bench.main(arguments), 0)
            result = json.loads((out / "results.json").read_text())
            self.assertEqual(result["runs"], 2)
            for row in result["rows"]:
                self.assertEqual(len(row["samples_ms"]), 2)
                self.assertEqual(len(row["binary"]["sha256"]), 64)
                self.assertGreater(row["summary"]["median_ms"], 0)
            ET.parse(out / "chart.svg")

    def test_missing_binary_before_launch(self):
        with self.assertRaisesRegex(ValueError, "executable not found"):
            bench.resolve_binary("/does/not/exist/fixture-terminal")

    def test_invalid_cli_values(self):
        for flag, value in (("--runs", "0"), ("--runs", "-1"), ("--warmup", "-1"),
                            ("--timeout", "0"), ("--timeout", "nan"), ("--timeout", "inf")):
            with self.subTest(flag=flag, value=value), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    bench.main([flag, value])
                self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
