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

Realtime path: Dynamo’s LocalAmplifyEngine applies the exported biquads.
This CLI designs coeffs, analyzes PCM, and can process float32 stereo streams.

Usage:
  python3 dynamo_eq.py selftest
  python3 dynamo_eq.py coeffs --profile cinema --device headphones --sr 48000
  python3 dynamo_eq.py analyze --sr 48000 < stereo.f32le
  python3 dynamo_eq.py symphony --device auto --sr 48000 < stereo.f32le
  python3 dynamo_eq.py process --profile impact --device speakers --sr 48000 < in > out
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


# Intent bases (then adapted by media + device + note evaluation)
BASE_PROFILES: Dict[str, List[BandSpec]] = {
    "presence": [
        BandSpec("lowshelf", 90, -1.2, 0.7, "sub"),
        BandSpec("peak", 350, -1.0, 0.9, "body"),
        BandSpec("peak", 1800, 2.8, 1.1, "presence"),
        BandSpec("peak", 3500, 2.2, 1.0, "air"),
        BandSpec("highshelf", 8000, 1.8, 0.7, "brilliance"),
    ],
    "cinema": [
        BandSpec("lowshelf", 70, 2.4, 0.7, "sub"),
        BandSpec("peak", 250, 0.8, 0.9, "warmth"),
        BandSpec("peak", 900, -1.8, 1.0, "mud"),
        BandSpec("peak", 3200, 1.4, 1.0, "presence"),
        BandSpec("highshelf", 9000, 2.2, 0.7, "air"),
    ],
    "impact": [
        BandSpec("lowshelf", 60, 3.8, 0.7, "sub"),
        BandSpec("peak", 110, 2.6, 1.0, "punch"),
        BandSpec("peak", 220, 1.5, 1.0, "body"),
        BandSpec("peak", 800, -1.2, 0.9, "mud"),
        BandSpec("highshelf", 7000, 1.0, 0.7, "air"),
    ],
    # Auto / symphony — balanced concert contour (starting point)
    "symphony": [
        BandSpec("lowshelf", 65, 2.0, 0.7, "sub"),
        BandSpec("peak", 180, 1.2, 0.95, "body"),
        BandSpec("peak", 700, -1.4, 1.0, "mud"),
        BandSpec("peak", 2200, 2.0, 1.05, "presence"),
        BandSpec("peak", 4500, 1.3, 1.0, "sheen"),
        BandSpec("highshelf", 10000, 1.6, 0.7, "air"),
    ],
}

# Device “you are there” voicing (added to band gains by label)
DEVICE_BIAS: Dict[str, Dict[str, float]] = {
    # dB offsets keyed by band label
    "headphones": {"sub": -0.4, "body": 0.3, "presence": 1.2, "air": 1.4, "sheen": 0.8, "mud": -0.3, "punch": 0.4, "brilliance": 1.0, "warmth": 0.2},
    "wireless": {"sub": 0.6, "body": 0.5, "presence": 0.9, "air": 0.5, "sheen": 0.4, "mud": -0.5, "punch": 0.8, "brilliance": 0.3, "warmth": 0.4},  # BT often dull
    "speakers": {"sub": 0.8, "body": 0.6, "presence": 0.7, "air": 0.4, "sheen": 0.3, "mud": -0.8, "punch": 0.5, "brilliance": 0.2, "warmth": 0.5},
    "external": {"sub": 1.0, "body": 0.4, "presence": 0.5, "air": 0.6, "sheen": 0.5, "mud": -0.6, "punch": 0.4, "brilliance": 0.4, "warmth": 0.3},
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


def build_adaptive_bands(
    profile: str,
    device: str,
    analysis: Optional[MediaAnalysis],
    intensity: float = 1.0,
) -> Tuple[List[BandSpec], float, dict]:
    """
    Combine intent profile + device symphony voicing + media/note evaluation.
    Returns bands, makeup_linear, report.
    """
    base_key = profile.lower() if profile.lower() in BASE_PROFILES else "symphony"
    bands = [
        BandSpec(s.kind, s.freq, s.gain_db, s.q, s.label)
        for s in BASE_PROFILES[base_key]
    ]
    device = (device or "auto").lower()
    if device not in DEVICE_BIAS:
        device = "auto"

    _apply_bias(bands, DEVICE_BIAS.get(device, {}), intensity)

    media_type = "music"
    quality = "medium"
    if analysis:
        media_type = analysis.media_type
        quality = analysis.quality
        _apply_bias(bands, MEDIA_BIAS.get(media_type, {}), intensity)
        if quality == "low":
            _apply_bias(bands, MEDIA_BIAS["low_quality"], intensity * 0.85)
        # Note-level tuning
        note_map = {n["label"]: n["suggested_gain_db"] for n in analysis.notes}
        for b in bands:
            if b.label in note_map:
                b.gain_db = max(-8.0, min(7.0, b.gain_db + note_map[b.label] * intensity * 0.75))

    # Symphony immersion extras by device
    width = 0.0  # mid-side width amount 0..0.35
    presence_air = 0.0
    if device == "headphones":
        width = 0.12 * intensity  # gentle stage
        presence_air = 0.4
    elif device == "wireless":
        width = 0.08 * intensity
        presence_air = 0.6  # restore HF lost to codecs
    elif device == "speakers":
        width = 0.05 * intensity
        presence_air = 0.2
    elif device == "external":
        width = 0.10 * intensity
        presence_air = 0.35

    for b in bands:
        if b.label in ("air", "brilliance", "sheen", "presence"):
            b.gain_db = max(-8.0, min(7.0, b.gain_db + presence_air))

    # Makeup: lower for high-DR masters, slightly higher for low quality
    makeup_db = 0.45 * intensity
    if analysis:
        if analysis.quality == "high":
            makeup_db = 0.25 * intensity
        elif analysis.quality == "low":
            makeup_db = 0.7 * intensity
        if analysis.media_type == "speech":
            makeup_db = 0.35 * intensity
    makeup = 10 ** (makeup_db / 20.0)

    report = {
        "profile": base_key,
        "device": device,
        "media_type": media_type,
        "quality": quality,
        "width": width,
        "intensity": intensity,
        "makeup_db": round(makeup_db, 2),
    }
    return bands, makeup, report


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
    if y > 0.97:
        y = 0.97 + 0.03 * math.tanh((y - 0.97) * 8)
    elif y < -0.97:
        y = -0.97 + 0.03 * math.tanh((y + 0.97) * 8)
    return max(-1.0, min(1.0, y))


def process_stereo_ms(
    data: bytes,
    filters_l: List[Biquad],
    filters_r: List[Biquad],
    makeup: float,
    width: float,
) -> bytes:
    """Stereo process with optional mid-side width (immersive stage, Spatial-safe)."""
    n = len(data) // 4
    if n % 2:
        n -= 1
    out = bytearray()
    w = max(0.0, min(0.4, width))
    for i in range(0, n, 2):
        l = struct.unpack_from("<f", data, i * 4)[0]
        r = struct.unpack_from("<f", data, (i + 1) * 4)[0]
        # Mid-side encode
        mid = 0.5 * (l + r)
        side = 0.5 * (l - r)
        side *= 1.0 + w
        l2 = mid + side
        r2 = mid - side
        lo = process_sample(filters_l, l2, makeup)
        ro = process_sample(filters_r, r2, makeup)
        out += struct.pack("<ff", lo, ro)
    return bytes(out)


def coeffs_payload(
    profile: str,
    sample_rate: float,
    device: str = "auto",
    analysis: Optional[MediaAnalysis] = None,
    intensity: float = 1.0,
) -> dict:
    bands, makeup, report = build_adaptive_bands(profile, device, analysis, intensity)
    filters = bands_to_filters(bands, sample_rate)
    return {
        "engine": "DynamoEQ",
        "version": 2,
        "symphony": True,
        "spatial_safe": True,
        "profile": report["profile"],
        "device": report["device"],
        "media_type": report["media_type"],
        "quality": report["quality"],
        "sampleRate": sample_rate,
        "makeup": makeup,
        "width": report["width"],
        "intensity": intensity,
        "bands": [asdict(b) for b in bands],
        "biquads": [
            {"b0": f.b0, "b1": f.b1, "b2": f.b2, "a1": f.a1, "a2": f.a2} for f in filters
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
    payload = coeffs_payload("symphony", sr, "headphones", a, 1.0)
    assert payload["width"] > 0
    assert len(payload["biquads"]) >= 5
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
    print(
        "selftest ok",
        {
            "media": a.media_type,
            "quality": a.quality,
            "width": payload["width"],
            "bands": len(payload["bands"]),
            "peak": peak,
        },
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(description="DynamoEQ adaptive local amplifier / symphony engine")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("coeffs", help="Print JSON coefficients")
    c.add_argument("--profile", default="symphony", choices=list(BASE_PROFILES))
    c.add_argument("--device", default="auto", choices=list(DEVICE_BIAS))
    c.add_argument("--sr", type=float, default=48000.0)
    c.add_argument("--intensity", type=float, default=1.0)

    a = sub.add_parser("analyze", help="Analyze stereo float32 LE PCM on stdin")
    a.add_argument("--sr", type=float, default=48000.0)

    s = sub.add_parser("symphony", help="Analyze + emit adaptive symphony coeffs")
    s.add_argument("--profile", default="symphony", choices=list(BASE_PROFILES))
    s.add_argument("--device", default="auto", choices=list(DEVICE_BIAS))
    s.add_argument("--sr", type=float, default=48000.0)
    s.add_argument("--intensity", type=float, default=1.0)

    pr = sub.add_parser("process", help="Process stereo float32 LE PCM stdin→stdout")
    pr.add_argument("--profile", default="symphony", choices=list(BASE_PROFILES))
    pr.add_argument("--device", default="auto", choices=list(DEVICE_BIAS))
    pr.add_argument("--sr", type=float, default=48000.0)
    pr.add_argument("--intensity", type=float, default=1.0)
    pr.add_argument("--adapt", action="store_true", help="Analyze stream then adapt")

    sub.add_parser("selftest")
    args = p.parse_args(argv)

    if args.cmd == "selftest":
        selftest()
        return 0

    if args.cmd == "coeffs":
        print(json.dumps(coeffs_payload(args.profile, args.sr, args.device, None, args.intensity), indent=2))
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
        print(json.dumps(coeffs_payload(args.profile, args.sr, args.device, analysis, args.intensity), indent=2))
        return 0

    if args.cmd == "process":
        raw = sys.stdin.buffer.read()
        analysis = None
        if args.adapt:
            _, _, mono = read_stereo_mono(raw)
            analysis = analyze_mono(mono, args.sr) if mono else None
        payload = coeffs_payload(args.profile, args.sr, args.device, analysis, args.intensity)
        bands = [BandSpec(b["kind"], b["freq"], b["gain_db"], b.get("q", 0.9), b.get("label", "")) for b in payload["bands"]]
        fl = bands_to_filters(bands, args.sr)
        fr = [f.clone() for f in fl]
        sys.stdout.buffer.write(
            process_stereo_ms(raw, fl, fr, payload["makeup"], payload["width"])
        )
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
