#!/usr/bin/env python3
"""
DynamoEQ — local multi-band EQ amplifier + spectral optimizer.

No network, no cloud APIs, no Apple Music scripting. Pure Python 3 stdlib.
Used by Dynamo Amplify for coefficient design / offline processing; the app
applies the same curves in real time via Core Audio.

Usage:
  python3 dynamo_eq.py coeffs --profile impact --sr 48000
  python3 dynamo_eq.py process --profile cinema --sr 48000 < in.f32le > out.f32le
  python3 dynamo_eq.py optimize --profile presence --sr 48000 < in.f32le
  python3 dynamo_eq.py selftest
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from dataclasses import dataclass, asdict
from typing import Iterable, List, Sequence, Tuple


# ---------------------------------------------------------------------------
# Biquad (RBJ cookbook) — pure Python
# ---------------------------------------------------------------------------


@dataclass
class Biquad:
    b0: float
    b1: float
    b2: float
    a1: float
    a2: float
    # state
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
    w0 = 2.0 * math.pi * (freq / sr)
    cos_w = math.cos(w0)
    sin_w = math.sin(w0)
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
    w0 = 2.0 * math.pi * (freq / sr)
    cos_w = math.cos(w0)
    sin_w = math.sin(w0)
    alpha = sin_w / (2.0 * max(q, 0.05))
    two_sqrt_a_alpha = 2 * math.sqrt(a) * alpha
    b0 = a * ((a + 1) - (a - 1) * cos_w + two_sqrt_a_alpha)
    b1 = 2 * a * ((a - 1) - (a + 1) * cos_w)
    b2 = a * ((a + 1) - (a - 1) * cos_w - two_sqrt_a_alpha)
    a0 = (a + 1) + (a - 1) * cos_w + two_sqrt_a_alpha
    a1 = -2 * ((a - 1) + (a + 1) * cos_w)
    a2 = (a + 1) + (a - 1) * cos_w - two_sqrt_a_alpha
    return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def _highshelf(sr: float, freq: float, gain_db: float, q: float = 0.707) -> Biquad:
    a = 10 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * (freq / sr)
    cos_w = math.cos(w0)
    sin_w = math.sin(w0)
    alpha = sin_w / (2.0 * max(q, 0.05))
    two_sqrt_a_alpha = 2 * math.sqrt(a) * alpha
    b0 = a * ((a + 1) + (a - 1) * cos_w + two_sqrt_a_alpha)
    b1 = -2 * a * ((a - 1) + (a + 1) * cos_w)
    b2 = a * ((a + 1) + (a - 1) * cos_w - two_sqrt_a_alpha)
    a0 = (a + 1) - (a - 1) * cos_w + two_sqrt_a_alpha
    a1 = 2 * ((a - 1) - (a + 1) * cos_w)
    a2 = (a + 1) - (a - 1) * cos_w - two_sqrt_a_alpha
    return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


@dataclass
class BandSpec:
    kind: str  # peak | lowshelf | highshelf
    freq: float
    gain_db: float
    q: float = 0.9


# Intent profiles — perceptual contours (dB), conservative headroom.
# Spatial/Atmos-safe: modest shelves, no mono/mid-side, same curve on every channel.
PROFILES: dict[str, List[BandSpec]] = {
    "presence": [
        BandSpec("lowshelf", 90, -1.2, 0.7),
        BandSpec("peak", 350, -1.0, 0.9),
        BandSpec("peak", 1800, 2.8, 1.1),
        BandSpec("peak", 3500, 2.2, 1.0),
        BandSpec("highshelf", 8000, 1.8, 0.7),
    ],
    "cinema": [
        BandSpec("lowshelf", 70, 2.4, 0.7),
        BandSpec("peak", 250, 0.8, 0.9),
        BandSpec("peak", 900, -1.8, 1.0),  # soft mid scoop
        BandSpec("peak", 3200, 1.4, 1.0),
        BandSpec("highshelf", 9000, 2.2, 0.7),
    ],
    "impact": [
        BandSpec("lowshelf", 60, 3.8, 0.7),
        BandSpec("peak", 110, 2.6, 1.0),
        BandSpec("peak", 220, 1.5, 1.0),
        BandSpec("peak", 800, -1.2, 0.9),
        BandSpec("highshelf", 7000, 1.0, 0.7),
    ],
}


def build_chain(profile: str, sample_rate: float, gain_scale: float = 1.0) -> Tuple[List[Biquad], float]:
    specs = PROFILES.get(profile.lower())
    if not specs:
        raise SystemExit(f"unknown profile {profile!r}; choose {list(PROFILES)}")
    filters: List[Biquad] = []
    for s in specs:
        g = s.gain_db * gain_scale
        if s.kind == "peak":
            filters.append(_peaking(sample_rate, s.freq, g, s.q))
        elif s.kind == "lowshelf":
            filters.append(_lowshelf(sample_rate, s.freq, g, s.q))
        elif s.kind == "highshelf":
            filters.append(_highshelf(sample_rate, s.freq, g, s.q))
        else:
            raise SystemExit(f"bad band kind {s.kind}")
    # Makeup: slight positive for impact/cinema only.
    makeup = {"presence": 0.4, "cinema": 0.6, "impact": 0.8}.get(profile.lower(), 0.5)
    makeup_lin = 10 ** ((makeup * gain_scale) / 20.0)
    return filters, makeup_lin


def process_sample(filters: Sequence[Biquad], x: float, makeup: float) -> float:
    y = x
    for f in filters:
        y = f.process(y)
    y *= makeup
    # Soft clip / limiter
    if y > 0.97:
        y = 0.97 + 0.03 * math.tanh((y - 0.97) * 8)
    elif y < -0.97:
        y = -0.97 + 0.03 * math.tanh((y + 0.97) * 8)
    return max(-1.0, min(1.0, y))


def process_interleaved_stereo(
    data: bytes, filters_l: List[Biquad], filters_r: List[Biquad], makeup: float
) -> bytes:
    n = len(data) // 4
    if n % 2:
        n -= 1
    out = bytearray()
    for i in range(0, n, 2):
        l = struct.unpack_from("<f", data, i * 4)[0]
        r = struct.unpack_from("<f", data, (i + 1) * 4)[0]
        lo = process_sample(filters_l, l, makeup)
        ro = process_sample(filters_r, r, makeup)
        out += struct.pack("<ff", lo, ro)
    return bytes(out)


# ---------------------------------------------------------------------------
# Optimizer — balance band energy toward profile target using short FFT-ish bands
# ---------------------------------------------------------------------------


def _band_energy(samples: Sequence[float], sr: float, f_lo: float, f_hi: float) -> float:
    """Crude energy via zero-crossing / difference proxy + bandpass-ish IIR."""
    # One-pole band approximation using consecutive difference scaled by freq.
    if not samples:
        return 0.0
    # Simple 2nd order bandpass energy estimate
    mid = math.sqrt(f_lo * f_hi)
    q = mid / max(f_hi - f_lo, 1.0)
    bp = _peaking(sr, mid, 0.0, max(0.5, min(4.0, q)))
    # Convert peaking@0dB to bandpass-ish by using derivative of highpassed signal
    # Just run peak with high Q and measure RMS of filtered (use lowshelf/highshelf combo)
    ls = _highshelf(sr, f_lo, -12, 0.7)
    hs = _lowshelf(sr, f_hi, -12, 0.7)
    acc = 0.0
    for x in samples:
        y = ls.process(x)
        y = hs.process(y)
        acc += y * y
    return math.sqrt(acc / max(1, len(samples)))


def optimize_gains(
    profile: str, sample_rate: float, mono: Sequence[float]
) -> Tuple[List[BandSpec], float]:
    """
    Adjust profile gains ±3 dB so band energies approach a target contour.
    Returns updated BandSpecs + makeup linear gain.
    """
    base = [BandSpec(s.kind, s.freq, s.gain_db, s.q) for s in PROFILES[profile.lower()]]
    # Measure residual (pre-EQ) energy in each band region
    centers = [s.freq for s in base]
    energies = []
    for c in centers:
        lo = c / 1.6
        hi = c * 1.6
        energies.append(_band_energy(mono, sample_rate, lo, hi) + 1e-9)

    # Target relative energies (boost weak bands that profile wants high)
    targets = []
    for s in base:
        # Want more energy where gain_db > 0
        targets.append(1.0 + max(-0.5, min(1.5, s.gain_db / 4.0)))

    mean_e = sum(energies) / len(energies)
    mean_t = sum(targets) / len(targets)
    adjusted: List[BandSpec] = []
    for s, e, t in zip(base, energies, targets):
        rel = (t / mean_t) / (e / mean_e)
        # Map relative deficit to extra dB
        delta = 20 * math.log10(max(0.5, min(2.0, rel))) * 0.35
        g = max(-6.0, min(6.5, s.gain_db + delta))
        adjusted.append(BandSpec(s.kind, s.freq, g, s.q))

    # Makeup from overall RMS
    rms = math.sqrt(sum(x * x for x in mono) / max(1, len(mono))) + 1e-9
    target_rms = 0.12
    makeup_db = 20 * math.log10(target_rms / rms)
    makeup_db = max(-3.0, min(4.0, makeup_db * 0.25))
    return adjusted, 10 ** (makeup_db / 20.0)


def coeffs_json(profile: str, sample_rate: float, gain_scale: float = 1.0) -> dict:
    specs = PROFILES[profile.lower()]
    filters, makeup = build_chain(profile, sample_rate, gain_scale)
    return {
        "engine": "DynamoEQ",
        "version": 1,
        "profile": profile.lower(),
        "sampleRate": sample_rate,
        "makeup": makeup,
        "bands": [asdict(s) for s in specs],
        "biquads": [
            {"b0": f.b0, "b1": f.b1, "b2": f.b2, "a1": f.a1, "a2": f.a2} for f in filters
        ],
    }


def selftest() -> None:
    sr = 48000.0
    # Unit impulse through impact chain should not explode
    filters, makeup = build_chain("impact", sr)
    y = 0.0
    peak = 0.0
    for i in range(2048):
        x = 1.0 if i == 0 else 0.0
        y = process_sample(filters, x, makeup)
        peak = max(peak, abs(y))
    assert peak < 2.0, peak
    # Sine at 100 Hz should get more gain on impact than presence
    def sine_rms(profile: str, freq: float) -> float:
        fl, mk = build_chain(profile, sr)
        acc = 0.0
        n = 4800
        for i in range(n):
            x = math.sin(2 * math.pi * freq * i / sr) * 0.2
            y = process_sample(fl, x, mk)
            acc += y * y
        return math.sqrt(acc / n)

    r_impact = sine_rms("impact", 80)
    r_presence = sine_rms("presence", 80)
    assert r_impact > r_presence * 1.05, (r_impact, r_presence)
    print("selftest ok", {"peak": peak, "impact80": r_impact, "presence80": r_presence})


def main(argv: Sequence[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Dynamo local EQ amplifier (no network APIs)")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("coeffs", help="Print JSON coefficients for a profile")
    c.add_argument("--profile", default="cinema", choices=list(PROFILES))
    c.add_argument("--sr", type=float, default=48000.0)
    c.add_argument("--scale", type=float, default=1.0)

    pr = sub.add_parser("process", help="Process stereo float32 LE interleaved PCM on stdin→stdout")
    pr.add_argument("--profile", default="cinema", choices=list(PROFILES))
    pr.add_argument("--sr", type=float, default=48000.0)
    pr.add_argument("--scale", type=float, default=1.0)

    op = sub.add_parser("optimize", help="Read PCM, print optimized band gains JSON")
    op.add_argument("--profile", default="cinema", choices=list(PROFILES))
    op.add_argument("--sr", type=float, default=48000.0)

    sub.add_parser("selftest")

    args = p.parse_args(argv)

    if args.cmd == "selftest":
        selftest()
        return 0

    if args.cmd == "coeffs":
        print(json.dumps(coeffs_json(args.profile, args.sr, args.scale), indent=2))
        return 0

    if args.cmd == "process":
        raw = sys.stdin.buffer.read()
        fl, mk = build_chain(args.profile, args.sr, args.scale)
        fr = [f.clone() for f in fl]
        sys.stdout.buffer.write(process_interleaved_stereo(raw, fl, fr, mk))
        return 0

    if args.cmd == "optimize":
        raw = sys.stdin.buffer.read()
        n = len(raw) // 4
        samples = list(struct.unpack("<" + "f" * n, raw[: n * 4]))
        # mono mix if stereo interleaved
        mono = []
        for i in range(0, len(samples) - 1, 2):
            mono.append(0.5 * (samples[i] + samples[i + 1]))
        if not mono:
            mono = samples
        bands, makeup = optimize_gains(args.profile, args.sr, mono[: min(len(mono), int(args.sr * 4))])
        print(
            json.dumps(
                {
                    "profile": args.profile,
                    "makeup": makeup,
                    "bands": [asdict(b) for b in bands],
                },
                indent=2,
            )
        )
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
