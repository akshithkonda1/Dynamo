#!/usr/bin/env python3
"""Tests for Tools/DynamoEQ/dynamo_tone_ai.py"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "Tools" / "DynamoEQ" / "dynamo_tone_ai.py"


def load():
    name = "dynamo_tone_ai"
    spec = importlib.util.spec_from_file_location(name, PATH)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


tone = load()


class TestToneAI(unittest.TestCase):
    def test_mozart_metadata_is_classical(self):
        v = tone.classify_features(
            tone.ToneFeatures(0.15, 0.3, 14, 0.06, 18, 0.05, 14000, 0.35),
            metadata_text="Mozart Piano Concerto classical orchestral",
        )
        self.assertEqual(v.genre, "classical")
        self.assertGreater(v.confidence, 0.3)
        self.assertIn("presence", v.eq_bias or {"presence": 0})

    def test_pop_metadata(self):
        v = tone.classify_features(
            tone.ToneFeatures(0.22, 0.32, 9, 0.09, 10, 0.08, 12000, 0.4),
            metadata_text="Dance Pop hit single",
        )
        self.assertEqual(v.genre, "pop")

    def test_speech(self):
        v = tone.classify_features(
            tone.ToneFeatures(0.1, 0.3, 10, 0.22, 12, 0.8, 8000, 0.5),
            metadata_text="Podcast interview",
        )
        self.assertEqual(v.genre, "speech")

    def test_bass_features_electronic_or_hiphop(self):
        v = tone.classify_features(
            tone.ToneFeatures(0.48, 0.18, 6.5, 0.07, 7.0, 0.04, 10000, 0.25),
            metadata_text=None,
        )
        self.assertIn(v.genre, ("electronic", "hiphop", "unknown", "ambient"))

    def test_train_synthetic_no_disk_audio(self):
        w = tone.train_weights(tone._synthetic_prototypes(), epochs=10, lr=0.4)
        self.assertEqual(len(w), len(tone.GENRES))
        self.assertEqual(len(w[0]), len(tone.FEATURE_KEYS))

    def test_genre_bias_mutates_bands(self):
        class B:
            def __init__(self, label, g):
                self.label = label
                self.gain_db = g

        bands = [B("punch", 0.0), B("presence", 0.0)]
        tone.apply_genre_bias_to_bands(bands, "pop", 0.5)
        self.assertNotEqual(bands[0].gain_db, 0.0)


if __name__ == "__main__":
    unittest.main()
