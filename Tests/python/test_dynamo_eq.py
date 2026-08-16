#!/usr/bin/env python3
"""
Unit tests for Tools/DynamoEQ/dynamo_eq.py

Run:
  python3 -m unittest Tests/python/test_dynamo_eq.py -v
  # or via scripts/test.sh
"""

from __future__ import annotations

import importlib.util
import math
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EQ_PATH = ROOT / "Tools" / "DynamoEQ" / "dynamo_eq.py"


def load_eq():
    # Register module before exec so dataclasses (Python 3.14) can resolve __module__.
    name = "dynamo_eq"
    spec = importlib.util.spec_from_file_location(name, EQ_PATH)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


eq = load_eq()


class TestBiquad(unittest.TestCase):
    def test_impulse_stable(self):
        f = eq._peaking(48000, 1000, 6.0, 1.0)
        peak = 0.0
        for i in range(4096):
            x = 1.0 if i == 0 else 0.0
            y = f.process(x)
            peak = max(peak, abs(y))
        self.assertLess(peak, 4.0)

    def test_clone_independent_state(self):
        a = eq._peaking(48000, 500, 3.0, 0.9)
        b = a.clone()
        a.process(0.5)
        self.assertNotEqual(a.z1, b.z1)


class TestProfiles(unittest.TestCase):
    def test_all_base_profiles_build(self):
        for name in eq.BASE_PROFILES:
            bands, makeup, report = eq.build_adaptive_bands(name, "auto", None, 1.0)
            self.assertGreaterEqual(len(bands), 4)
            self.assertGreater(makeup, 0)
            filters = eq.bands_to_filters(bands, 48000)
            self.assertEqual(len(filters), len(bands))
            self.assertEqual(report["profile"], name)

    def test_device_bias_changes_gains(self):
        base, _, _ = eq.build_adaptive_bands("symphony", "auto", None, 1.0)
        phones, _, r = eq.build_adaptive_bands("symphony", "headphones", None, 1.0)
        self.assertEqual(r["device"], "headphones")
        # At least one band gain should differ after headphones bias
        diffs = [abs(a.gain_db - b.gain_db) for a, b in zip(base, phones)]
        self.assertTrue(any(d > 0.05 for d in diffs))


def _tone(freq: float, seconds: float = 0.4, sr: float = 48000, amp: float = 0.2):
    n = int(sr * seconds)
    return [amp * math.sin(2 * math.pi * freq * i / sr) for i in range(n)]


class TestAnalysis(unittest.TestCase):
    def test_speech_like_high_zcr(self):
        # Broadband-ish: mix of mid frequencies
        sr = 48000
        mono = []
        for i in range(int(sr * 0.5)):
            t = i / sr
            mono.append(0.1 * math.sin(2 * math.pi * 800 * t) + 0.05 * math.sin(2 * math.pi * 2200 * t))
        a = eq.analyze_mono(mono, sr)
        self.assertIn(a.media_type, eq.MEDIA_BIAS)
        self.assertIn(a.quality, ("high", "medium", "low"))
        self.assertTrue(0 <= a.quality_score <= 1)
        self.assertTrue(a.notes)

    def test_bass_heavy_classification(self):
        mono = _tone(60, amp=0.35) + _tone(90, amp=0.2)
        a = eq.analyze_mono(mono, 48000)
        self.assertGreater(a.bass_ratio, 0.15)
        self.assertIn(a.media_type, ("bass_heavy", "music", "bright", "sparse", "low_quality", "speech"))

    def test_note_suggestions_bounded(self):
        mono = _tone(440)
        a = eq.analyze_mono(mono, 48000)
        for n in a.notes:
            self.assertGreaterEqual(n["suggested_gain_db"], -3.5)
            self.assertLessEqual(n["suggested_gain_db"], 3.5)


class TestSymphonyCoeffs(unittest.TestCase):
    def test_coeffs_json_shape(self):
        payload = eq.coeffs_payload("symphony", 48000, "headphones", None, 1.0)
        self.assertEqual(payload["engine"], "DynamoEQ")
        self.assertEqual(payload["version"], 2)
        self.assertTrue(payload["spatial_safe"])
        self.assertIn("biquads", payload)
        self.assertGreaterEqual(len(payload["biquads"]), 5)
        self.assertGreater(payload["width"], 0)
        for b in payload["biquads"]:
            for k in ("b0", "b1", "b2", "a1", "a2"):
                self.assertIn(k, b)

    def test_adaptive_with_analysis(self):
        mono = _tone(110) + _tone(2000, amp=0.05)
        analysis = eq.analyze_mono(mono, 48000)
        payload = eq.coeffs_payload("symphony", 48000, "wireless", analysis, 1.0)
        self.assertEqual(payload["device"], "wireless")
        self.assertIsNotNone(payload["analysis"])

    def test_process_stereo_ms_length(self):
        # 10 stereo frames
        frames = []
        for i in range(10):
            frames.append(0.1 * math.sin(i))
            frames.append(0.1 * math.cos(i))
        raw = struct.pack("<" + "f" * len(frames), *frames)
        bands, makeup, report = eq.build_adaptive_bands("impact", "speakers", None, 1.0)
        fl = eq.bands_to_filters(bands, 48000)
        fr = [f.clone() for f in fl]
        out = eq.process_stereo_ms(raw, fl, fr, makeup, report["width"])
        self.assertEqual(len(out), len(raw))


class TestCLI(unittest.TestCase):
    def test_selftest_main(self):
        self.assertEqual(eq.main(["selftest"]), 0)

    def test_coeffs_main_exits_zero(self):
        # Capture stdout
        import io
        from contextlib import redirect_stdout

        buf = io.StringIO()
        with redirect_stdout(buf):
            code = eq.main(["coeffs", "--profile", "cinema", "--device", "auto", "--sr", "48000"])
        self.assertEqual(code, 0)
        self.assertIn("biquads", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
