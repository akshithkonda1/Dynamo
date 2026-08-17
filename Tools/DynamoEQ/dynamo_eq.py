#!/usr/bin/env python3
"""
DynamoEQ — local adaptive sound amplifier / optimizer / “symphony” engine.

Three jobs (no network, no cloud APIs, pure Python 3 stdlib):

  1. Amplify by **media type & quality** (speech / music / bass-heavy / sparse /
     dynamic-range / bandwidth estimate from PCM alone).
  2. Evaluate **how each spectral “note” region** should be lifted or tamed so
     the result sounds clearer and more musical than the source.
  3. Render a **device-aware immersive path** so headphones (wired/wireless),
     built-in speakers, or external speakers each get a concert-hall / “you
     are there” contour — without mono-folding Spatial/Atmos feeds.

**Seamless transitions (v3):**
  - Equal-power dual-path crossfades between profiles / devices
  - Soft wet fade-in / fade-out so engage never clicks
  - Band-gain morph helpers for offline previews of intermediate curves
  - Matches Dynamo LocalAmplifyEngine realtime behaviour (~90 ms profile, ~120 ms engage)

Realtime path: Dynamo’s LocalAmplifyEngine applies the exported biquads with the
same dual-bank crossfade + wet ramp.

Usage:
  python3 dynamo_eq.py selftest
  python3 dynamo_eq.py coeffs --profile cinema --device headphones --sr 48000
  python3 dynamo_eq.py analyze --sr 48000 < stereo.f32le
  python3 dynamo_eq.py symphony --device auto --sr 48000 < stereo.f32le
  python3 dynamo_eq.py process --profile impact --device speakers --sr 48000 < in > out
  python3 dynamo_eq.py process --from-profile cinema --profile symphony \\
      --transition-ms 90 --fade-in-ms 120 --sr 48000 < in > out
  python3 dynamo_eq.py morph --from-profile cinema --to-profile impact --steps 5
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from dataclasses import asdict, dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple


# ---------------------------------------------------------------------------
# Biquad (RBJ)
# ---------------------------------------------------------------------------


@dataclass
class Biquad:
    b0: float
    b1: float
    b2: float
    a1: float
    a2: float
    z1: float = 0.0
    z2: float = 0.0

    def process(self, x: float) -> float:
        y = self.b0 * x + self.z1
        self.z1 = self.b1 * x - self.a1 * y + self.z2
        self.z2 = self.b2 * x - self.a2 * y
        return y

    def reset(self) -> None:
        self.z1 = self.z2 = 0.0

    def clone(self) -> "Biquad":
        return Biquad(self.b0, self.b1, self.b2, self.a1, self.a2)


def _peaking(sr: float, freq: float, gain_db: float, q: float) -> Biquad:
    a = 10 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * min(0.49, max(1e-4, freq / sr))
    cos_w, sin_w = math.cos(w0), math.sin(w0)
    alpha = sin_w / (2.0 * max(q, 0.05))
    b0 = 1 + alpha * a
    b1 = -2 * cos_w
    b2 = 1 - alpha * a
    a0 = 1 + alpha / a
    a1 = -2 * cos_w
    a2 = 1 - alpha / a
    return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def _lowshelf(sr: float, freq: float, gain_db: float, q: float = 0.707) -> Biquad:
    a = 10 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * min(0.49, max(1e-4, freq / sr))
    cos_w, sin_w = math.cos(w0), math.sin(w0)
    alpha = sin_w / (2.0 * max(q, 0.05))
    t = 2 * math.sqrt(a) * alpha
    b0 = a * ((a + 1) - (a - 1) * cos_w + t)
    b1 = 2 * a * ((a - 1) - (a + 1) * cos_w)
    b2 = a * ((a + 1) - (a - 1) * cos_w - t)
    a0 = (a + 1) + (a - 1) * cos_w + t
    a1 = -2 * ((a - 1) + (a + 1) * cos_w)
    a2 = (a + 1) + (a - 1) * cos_w - t
    return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def _highshelf(sr: float, freq: float, gain_db: float, q: float = 0.707) -> Biquad:
    a = 10 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * min(0.49, max(1e-4, freq / sr))
    cos_w, sin_w = math.cos(w0), math.sin(w0)
    alpha = sin_w / (2.0 * max(q, 0.05))
    t = 2 * math.sqrt(a) * alpha
    b0 = a * ((a + 1) + (a - 1) * cos_w + t)
    b1 = -2 * a * ((a - 1) + (a + 1) * cos_w)
    b2 = a * ((a + 1) + (a - 1) * cos_w - t)
    a0 = (a + 1) - (a - 1) * cos_w + t
    a1 = 2 * ((a - 1) - (a + 1) * cos_w)
    a2 = (a + 1) - (a - 1) * cos_w - t
    return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


@dataclass
class BandSpec:
    kind: str  # peak | lowshelf | highshelf
    freq: float
    gain_db: float
    q: float = 0.9
    label: str = ""  # note-region name for analysis


# Intent bases — fidelity-capped (match LocalAmplifyEngine DynamoEQCurves)
BASE_PROFILES: Dict[str, List[BandSpec]] = {
    "reference": [
        BandSpec("lowshelf", 70, 0.4, 0.7, "sub"),
        BandSpec("peak", 700, -0.8, 1.0, "mud"),
        BandSpec("peak", 2200, 0.5, 1.0, "presence"),
        BandSpec("highshelf", 10000, 0.0, 0.7, "air"),
    ],
    "presence": [
        BandSpec("lowshelf", 90, -0.6, 0.7, "sub"),
        BandSpec("peak", 350, -0.6, 0.9, "body"),
        BandSpec("peak", 1800, 1.6, 1.1, "presence"),
        BandSpec("peak", 3500, 1.0, 1.0, "air"),
        BandSpec("highshelf", 8000, 0.6, 0.7, "brilliance"),
    ],
    "cinema": [
        BandSpec("lowshelf", 70, 1.2, 0.7, "sub"),
        BandSpec("peak", 250, 0.4, 0.9, "warmth"),
        BandSpec("peak", 900, -1.2, 1.0, "mud"),
        BandSpec("peak", 3200, 0.8, 1.0, "presence"),
        BandSpec("highshelf", 9000, 0.6, 0.7, "air"),
    ],
    "impact": [
        BandSpec("lowshelf", 60, 2.0, 0.7, "sub"),
        BandSpec("peak", 110, 1.5, 1.0, "punch"),
        BandSpec("peak", 220, 0.8, 1.0, "body"),
        BandSpec("peak", 800, -0.8, 0.9, "mud"),
        BandSpec("highshelf", 7000, 0.4, 0.7, "air"),
    ],
    "symphony": [
        BandSpec("lowshelf", 65, 0.9, 0.7, "sub"),
        BandSpec("peak", 180, 0.5, 0.95, "body"),
        BandSpec("peak", 700, -0.9, 1.0, "mud"),
        BandSpec("peak", 2200, 0.9, 1.05, "presence"),
        BandSpec("peak", 4500, 0.4, 1.0, "sheen"),
        BandSpec("highshelf", 10000, 0.5, 0.7, "air"),
    ],
}

# Mild device calibration (not aggressive immersive)
DEVICE_BIAS: Dict[str, Dict[str, float]] = {
    "headphones": {"sub": -0.3, "presence": 0.6, "air": 0.4, "mud": -0.3},
    "wireless": {"sub": 0.3, "presence": 0.5, "air": 0.35, "mud": -0.4, "punch": 0.3},
    "speakers": {"sub": 0.5, "body": 0.3, "mud": -0.5, "presence": 0.3, "air": -0.2},
    "external": {"mud": -0.2, "presence": 0.15},
    "auto": {},
}

# Media-type bias
MEDIA_BIAS: Dict[str, Dict[str, float]] = {
    "speech": {"sub": -2.0, "body": -0.5, "presence": 2.5, "air": 1.0, "mud": -1.5, "punch": -1.0, "sheen": 0.5, "brilliance": 0.8, "warmth": -0.5},
    "music": {"sub": 0.3, "body": 0.2, "presence": 0.5, "air": 0.4, "mud": -0.4, "punch": 0.3, "sheen": 0.3, "brilliance": 0.2, "warmth": 0.2},
    "bass_heavy": {"sub": 0.8, "body": 0.6, "presence": 0.2, "air": 0.3, "mud": -1.0, "punch": 1.0, "sheen": 0.0, "brilliance": -0.2, "warmth": 0.4},
    "bright": {"sub": 0.2, "body": 0.0, "presence": 0.3, "air": -0.8, "mud": -0.3, "punch": 0.2, "sheen": -0.5, "brilliance": -0.6, "warmth": 0.3},
    "sparse": {"sub": 0.0, "body": 0.4, "presence": 1.0, "air": 0.8, "mud": -0.5, "punch": 0.0, "sheen": 0.6, "brilliance": 0.5, "warmth": 0.2},
    "low_quality": {"sub": 0.5, "body": 0.3, "presence": 1.2, "air": -0.5, "mud": -1.2, "punch": 0.4, "sheen": -0.3, "brilliance": -0.8, "warmth": 0.6},  # tame harshness, fill body
}


# ---------------------------------------------------------------------------
# Analysis — media type & quality from PCM (no metadata APIs)
# ---------------------------------------------------------------------------


@dataclass
class MediaAnalysis:
    media_type: str
    quality: str  # high | medium | low
    quality_score: float  # 0..1
    dynamic_range_db: float
    bandwidth_hz: float
    crest_db: float
    speech_likelihood: float
    bass_ratio: float
    brightness: float
    notes: List[dict] = field(default_factory=list)  # per-region energy + suggested gain


def _rms(xs: Sequence[float]) -> float:
    if not xs:
        return 1e-12
    return math.sqrt(sum(x * x for x in xs) / len(xs)) + 1e-12


def _band_energy(samples: Sequence[float], sr: float, f_lo: float, f_hi: float) -> float:
    """Lightweight band energy via shelf cascade (no FFT dependency)."""
    hp = _highshelf(sr, f_lo, -18, 0.7)
    lp = _lowshelf(sr, f_hi, -18, 0.7)
    acc = 0.0
    for x in samples:
        y = hp.process(x)
        y = lp.process(y)
        acc += y * y
    return math.sqrt(acc / max(1, len(samples))) + 1e-12


NOTE_REGIONS = [
    ("sub", 40, 100),
    ("punch", 90, 160),
    ("body", 160, 400),
    ("mud", 400, 900),
    ("warmth", 200, 500),
    ("presence", 1500, 3500),
    ("sheen", 3500, 6500),
    ("air", 6500, 12000),
    ("brilliance", 8000, 14000),
]


def analyze_mono(samples: Sequence[float], sr: float) -> MediaAnalysis:
    n = len(samples)
    if n < 256:
        samples = list(samples) + [0.0] * (256 - n)
        n = len(samples)

    # Use up to ~3s for analysis
    max_n = min(n, int(sr * 3))
    step = max(1, max_n // 12000)
    mono = [samples[i] for i in range(0, max_n, step)]

    rms = _rms(mono)
    peak = max(abs(x) for x in mono) + 1e-12
    crest_db = 20 * math.log10(peak / rms)
    # Dynamic range proxy: high percentile vs low percentile of frame RMS
    frame = max(64, len(mono) // 40)
    frame_rms = []
    for i in range(0, len(mono) - frame, frame):
        frame_rms.append(_rms(mono[i : i + frame]))
    frame_rms.sort()
    if frame_rms:
        lo = frame_rms[max(0, len(frame_rms) // 20)]
        hi = frame_rms[min(len(frame_rms) - 1, (19 * len(frame_rms)) // 20)]
        dr_db = 20 * math.log10((hi + 1e-12) / (lo + 1e-12))
    else:
        dr_db = crest_db

    # Zero-crossing rate → speech-ish
    zc = 0
    for i in range(1, len(mono)):
        if (mono[i - 1] >= 0) != (mono[i] >= 0):
            zc += 1
    zcr = zc / max(1, len(mono))

    e_sub = _band_energy(mono, sr, 40, 120)
    e_mid = _band_energy(mono, sr, 300, 3000)
    e_high = _band_energy(mono, sr, 4000, 12000)
    e_all = e_sub + e_mid + e_high + 1e-12
    bass_ratio = e_sub / e_all
    brightness = e_high / e_all

    # Bandwidth: highest band with meaningful energy
    bandwidth = 4000.0
    for f_hi in (6000, 8000, 10000, 12000, 14000, 16000):
        if _band_energy(mono, sr, f_hi * 0.7, f_hi) > rms * 0.04:
            bandwidth = float(f_hi)

    speech_likelihood = min(1.0, max(0.0, (zcr - 0.05) * 4.0 + (0.35 - bass_ratio) * 1.5))
    if e_mid / e_all > 0.45 and bass_ratio < 0.25:
        speech_likelihood = min(1.0, speech_likelihood + 0.25)

    # Quality score from bandwidth + dynamic range + crest
    q = 0.0
    q += min(1.0, bandwidth / 14000.0) * 0.4
    q += min(1.0, dr_db / 24.0) * 0.35
    q += min(1.0, max(0.0, (crest_db - 6) / 14.0)) * 0.25
    if q >= 0.72:
        quality = "high"
    elif q >= 0.42:
        quality = "medium"
    else:
        quality = "low"

    if speech_likelihood > 0.55:
        media_type = "speech"
    elif bass_ratio > 0.38:
        media_type = "bass_heavy"
    elif brightness > 0.42:
        media_type = "bright"
    elif dr_db > 18 and bass_ratio < 0.22:
        media_type = "sparse"
    elif quality == "low":
        media_type = "low_quality"
    else:
        media_type = "music"

    # Per-note region evaluation
    notes = []
    target = {
        "sub": 0.18,
        "punch": 0.14,
        "body": 0.16,
        "mud": 0.10,
        "warmth": 0.14,
        "presence": 0.16,
        "sheen": 0.12,
        "air": 0.10,
        "brilliance": 0.08,
    }
    for label, lo, hi in NOTE_REGIONS:
        e = _band_energy(mono, sr, lo, hi)
        rel = e / (rms + 1e-12)
        tgt = target.get(label, 0.12)
        # Suggest dB to move region toward musical balance (gentle)
        if rel < 1e-6:
            delta = 0.0
        else:
            delta = 20 * math.log10(tgt / max(rel * 0.35, 1e-6)) * 0.22
        delta = max(-3.5, min(3.5, delta))
        notes.append(
            {
                "label": label,
                "f_lo": lo,
                "f_hi": hi,
                "energy": e,
                "relative": rel,
                "suggested_gain_db": round(delta, 2),
            }
        )

    return MediaAnalysis(
        media_type=media_type,
        quality=quality,
        quality_score=round(q, 3),
        dynamic_range_db=round(dr_db, 2),
        bandwidth_hz=bandwidth,
        crest_db=round(crest_db, 2),
        speech_likelihood=round(speech_likelihood, 3),
        bass_ratio=round(bass_ratio, 3),
        brightness=round(brightness, 3),
        notes=notes,
    )


# ---------------------------------------------------------------------------
# Adaptive profile build
# ---------------------------------------------------------------------------


def _apply_bias(bands: List[BandSpec], bias: Dict[str, float], scale: float = 1.0) -> None:
    for b in bands:
        key = b.label or ""
        if key in bias:
            b.gain_db = max(-8.0, min(7.0, b.gain_db + bias[key] * scale))


# Spatial / Atmos path keys (match AmplifySpatialPath.rawValue in Swift)
SPATIAL_PATHS = ("stereo", "spatialBinaural", "atmosBed", "multichannel", "stereoMixFallback")

# Per-profile max |gain| dB and default makeup
PROFILE_CAPS = {
    "reference": (1.5, 0.12),
    "symphony": (1.8, 0.18),
    "presence": (2.0, 0.20),
    "cinema": (2.0, 0.20),
    "impact": (2.5, 0.25),
}


def _load_tone_ai():
    """Import on-device genre AI from the same folder (optional)."""
    try:
        import importlib.util
        from pathlib import Path

        path = Path(__file__).resolve().parent / "dynamo_tone_ai.py"
        if not path.is_file():
            return None
        name = "dynamo_tone_ai"
        spec = importlib.util.spec_from_file_location(name, path)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


def build_adaptive_bands(
    profile: str,
    device: str,
    analysis: Optional[MediaAnalysis],
    intensity: float = 1.0,
    path: str = "stereo",
    genre: Optional[str] = None,
    metadata_text: Optional[str] = None,
) -> Tuple[List[BandSpec], float, dict]:
    """
    Fidelity-capped intent + mild device calibration + optional analysis trims +
    Spatial/Atmos path voicing + on-device Tone AI genre bias.
    Width only for Impact on stereo.
    """
    base_key = profile.lower() if profile.lower() in BASE_PROFILES else "symphony"
    bands = [
        BandSpec(s.kind, s.freq, s.gain_db, s.q, s.label)
        for s in BASE_PROFILES[base_key]
    ]
    device = (device or "auto").lower()
    if device not in DEVICE_BIAS:
        device = "auto"
    path = path if path in SPATIAL_PATHS else "stereo"
    gain_cap, default_makeup = PROFILE_CAPS.get(base_key, (1.8, 0.18))

    _apply_bias(bands, DEVICE_BIAS.get(device, {}), intensity * 0.85)

    media_type = "music"
    quality = "medium"
    if analysis and base_key != "reference":
        media_type = analysis.media_type
        quality = analysis.quality
        # Light analysis bias only (scaled down for fidelity)
        _apply_bias(bands, MEDIA_BIAS.get(media_type, {}), intensity * 0.35)
        if quality == "low":
            _apply_bias(bands, MEDIA_BIAS["low_quality"], intensity * 0.25)
        note_map = {n["label"]: n["suggested_gain_db"] for n in analysis.notes}
        for b in bands:
            if b.label in note_map:
                b.gain_db = max(-gain_cap, min(gain_cap, b.gain_db + note_map[b.label] * intensity * 0.25))

    # On-device Tone AI — genre from live features + optional local metadata text.
    tone_genre = (genre or "").lower().strip() or None
    tone_conf = 0.0
    tone_source = "none"
    if base_key != "reference":
        tone = _load_tone_ai()
        if tone is not None:
            try:
                if analysis is not None:
                    feats = tone.ToneFeatures(
                        bass_ratio=analysis.bass_ratio,
                        brightness=analysis.brightness,
                        crest_db=analysis.crest_db,
                        zcr=0.08,  # not on MediaAnalysis — soft default
                        dynamic_range_db=analysis.dynamic_range_db,
                        speech_likelihood=analysis.speech_likelihood,
                        bandwidth_hz=analysis.bandwidth_hz,
                        mid_ratio=max(0.05, 1.0 - analysis.bass_ratio - analysis.brightness),
                    )
                    verdict = tone.classify_features(feats, metadata_text=metadata_text)
                elif metadata_text:
                    # Metadata-only prior when PCM analysis absent
                    feats = tone.ToneFeatures(0.22, 0.25, 10, 0.08, 12, 0.1, 11000, 0.33)
                    verdict = tone.classify_features(feats, metadata_text=metadata_text)
                else:
                    verdict = None
                if verdict is not None:
                    tone_genre = verdict.genre
                    tone_conf = float(verdict.confidence)
                    tone_source = verdict.source
                    tone.apply_genre_bias_to_bands(
                        bands, tone_genre, intensity=intensity * 0.40, gain_cap=gain_cap
                    )
            except Exception:
                pass
        elif tone_genre:
            # Fallback static map if module missing but genre string provided
            static = {
                "pop": {"punch": 0.4, "presence": 0.5, "mud": -0.3},
                "classical": {"air": 0.4, "mud": -0.4, "sub": -0.2},
                "electronic": {"sub": 0.6, "punch": 0.3},
                "hiphop": {"sub": 0.7, "presence": 0.2},
                "speech": {"presence": 0.8, "sub": -0.6, "mud": -0.5},
            }
            _apply_bias(bands, static.get(tone_genre, {}), intensity * 0.4)

    # Width: Impact only, stereo path only
    width = 0.08 * intensity if base_key == "impact" and path == "stereo" else 0.0

    makeup_db = default_makeup * intensity
    if analysis:
        if analysis.quality == "high":
            makeup_db = min(makeup_db, 0.12 * intensity)
        elif analysis.quality == "low":
            makeup_db = min(0.25 * intensity, makeup_db + 0.05)
        if analysis.media_type == "speech":
            makeup_db = min(makeup_db, 0.15 * intensity)
    if tone_genre == "classical":
        makeup_db = min(makeup_db, 0.14 * intensity)
    elif tone_genre == "speech":
        makeup_db = min(makeup_db, 0.15 * intensity)

    # Atmos/Spatial: gentle sub + mud; no air boost
    if path in ("atmosBed", "multichannel", "spatialBinaural", "stereoMixFallback"):
        width = 0.0
        makeup_db = min(makeup_db, 0.15 * intensity)
        for b in bands:
            if b.label in ("air", "brilliance", "sheen"):
                b.gain_db = min(0.0, b.gain_db * 0.2)
            elif b.label == "presence":
                b.gain_db = min(b.gain_db, 0.5)
            elif b.label == "mud":
                b.gain_db = min(b.gain_db, -0.4)

    if base_key == "reference":
        makeup_db = min(makeup_db, 0.2)
        width = 0.0

    for b in bands:
        b.gain_db = max(-gain_cap, min(gain_cap, b.gain_db))

    # Headroom-first: scale if positive boosts stack too high
    pos_sum = sum(max(0.0, b.gain_db) for b in bands)
    if pos_sum + makeup_db > 3.5:
        scale = 3.5 / (pos_sum + makeup_db)
        for b in bands:
            b.gain_db *= scale
        makeup_db *= scale

    makeup = 10 ** (makeup_db / 20.0)

    report = {
        "profile": base_key,
        "device": device,
        "path": path,
        "media_type": media_type,
        "quality": quality,
        "width": width,
        "intensity": intensity,
        "makeup_db": round(makeup_db, 2),
        "atmos_safe": path in ("atmosBed", "multichannel", "spatialBinaural", "stereoMixFallback"),
        "mid_side": width > 0.001,
        "fidelity_capped": True,
        "linked_true_peak_ceiling_db": -1.0,
        "tone_genre": tone_genre or "unknown",
        "tone_confidence": round(tone_conf, 3),
        "tone_source": tone_source,
        "tone_ai": True,
    }
    return bands, makeup, report


def lfe_bands(bands: Sequence[BandSpec]) -> List[BandSpec]:
    """Sub/lowshelf-only set for LFE channels in Atmos/surround beds."""
    out: List[BandSpec] = []
    for b in bands:
        if b.kind == "lowshelf" or b.freq <= 150:
            out.append(
                BandSpec(
                    b.kind if b.kind == "lowshelf" else "peak",
                    min(b.freq, 120.0) if b.kind != "lowshelf" else b.freq,
                    b.gain_db * (0.85 if b.kind == "lowshelf" else 0.7),
                    b.q,
                    b.label,
                )
            )
    if not out:
        out = [BandSpec("lowshelf", 80, 0.0, 0.7, "sub")]
    return out


def bands_to_filters(bands: Sequence[BandSpec], sr: float) -> List[Biquad]:
    out: List[Biquad] = []
    for s in bands:
        if s.kind == "peak":
            out.append(_peaking(sr, s.freq, s.gain_db, s.q))
        elif s.kind == "lowshelf":
            out.append(_lowshelf(sr, s.freq, s.gain_db, s.q))
        elif s.kind == "highshelf":
            out.append(_highshelf(sr, s.freq, s.gain_db, s.q))
    return out


def process_sample(filters: Sequence[Biquad], x: float, makeup: float) -> float:
    y = x
    for f in filters:
        y = f.process(y)
    y *= makeup
    return soft_limit(y)


def soft_limit(y: float) -> float:
    if y > 0.97:
        y = 0.97 + 0.03 * math.tanh((y - 0.97) * 8)
    elif y < -0.97:
        y = -0.97 + 0.03 * math.tanh((y + 0.97) * 8)
    return max(-1.0, min(1.0, y))


# ---------------------------------------------------------------------------
# Seamless transitions — equal-power dual path + wet ramps
# ---------------------------------------------------------------------------

# Defaults aligned with LocalAmplifyEngine (seconds → ms for CLI).
DEFAULT_TRANSITION_MS = 90.0
DEFAULT_FADE_IN_MS = 120.0
DEFAULT_FADE_OUT_MS = 80.0


def equal_power(t: float) -> Tuple[float, float]:
    """Equal-power crossfade weights for t in [0, 1] (A→B)."""
    x = max(0.0, min(1.0, t))
    return math.cos(x * math.pi * 0.5), math.sin(x * math.pi * 0.5)


def blend_bands(
    a: Sequence[BandSpec],
    b: Sequence[BandSpec],
    t: float,
) -> List[BandSpec]:
    """
    Morph band gains (and q) by label for offline previews.
    Missing labels in either side are treated as 0 dB identity peers.
    """
    t = max(0.0, min(1.0, t))
    by_a = {s.label or f"@{i}": s for i, s in enumerate(a)}
    by_b = {s.label or f"@{i}": s for i, s in enumerate(b)}
    labels = list(dict.fromkeys([*by_a.keys(), *by_b.keys()]))
    out: List[BandSpec] = []
    for lab in labels:
        sa = by_a.get(lab)
        sb = by_b.get(lab)
        if sa and sb:
            out.append(
                BandSpec(
                    kind=sb.kind if t >= 0.5 else sa.kind,
                    freq=sa.freq * (1 - t) + sb.freq * t,
                    gain_db=sa.gain_db * (1 - t) + sb.gain_db * t,
                    q=sa.q * (1 - t) + sb.q * t,
                    label=lab if not lab.startswith("@") else (sa.label or sb.label),
                )
            )
        elif sa:
            out.append(BandSpec(sa.kind, sa.freq, sa.gain_db * (1 - t), sa.q, sa.label))
        elif sb:
            out.append(BandSpec(sb.kind, sb.freq, sb.gain_db * t, sb.q, sb.label))
    return out


def wet_envelope(frame: int, total_frames: int, fade_in: int, fade_out: int) -> float:
    """Linear wet 0→1→0 envelope in frames (equal-power optional at ends)."""
    if total_frames <= 0:
        return 1.0
    w = 1.0
    if fade_in > 0 and frame < fade_in:
        w = frame / float(fade_in)
    if fade_out > 0 and frame >= total_frames - fade_out:
        rem = total_frames - frame
        w = min(w, rem / float(fade_out))
    # Equal-power shape on the ramp so loudness stays even.
    w = max(0.0, min(1.0, w))
    return math.sin(w * math.pi * 0.5)


def process_stereo_ms(
    data: bytes,
    filters_l: List[Biquad],
    filters_r: List[Biquad],
    makeup: float,
    width: float,
    *,
    fade_in_frames: int = 0,
    fade_out_frames: int = 0,
) -> bytes:
    """Stereo process with optional mid-side width + seamless wet fade."""
    n = len(data) // 4
    if n % 2:
        n -= 1
    frames = n // 2
    out = bytearray()
    w = max(0.0, min(0.4, width))
    for fi, i in enumerate(range(0, n, 2)):
        l = struct.unpack_from("<f", data, i * 4)[0]
        r = struct.unpack_from("<f", data, (i + 1) * 4)[0]
        dry_l, dry_r = l, r
        mid = 0.5 * (l + r)
        side = 0.5 * (l - r)
        side *= 1.0 + w
        l2 = mid + side
        r2 = mid - side
        lo = process_sample(filters_l, l2, makeup)
        ro = process_sample(filters_r, r2, makeup)
        wet = wet_envelope(fi, frames, fade_in_frames, fade_out_frames)
        lo = dry_l * (1.0 - wet) + lo * wet
        ro = dry_r * (1.0 - wet) + ro * wet
        out += struct.pack("<ff", lo, ro)
    return bytes(out)


def process_stereo_seamless(
    data: bytes,
    sr: float,
    from_profile: str,
    to_profile: str,
    device: str = "auto",
    analysis: Optional[MediaAnalysis] = None,
    intensity: float = 1.0,
    transition_ms: float = DEFAULT_TRANSITION_MS,
    fade_in_ms: float = DEFAULT_FADE_IN_MS,
    fade_out_ms: float = 0.0,
) -> bytes:
    """
    Dual-path equal-power crossfade from one curve to another, plus wet engage.
    Mirrors LocalAmplifyEngine realtime transitions for offline design/test.
    """
    bands_a, makeup_a, report_a = build_adaptive_bands(from_profile, device, analysis, intensity)
    bands_b, makeup_b, report_b = build_adaptive_bands(to_profile, device, analysis, intensity)
    fl_a = bands_to_filters(bands_a, sr)
    fr_a = [f.clone() for f in fl_a]
    fl_b = bands_to_filters(bands_b, sr)
    fr_b = [f.clone() for f in fl_b]
    width_a = float(report_a["width"])
    width_b = float(report_b["width"])

    n = len(data) // 4
    if n % 2:
        n -= 1
    frames = n // 2
    xfade = max(1, int(sr * (transition_ms / 1000.0)))
    fade_in = max(0, int(sr * (fade_in_ms / 1000.0)))
    fade_out = max(0, int(sr * (fade_out_ms / 1000.0)))

    out = bytearray()
    for fi, i in enumerate(range(0, n, 2)):
        l = struct.unpack_from("<f", data, i * 4)[0]
        r = struct.unpack_from("<f", data, (i + 1) * 4)[0]
        dry_l, dry_r = l, r
        t = min(1.0, fi / float(xfade)) if xfade > 0 else 1.0
        gA, gB = equal_power(t)
        w = width_a * gA + width_b * gB

        mid = 0.5 * (l + r)
        side = 0.5 * (l - r) * (1.0 + w)
        l2, r2 = mid + side, mid - side

        la = process_sample(fl_a, l2, makeup_a)
        ra = process_sample(fr_a, r2, makeup_a)
        lb = process_sample(fl_b, l2, makeup_b)
        rb = process_sample(fr_b, r2, makeup_b)
        lo = la * gA + lb * gB
        ro = ra * gA + rb * gB

        wet = wet_envelope(fi, frames, fade_in, fade_out)
        lo = dry_l * (1.0 - wet) + lo * wet
        ro = dry_r * (1.0 - wet) + ro * wet
        out += struct.pack("<ff", max(-1.0, min(1.0, lo)), max(-1.0, min(1.0, ro)))
    return bytes(out)


def morph_payload(
    from_profile: str,
    to_profile: str,
    sample_rate: float,
    device: str = "auto",
    steps: int = 5,
    intensity: float = 1.0,
) -> dict:
    """Emit intermediate band morphs for designers / unit tests."""
    a, _, _ = build_adaptive_bands(from_profile, device, None, intensity)
    b, _, _ = build_adaptive_bands(to_profile, device, None, intensity)
    frames = []
    n = max(2, steps)
    for i in range(n):
        t = i / float(n - 1)
        bands = blend_bands(a, b, t)
        gA, gB = equal_power(t)
        frames.append(
            {
                "t": round(t, 4),
                "equal_power": {"a": round(gA, 5), "b": round(gB, 5)},
                "bands": [asdict(x) for x in bands],
            }
        )
    return {
        "engine": "DynamoEQ",
        "version": 4,
        "seamless": True,
        "tone_ai": True,
        "from_profile": from_profile,
        "to_profile": to_profile,
        "device": device,
        "steps": n,
        "frames": frames,
    }


def coeffs_payload(
    profile: str,
    sample_rate: float,
    device: str = "auto",
    analysis: Optional[MediaAnalysis] = None,
    intensity: float = 1.0,
    path: str = "stereo",
    genre: Optional[str] = None,
    metadata_text: Optional[str] = None,
) -> dict:
    bands, makeup, report = build_adaptive_bands(
        profile,
        device,
        analysis,
        intensity,
        path=path,
        genre=genre,
        metadata_text=metadata_text,
    )
    filters = bands_to_filters(bands, sample_rate)
    lfe = bands_to_filters(lfe_bands(bands), sample_rate)
    return {
        "engine": "DynamoEQ",
        "version": 4,
        "symphony": True,
        "spatial_safe": True,
        "atmos_ready": True,
        "tone_ai": True,
        "seamless": True,
        "transition_ms": DEFAULT_TRANSITION_MS,
        "fade_in_ms": DEFAULT_FADE_IN_MS,
        "fade_out_ms": DEFAULT_FADE_OUT_MS,
        "profile": report["profile"],
        "device": report["device"],
        "path": report["path"],
        "media_type": report["media_type"],
        "quality": report["quality"],
        "tone_genre": report.get("tone_genre", "unknown"),
        "tone_confidence": report.get("tone_confidence", 0),
        "tone_source": report.get("tone_source", "none"),
        "sampleRate": sample_rate,
        "makeup": makeup,
        "width": report["width"],
        "intensity": intensity,
        "mid_side": report["mid_side"],
        "atmos_safe": report["atmos_safe"],
        "bands": [asdict(b) for b in bands],
        "lfe_bands": [asdict(b) for b in lfe_bands(bands)],
        "biquads": [
            {"b0": f.b0, "b1": f.b1, "b2": f.b2, "a1": f.a1, "a2": f.a2} for f in filters
        ],
        "lfe_biquads": [
            {"b0": f.b0, "b1": f.b1, "b2": f.b2, "a1": f.a1, "a2": f.a2} for f in lfe
        ],
        "analysis": asdict(analysis) if analysis else None,
    }


def read_stereo_mono(raw: bytes) -> Tuple[List[float], List[float], List[float]]:
    n = len(raw) // 4
    samples = list(struct.unpack("<" + "f" * n, raw[: n * 4])) if n else []
    left, right, mono = [], [], []
    for i in range(0, len(samples) - 1, 2):
        l, r = samples[i], samples[i + 1]
        left.append(l)
        right.append(r)
        mono.append(0.5 * (l + r))
    if not mono and samples:
        mono = samples
        left = samples
        right = samples
    return left, right, mono


def selftest() -> None:
    sr = 48000.0
    # Synthetic music-like tone stack
    mono = []
    for i in range(int(sr * 0.5)):
        t = i / sr
        mono.append(
            0.15 * math.sin(2 * math.pi * 110 * t)
            + 0.08 * math.sin(2 * math.pi * 440 * t)
            + 0.04 * math.sin(2 * math.pi * 2000 * t)
        )
    a = analyze_mono(mono, sr)
    assert a.media_type in BASE_PROFILES or a.media_type in MEDIA_BIAS
    payload = coeffs_payload("symphony", sr, "headphones", a, 1.0, path="stereo")
    assert payload["width"] == 0  # width only on Impact
    assert payload["version"] == 4
    assert payload["seamless"] is True
    assert payload["atmos_ready"] is True
    assert payload.get("tone_ai") is True
    # Classical metadata should bias tone genre when analysis is musical
    classical = coeffs_payload(
        "symphony",
        sr,
        "headphones",
        a,
        1.0,
        path="stereo",
        metadata_text="Mozart Symphony No. 40 classical orchestral",
    )
    assert classical.get("tone_genre") in (
        "classical",
        "unknown",
        "jazz",
        "folk",
        "ambient",
        "pop",
        "rock",
        "electronic",
        "hiphop",
        "metal",
        "speech",
    )
    assert len(payload["biquads"]) >= 5
    impact = coeffs_payload("impact", sr, "headphones", a, 1.0, path="stereo")
    assert impact["width"] > 0
    atmos = coeffs_payload("symphony", sr, "external", a, 1.0, path="atmosBed")
    assert atmos["width"] == 0
    assert atmos["atmos_safe"] is True
    assert len(atmos["lfe_biquads"]) >= 1
    ref = coeffs_payload("reference", sr, "auto", a, 1.0, path="stereo")
    assert ref["makeup"] <= 10 ** (0.25 / 20.0)
    # Process should not explode
    filters = bands_to_filters(
        [BandSpec(**{k: b[k] for k in ("kind", "freq", "gain_db", "q", "label") if k in b}) for b in payload["bands"]],
        sr,
    )
    peak = 0.0
    for x in mono[:2000]:
        y = process_sample(filters, x, payload["makeup"])
        peak = max(peak, abs(y))
    assert peak < 1.05, peak

    # Seamless transition: dual-path should not produce NaNs or hard jumps > hard clip.
    stereo = bytearray()
    for x in mono[:8000]:
        stereo += struct.pack("<ff", x, x * 0.9)
    out = process_stereo_seamless(
        bytes(stereo),
        sr,
        "cinema",
        "impact",
        device="headphones",
        transition_ms=40,
        fade_in_ms=20,
    )
    assert len(out) == len(stereo)
    samples = struct.unpack("<" + "f" * (len(out) // 4), out)
    assert all(math.isfinite(s) for s in samples)
    assert max(abs(s) for s in samples) <= 1.0 + 1e-5

    # Equal-power continuity
    g0a, g0b = equal_power(0.0)
    g1a, g1b = equal_power(1.0)
    assert abs(g0a - 1.0) < 1e-9 and abs(g0b) < 1e-9
    assert abs(g1b - 1.0) < 1e-9 and abs(g1a) < 1e-9
    mid_a, mid_b = equal_power(0.5)
    assert abs(mid_a * mid_a + mid_b * mid_b - 1.0) < 1e-6

    morph = morph_payload("presence", "symphony", sr, "auto", steps=4)
    assert len(morph["frames"]) == 4

    print(
        "selftest ok",
        {
            "media": a.media_type,
            "quality": a.quality,
            "width": payload["width"],
            "bands": len(payload["bands"]),
            "peak": peak,
            "seamless": True,
            "tone_ai": True,
            "version": 4,
        },
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(description="DynamoEQ adaptive local amplifier / symphony engine")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("coeffs", help="Print JSON coefficients")
    c.add_argument("--profile", default="symphony", choices=list(BASE_PROFILES))
    c.add_argument("--device", default="auto", choices=list(DEVICE_BIAS))
    c.add_argument(
        "--path",
        default="stereo",
        choices=list(SPATIAL_PATHS),
        help="Spatial/Atmos path: stereo | spatialBinaural | atmosBed | multichannel",
    )
    c.add_argument("--sr", type=float, default=48000.0)
    c.add_argument("--intensity", type=float, default=1.0)
    c.add_argument("--genre", default="", help="Optional genre hint (pop/classical/…)")
    c.add_argument("--metadata", default="", help="Local title/artist/genre text for Tone AI")

    a = sub.add_parser("analyze", help="Analyze stereo float32 LE PCM on stdin")
    a.add_argument("--sr", type=float, default=48000.0)

    s = sub.add_parser("symphony", help="Analyze + emit adaptive symphony coeffs")
    s.add_argument("--profile", default="symphony", choices=list(BASE_PROFILES))
    s.add_argument("--device", default="auto", choices=list(DEVICE_BIAS))
    s.add_argument("--path", default="stereo", choices=list(SPATIAL_PATHS))
    s.add_argument("--sr", type=float, default=48000.0)
    s.add_argument("--intensity", type=float, default=1.0)
    s.add_argument("--genre", default="")
    s.add_argument("--metadata", default="")

    pr = sub.add_parser("process", help="Process stereo float32 LE PCM stdin→stdout")
    pr.add_argument("--profile", default="symphony", choices=list(BASE_PROFILES))
    pr.add_argument(
        "--from-profile",
        default=None,
        choices=list(BASE_PROFILES),
        help="Start curve for seamless dual-path crossfade into --profile",
    )
    pr.add_argument("--device", default="auto", choices=list(DEVICE_BIAS))
    pr.add_argument("--path", default="stereo", choices=list(SPATIAL_PATHS))
    pr.add_argument("--sr", type=float, default=48000.0)
    pr.add_argument("--intensity", type=float, default=1.0)
    pr.add_argument("--adapt", action="store_true", help="Analyze stream then adapt")
    pr.add_argument(
        "--transition-ms",
        type=float,
        default=DEFAULT_TRANSITION_MS,
        help="Profile/device crossfade length (ms)",
    )
    pr.add_argument(
        "--fade-in-ms",
        type=float,
        default=DEFAULT_FADE_IN_MS,
        help="Wet engage ramp (ms); 0 disables",
    )
    pr.add_argument(
        "--fade-out-ms",
        type=float,
        default=0.0,
        help="Wet disengage ramp at end (ms)",
    )

    m = sub.add_parser("morph", help="Emit intermediate band morphs (JSON) between profiles")
    m.add_argument("--from-profile", default="cinema", choices=list(BASE_PROFILES))
    m.add_argument("--to-profile", default="symphony", choices=list(BASE_PROFILES))
    m.add_argument("--device", default="auto", choices=list(DEVICE_BIAS))
    m.add_argument("--sr", type=float, default=48000.0)
    m.add_argument("--steps", type=int, default=5)
    m.add_argument("--intensity", type=float, default=1.0)

    sub.add_parser("selftest")
    args = p.parse_args(argv)

    if args.cmd == "selftest":
        selftest()
        return 0

    if args.cmd == "coeffs":
        print(
            json.dumps(
                coeffs_payload(
                    args.profile,
                    args.sr,
                    args.device,
                    None,
                    args.intensity,
                    path=args.path,
                    genre=args.genre or None,
                    metadata_text=args.metadata or None,
                ),
                indent=2,
            )
        )
        return 0

    if args.cmd == "analyze":
        raw = sys.stdin.buffer.read()
        _, _, mono = read_stereo_mono(raw)
        print(json.dumps(asdict(analyze_mono(mono, args.sr)), indent=2))
        return 0

    if args.cmd == "symphony":
        raw = sys.stdin.buffer.read()
        _, _, mono = read_stereo_mono(raw)
        analysis = analyze_mono(mono, args.sr) if mono else None
        print(
            json.dumps(
                coeffs_payload(
                    args.profile,
                    args.sr,
                    args.device,
                    analysis,
                    args.intensity,
                    path=args.path,
                    genre=args.genre or None,
                    metadata_text=args.metadata or None,
                ),
                indent=2,
            )
        )
        return 0

    if args.cmd == "morph":
        print(
            json.dumps(
                morph_payload(
                    args.from_profile,
                    args.to_profile,
                    args.sr,
                    args.device,
                    args.steps,
                    args.intensity,
                ),
                indent=2,
            )
        )
        return 0

    if args.cmd == "process":
        raw = sys.stdin.buffer.read()
        analysis = None
        if args.adapt:
            _, _, mono = read_stereo_mono(raw)
            analysis = analyze_mono(mono, args.sr) if mono else None
        fade_in_frames = max(0, int(args.sr * (args.fade_in_ms / 1000.0)))
        fade_out_frames = max(0, int(args.sr * (args.fade_out_ms / 1000.0)))
        if args.from_profile and args.from_profile != args.profile:
            sys.stdout.buffer.write(
                process_stereo_seamless(
                    raw,
                    args.sr,
                    args.from_profile,
                    args.profile,
                    device=args.device,
                    analysis=analysis,
                    intensity=args.intensity,
                    transition_ms=args.transition_ms,
                    fade_in_ms=args.fade_in_ms,
                    fade_out_ms=args.fade_out_ms,
                )
            )
        else:
            payload = coeffs_payload(
                args.profile, args.sr, args.device, analysis, args.intensity, path=args.path
            )
            bands = [
                BandSpec(b["kind"], b["freq"], b["gain_db"], b.get("q", 0.9), b.get("label", ""))
                for b in payload["bands"]
            ]
            fl = bands_to_filters(bands, args.sr)
            fr = [f.clone() for f in fl]
            # Atmos/Spatial paths force width 0 in payload already.
            sys.stdout.buffer.write(
                process_stereo_ms(
                    raw,
                    fl,
                    fr,
                    payload["makeup"],
                    payload["width"],
                    fade_in_frames=fade_in_frames,
                    fade_out_frames=fade_out_frames,
                )
            )
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
