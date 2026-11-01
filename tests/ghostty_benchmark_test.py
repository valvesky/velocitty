"""Exact/text-skipping measurement modes and three-series Ghostty charts."""
import base64
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import bench_vs_ghostty as bench


def fixture(skipping=True):
    row = {"test": "ascii", "label": "ASCII & UTF-8", "bytes": bench.MIB}
    for key in bench.SERIES:
        if key != "velocitty_skip" or skipping:
            row[key] = {"cpu_mbps": 100, "wall_mbps": 50}
    return {
        "metric": "cpu", "rows": [row], "cpu": "Fixture CPU & <test>",
        "velocitty": "revision-dirty", "ghostty": "1.4.0", "grid": "120x80",
        "runs": 5, "date": "2026-01-02", "load_avg_1m": 1.0,
    }


class Charts(unittest.TestCase):
    def test_equal_rates_have_separate_lanes_and_aligned_values(self):
        root = ET.fromstring(bench.chart(fixture()))
        text = " ".join(root.itertext())
        for label in ("Velocitty exact", "Velocitty text skipping", "Ghostty", "--drop",
                      "no rendering/presentation", "Fixture CPU & <test>", "ASCII & UTF-8"):
            self.assertIn(label, text)
        bars = root.findall('{*}rect[@data-role="bar"]')
        self.assertEqual(len(bars), 3)
        self.assertEqual(len({b.attrib["width"] for b in bars}), 1)
        self.assertEqual(len({b.attrib["y"] for b in bars}), 3)
        self.assertEqual({b.attrib["data-series"] for b in bars}, set(bench.SERIES))
        values = [c for c in root.findall("{*}text") if c.text == "100.0 MB/s"]
        self.assertEqual(len(values), 3)
        self.assertEqual(len({c.attrib["x"] for c in values}), 1)
        self.assertIn("reference", text)

    def test_linear_bars_start_at_zero_and_preserve_rate_ratios(self):
        for metric in ("cpu", "wall"):
            with self.subTest(metric=metric):
                result = fixture()
                result["metric"] = metric
                for key, rate in zip(bench.SERIES, (100, 200, 300)):
                    result["rows"][0][key][f"{metric}_mbps"] = rate
                root = ET.fromstring(bench.chart(result))
                self.assertIn("linear scale from zero", " ".join(root.itertext()))
                bars = root.findall('{*}rect[@data-role="bar"]')
                self.assertEqual(len({b.attrib["x"] for b in bars}), 1)
                widths = [float(b.attrib["width"]) for b in bars]
                self.assertAlmostEqual(widths[1], 2 * widths[0], delta=0.2)
                self.assertAlmostEqual(widths[2], 3 * widths[0], delta=0.2)

    def test_each_workload_has_an_independent_linear_scale(self):
        result = fixture()
        other = fixture()["rows"][0]
        for row, multiplier in ((result["rows"][0], 1), (other, 1000)):
            for key, rate in zip(bench.SERIES, (100, 200, 300)):
                row[key]["cpu_mbps"] = rate * multiplier
        result["rows"].append(other)
        root = ET.fromstring(bench.chart(result))
        bars = root.findall('{*}rect[@data-role="bar"]')
        self.assertEqual([b.attrib["width"] for b in bars[:3]],
                         [b.attrib["width"] for b in bars[3:]])
        self.assertIn("compare bar lengths within each workload only", " ".join(root.itertext()))

    def test_legacy_exact_only_results_still_render(self):
        root = ET.fromstring(bench.chart(fixture(skipping=False)))
        self.assertEqual(len(root.findall('{*}rect[@data-role="bar"]')), 2)
        self.assertNotIn("Velocitty text skipping", " ".join(root.itertext()))

    def test_embedded_icons_and_only_skip_lightning_is_inverted(self):
        root = ET.fromstring(bench.chart(fixture()))
        symbols = root.findall("{*}defs/{*}symbol")
        self.assertEqual(len(symbols), 3)
        filenames = {"velocitty": "lightning.png", "velocitty_skip": "lightning-inverted.png", "ghostty": "ghost-emoji.png"}
        for symbol in symbols:
            key = symbol.attrib["id"].removeprefix("marker-")
            uri = symbol.find("{*}image").attrib["href"]
            self.assertTrue(uri.startswith("data:image/png;base64,"))
            png = base64.b64decode(uri.split(",", 1)[1])
            self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertEqual(png, (ROOT / "assets" / "benchmarks" / filenames[key]).read_bytes())
        for marker in root.findall("{*}use"):
            self.assertEqual(marker.attrib["href"], "#marker-" + marker.attrib["data-series"])
        self.assertNotEqual((ROOT / "assets/benchmarks/lightning.png").read_bytes(),
                            (ROOT / "assets/benchmarks/lightning-inverted.png").read_bytes())

    def test_inconsistent_modes_are_rejected(self):
        result = fixture()
        other = fixture(skipping=False)["rows"][0]
        result["rows"].append(other)
        with self.assertRaisesRegex(ValueError, "same benchmark modes"):
            bench.chart(result)

    def test_chart_only_preserves_measurements_and_does_not_run_benchmarks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.json"
            original = json.dumps(fixture())
            path.write_text(original)
            with mock.patch.object(sys, "argv", ["bench_vs_ghostty.py", "--chart-only", "--out", directory]), \
                    mock.patch.object(bench, "measure") as measure, \
                    mock.patch.object(bench.shutil, "which", return_value=None), \
                    contextlib.redirect_stdout(io.StringIO()):
                bench.main()
            measure.assert_not_called()
            self.assertEqual(path.read_text(), original)
            ET.parse(Path(directory) / "chart.svg")


class Measurement(unittest.TestCase):
    def test_exact_skip_and_ghostty_use_identical_payloads_and_rotating_order(self):
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(velocitty_bench="velocitty-bench", ghostty_bench="ghostty-bench",
                                   out=directory, reps=2, runs=3, metric="cpu")
            calls = []

            def dump(command, **kwargs):
                data = Path(command[-1])
                for key, _ in bench.TESTS:
                    with (data / f"kitten-{key}.bin").open("wb") as stream:
                        stream.truncate(bench.MIB)

            def timed(command):
                calls.append(command)
                cpu = 0.03 if command[0] == "ghostty-bench" else (0.01 if "--drop" in command else 0.02)
                return cpu, cpu * 2

            with mock.patch.object(bench, "run", side_effect=dump), \
                    mock.patch.object(bench, "timed", side_effect=timed), \
                    mock.patch.object(bench, "git_rev", return_value="revision-dirty"), \
                    mock.patch.object(bench, "ghostty_version", return_value="1.4.0"), \
                    contextlib.redirect_stdout(io.StringIO()):
                result = bench.measure(args)
            self.assertEqual(len(calls), len(bench.TESTS) * args.runs * 3)
            self.assertEqual(sum("--drop" in command for command in calls), len(bench.TESTS) * args.runs)
            for row in result["rows"]:
                self.assertEqual(set(row["round_order"][i][0] for i in range(args.runs)), set(bench.SERIES))
                payloads = {row[key]["command"][2] for key in bench.SERIES}
                self.assertEqual(len(payloads), 1)
                self.assertIn("--drop", row["velocitty_skip"]["command"])
                for key in ("velocitty", "ghostty"):
                    self.assertNotIn("--drop", row[key]["command"])
                self.assertEqual(row["velocitty"]["cpu_mbps"], 50)
                self.assertEqual(row["velocitty_skip"]["cpu_mbps"], 100)
                for key in bench.SERIES:
                    self.assertEqual(len(row[key]["samples"]), args.runs)


if __name__ == "__main__":
    unittest.main()
