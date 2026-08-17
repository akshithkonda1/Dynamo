#!/usr/bin/env python3
"""
Dynamo Tone AI — on-device genre / tone intelligence for Amplify EQ.

Design constraints (product):
  • No cloud APIs, no network calls.
  • No on-device storage of audio, scrapes, or user listening history.
  • Python owns the model definition + offline training; Swift mirrors
    inference for the realtime process-tap path.
  • Optional developer training can read local music libraries / PCM folders
    (or synthetic prototypes). Only fitted **weights** are exported — never the
    source audio.

Usage:
  python3 dynamo_tone_ai.py selftest
  python3 dynamo_tone_ai.py classify --features '{"bass_ratio":0.4,"brightness":0.2,...}'
  python3 dynamo_tone_ai.py analyze --sr 48000 < stereo.f32le
  python3 dynamo_tone_ai.py train --synthetic   # refit embedded weights (dev)
  python3 dynamo_tone_ai.py train --pcm-dir /path/to/wav_or_f32le_labeled
  python3 dynamo_tone_ai.py export-weights      # print JSON for embedding

Labeled PCM layout for train --pcm-dir (developer machine only):
  pcm_dir/pop/*.f32le | *.wav
  pcm_dir/classical/...
  Genre folder name must match GENRES.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys
import wave
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# Genre set + EQ bias (dB offsets applied lightly on Amplify bands)
# ---------------------------------------------------------------------------

GENRES: Tuple[str, ...] = (
    "pop",
    "classical",
    "electronic",
    "hiphop",
    "rock",
    "jazz",
    "speech",
    "ambient",
    "metal",
    "folk",
    "unknown",
)

# Feature order for the linear classifier (matches Swift AmplifyToneAI).
FEATURE_KEYS: Tuple[str, ...] = (
    "bass_ratio",
    "brightness",
    "crest_norm",
    "zcr",
    "dr_norm",
    "speech_likelihood",
    "bandwidth_norm",
    "mid_ratio",
    "bias",  # always 1.0
)

# Band labels align with dynamo_eq NOTE_REGIONS / BASE_PROFILES.
GENRE_EQ_BIAS: Dict[str, Dict[str, float]] = {
    # Pop — mild punch + presence, controlled mud
    "pop": {
        "sub": 0.15,
        "punch": 0.55,
        "body": 0.25,
        "mud": -0.45,
        "warmth": 0.10,
        "presence": 0.65,
        "sheen": 0.35,
        "air": 0.20,
        "brilliance": 0.10,
    },
    # Classical / orchestral — preserve dynamics, gentle air, no bass hype
    "classical": {
        "sub": -0.25,
        "punch": -0.20,
        "body": 0.15,
        "mud": -0.55,
        "warmth": 0.30,
        "presence": 0.25,
        "sheen": 0.40,
        "air": 0.55,
        "brilliance": 0.35,
    },
    # Electronic — sub weight, controlled highs
    "electronic": {
        "sub": 0.75,
        "punch": 0.45,
        "body": 0.10,
        "mud": -0.35,
        "warmth": -0.10,
        "presence": 0.20,
        "sheen": 0.15,
        "air": -0.10,
        "brilliance": -0.05,
    },
    # Hip-hop / R&B — deep sub, smooth mids
    "hiphop": {
        "sub": 0.90,
        "punch": 0.55,
        "body": 0.20,
        "mud": -0.50,
        "warmth": 0.25,
        "presence": 0.30,
        "sheen": -0.10,
        "air": -0.15,
        "brilliance": -0.20,
    },
    # Rock — body + presence, tame harsh sheen
    "rock": {
        "sub": 0.20,
        "punch": 0.40,
        "body": 0.55,
        "mud": -0.40,
        "warmth": 0.20,
        "presence": 0.50,
        "sheen": -0.25,
        "air": 0.05,
        "brilliance": -0.15,
    },
    # Jazz — warmth, air, low compression feel
    "jazz": {
        "sub": -0.10,
        "punch": 0.05,
        "body": 0.30,
        "mud": -0.35,
        "warmth": 0.55,
        "presence": 0.25,
        "sheen": 0.30,
        "air": 0.40,
        "brilliance": 0.15,
    },
    # Speech / podcast — presence clarity, cut rumble
    "speech": {
        "sub": -0.80,
        "punch": -0.40,
        "body": 0.10,
        "mud": -0.70,
        "warmth": 0.15,
        "presence": 1.00,
        "sheen": 0.35,
        "air": 0.15,
        "brilliance": 0.05,
    },
    # Ambient — soft sub, open air, no punch hype
    "ambient": {
        "sub": 0.30,
        "punch": -0.30,
        "body": 0.20,
        "mud": -0.20,
        "warmth": 0.40,
        "presence": -0.15,
        "sheen": 0.25,
        "air": 0.50,
        "brilliance": 0.30,
    },
    # Metal — tight lows, presence cut mud, control harsh HF
    "metal": {
        "sub": 0.35,
        "punch": 0.50,
        "body": 0.45,
        "mud": -0.70,
        "warmth": -0.15,
        "presence": 0.55,
        "sheen": -0.40,
        "air": -0.20,
        "brilliance": -0.25,
    },
    # Folk / acoustic — body warmth, natural air
    "folk": {
        "sub": -0.15,
        "punch": 0.10,
        "body": 0.45,
        "mud": -0.30,
        "warmth": 0.50,
        "presence": 0.35,
        "sheen": 0.20,
        "air": 0.35,
        "brilliance": 0.15,
    },
    "unknown": {},
}

# Metadata keyword → genre prior (local Music/Spotify genre strings — no API).
METADATA_KEYWORDS: Dict[str, Tuple[str, ...]] = {
    "pop": ("pop", "dance pop", "synth-pop", "k-pop", "electropop", "teen pop"),
    "classical": (
        "classical",
        "orchestral",
        "symphony",
        "opera",
        "baroque",
        "chamber",
        "mozart",
        "bach",
        "beethoven",
        "romantic era",
    ),
    "electronic": (
        "electronic",
        "edm",
        "house",
        "techno",
        "trance",
        "dubstep",
        "drum and bass",
        "synthwave",
        "electro",
    ),
    "hiphop": ("hip-hop", "hip hop", "rap", "trap", "r&b", "rnb", "soul"),
    "rock": ("rock", "indie rock", "alternative", "punk", "grunge", "hard rock"),
    "jazz": ("jazz", "swing", "bebop", "blues", "smooth jazz"),
    "speech": ("podcast", "audiobook", "spoken", "speech", "comedy", "interview"),
    "ambient": ("ambient", "chillout", "downtempo", "new age", "drone"),
    "metal": ("metal", "death metal", "black metal", "thrash", "hardcore"),
    "folk": ("folk", "acoustic", "country", "bluegrass", "americana", "singer-songwriter"),
}


# ---------------------------------------------------------------------------
# Embedded classifier weights (genre × feature). Fitted offline; shipped only
# as numbers — never as training audio. Softmax over linear scores.
# Rows follow GENRES order; columns follow FEATURE_KEYS.
# ---------------------------------------------------------------------------

# Hand-seeded + synthetic-refined prior. `train --synthetic` can regenerate.
_WEIGHTS: List[List[float]] = [
    # pop: balanced, moderate brightness, mid crest
    [0.4, 0.8, 0.3, 0.2, 0.1, -0.8, 0.5, 0.6, 0.2],
    # classical: low bass, high DR/crest, air
    [-1.2, 0.6, 1.4, -0.3, 1.6, -0.5, 1.0, 0.3, -0.1],
    # electronic: high bass, moderate brightness
    [1.6, 0.4, -0.4, 0.1, -0.3, -0.9, 0.6, -0.2, 0.1],
    # hiphop: very high bass, lower HF
    [2.0, -0.6, -0.5, -0.2, -0.4, -0.7, 0.2, -0.3, 0.15],
    # rock: mid body, moderate bass, some HF
    [0.3, 0.5, 0.2, 0.3, 0.0, -0.6, 0.5, 0.8, 0.1],
    # jazz: warm mids, moderate DR
    [-0.3, 0.2, 0.6, 0.1, 0.7, -0.4, 0.4, 0.5, 0.05],
    # speech: high ZCR, mid energy, low bass
    [-1.5, 0.3, 0.2, 2.2, 0.3, 2.5, -0.4, 1.2, 0.0],
    # ambient: soft crest, open air, soft punch
    [0.5, 0.4, -0.8, -0.4, 0.4, -0.5, 0.7, -0.2, 0.0],
    # metal: dense mids, controlled HF, punch
    [0.6, 0.3, -0.2, 0.4, -0.5, -0.7, 0.3, 1.0, 0.1],
    # folk: acoustic body, mild bass
    [-0.4, 0.2, 0.5, 0.0, 0.5, -0.3, 0.3, 0.6, 0.05],
    # unknown: flat prior
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
]


@dataclass
class ToneFeatures:
    bass_ratio: float
    brightness: float
    crest_db: float
    zcr: float
    dynamic_range_db: float
    speech_likelihood: float
    bandwidth_hz: float
    mid_ratio: float = 0.33

    def vector(self) -> List[float]:
        return [
            _clamp01(self.bass_ratio),
            _clamp01(self.brightness),
            _clamp01(self.crest_db / 20.0),
            _clamp01(self.zcr * 2.5),
            _clamp01(self.dynamic_range_db / 28.0),
            _clamp01(self.speech_likelihood),
            _clamp01(self.bandwidth_hz / 16000.0),
            _clamp01(self.mid_ratio),
            1.0,
        ]


@dataclass
class ToneVerdict:
    genre: str
    confidence: float
    scores: Dict[str, float]
    eq_bias: Dict[str, float]
    makeup_mul: float
    hf_mul: float
    source: str  # "audio" | "metadata" | "blend"
    notes: List[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def _clamp01(x: float) -> float:
    return max(0.0, min(1.0, float(x)))


def _softmax(xs: Sequence[float]) -> List[float]:
    m = max(xs) if xs else 0.0
    exps = [math.exp(x - m) for x in xs]
    s = sum(exps) + 1e-12
    return [e / s for e in exps]


def metadata_genre_prior(text: Optional[str]) -> Optional[Tuple[str, float]]:
    """Map a free-text genre/artist/album blob to a genre prior. Local only."""
    if not text:
        return None
    blob = text.lower()
    best: Optional[str] = None
    best_hits = 0
    for genre, keys in METADATA_KEYWORDS.items():
        hits = sum(1 for k in keys if k in blob)
        if hits > best_hits:
            best_hits = hits
            best = genre
    if best is None or best_hits == 0:
        return None
    conf = min(0.92, 0.45 + 0.15 * best_hits)
    return best, conf


def classify_features(
    features: ToneFeatures,
    metadata_text: Optional[str] = None,
    session_ema: Optional[List[float]] = None,
) -> ToneVerdict:
    """
    Infer genre from live features + optional metadata prior.

    session_ema: optional in-memory feature EMA (length = len(FEATURE_KEYS)-1
    without bias). Used for ephemeral adaptation during a session; caller must
    not persist it.
    """
    vec = features.vector()
    if session_ema and len(session_ema) == len(FEATURE_KEYS) - 1:
        # Light blend with session EMA (ephemeral learning, no disk).
        blended = []
        for i, v in enumerate(vec[:-1]):
            blended.append(0.72 * v + 0.28 * session_ema[i])
        blended.append(1.0)
        vec = blended

    scores_list: List[float] = []
    for row in _WEIGHTS:
        s = sum(w * x for w, x in zip(row, vec))
        scores_list.append(s)
    probs = _softmax(scores_list)
    score_map = {g: round(p, 4) for g, p in zip(GENRES, probs)}
    audio_idx = max(range(len(probs)), key=lambda i: probs[i])
    audio_genre = GENRES[audio_idx]
    audio_conf = probs[audio_idx]

    source = "audio"
    genre = audio_genre
    conf = audio_conf
    notes: List[str] = []

    meta = metadata_genre_prior(metadata_text)
    if meta:
        m_genre, m_conf = meta
        m_idx = GENRES.index(m_genre) if m_genre in GENRES else -1
        if m_idx >= 0:
            # Blend metadata prior into softmax (no external lookup).
            boosted = list(scores_list)
            boosted[m_idx] += 1.8 * m_conf
            probs2 = _softmax(boosted)
            score_map = {g: round(p, 4) for g, p in zip(GENRES, probs2)}
            idx2 = max(range(len(probs2)), key=lambda i: probs2[i])
            genre = GENRES[idx2]
            conf = probs2[idx2]
            source = "blend" if audio_genre != genre else "metadata"
            notes.append(f"metadata prior {m_genre}@{m_conf:.2f}")

    if conf < 0.28:
        genre = "unknown"
        conf = max(conf, 0.2)
        notes.append("low confidence → unknown")

    bias = dict(GENRE_EQ_BIAS.get(genre, {}))
    makeup_mul, hf_mul = _live_multipliers(genre, features)

    return ToneVerdict(
        genre=genre,
        confidence=round(conf, 3),
        scores=score_map,
        eq_bias=bias,
        makeup_mul=makeup_mul,
        hf_mul=hf_mul,
        source=source,
        notes=notes,
    )


def _live_multipliers(genre: str, f: ToneFeatures) -> Tuple[float, float]:
    """Gentle live targets for Swift process-tap path."""
    makeup = 1.0
    hf = 1.0
    if genre == "classical":
        makeup = 0.94
        hf = 1.02
    elif genre == "pop":
        makeup = 1.01
        hf = 0.98
    elif genre == "electronic":
        makeup = 1.02
        hf = 0.94
    elif genre == "hiphop":
        makeup = 1.03
        hf = 0.90
    elif genre == "rock":
        makeup = 1.00
        hf = 0.93
    elif genre == "jazz":
        makeup = 0.97
        hf = 1.00
    elif genre == "speech":
        makeup = 0.96
        hf = 1.0
    elif genre == "ambient":
        makeup = 0.98
        hf = 1.03
    elif genre == "metal":
        makeup = 0.99
        hf = 0.88
    elif genre == "folk":
        makeup = 0.98
        hf = 1.0

    # Content-aware soft push from features
    if f.brightness > 0.5:
        hf *= 0.95
    if f.bass_ratio > 0.4:
        makeup = min(1.05, makeup + 0.01)
    if f.speech_likelihood > 0.55:
        makeup = min(makeup, 0.97)
        hf = min(1.02, max(0.95, hf))

    return (
        max(0.88, min(1.08, makeup)),
        max(0.80, min(1.05, hf)),
    )


def apply_genre_bias_to_bands(
    bands: list,
    genre: str,
    intensity: float = 0.45,
    gain_cap: float = 2.5,
) -> None:
    """Mutate BandSpec-like objects (gain_db + label) with genre EQ bias."""
    bias = GENRE_EQ_BIAS.get(genre) or {}
    if not bias or intensity <= 0:
        return
    for b in bands:
        label = getattr(b, "label", None) or ""
        if label in bias:
            b.gain_db = max(-gain_cap, min(gain_cap, b.gain_db + bias[label] * intensity))


# ---------------------------------------------------------------------------
# Feature extraction from PCM (reuse band energy style from dynamo_eq)
# ---------------------------------------------------------------------------


def features_from_mono(samples: Sequence[float], sr: float) -> ToneFeatures:
    n = len(samples)
    if n < 256:
        samples = list(samples) + [0.0] * (256 - n)
        n = len(samples)
    max_n = min(n, int(sr * 3))
    step = max(1, max_n // 12000)
    mono = [samples[i] for i in range(0, max_n, step)]

    def rms(xs: Sequence[float]) -> float:
        return math.sqrt(sum(x * x for x in xs) / max(1, len(xs))) + 1e-12

    r = rms(mono)
    peak = max(abs(x) for x in mono) + 1e-12
    crest_db = 20 * math.log10(peak / r)

    frame = max(64, len(mono) // 40)
    frame_rms = [rms(mono[i : i + frame]) for i in range(0, len(mono) - frame, frame)]
    frame_rms.sort()
    if frame_rms:
        lo = frame_rms[max(0, len(frame_rms) // 20)]
        hi = frame_rms[min(len(frame_rms) - 1, (19 * len(frame_rms)) // 20)]
        dr_db = 20 * math.log10((hi + 1e-12) / (lo + 1e-12))
    else:
        dr_db = crest_db

    zc = sum(1 for i in range(1, len(mono)) if (mono[i - 1] >= 0) != (mono[i] >= 0))
    zcr = zc / max(1, len(mono))

    # Cheap band energy via RMS of simple IIR high/low shelves is in dynamo_eq;
    # here use block spectral proxies via differencing + envelope.
    def band_proxy(lo_ratio: float, hi_ratio: float) -> float:
        # Differentiate → high emphasis; integrate-ish → low.
        acc = 0.0
        prev = 0.0
        alpha_hi = min(0.95, hi_ratio)
        alpha_lo = min(0.95, lo_ratio)
        y_lp = 0.0
        y_bp = 0.0
        for x in mono:
            y_lp = y_lp + alpha_lo * (x - y_lp)
            hp = x - y_lp
            y_bp = y_bp + alpha_hi * (hp - y_bp)
            band = hp - y_bp
            acc += band * band
            prev = x
        return math.sqrt(acc / max(1, len(mono))) + 1e-12

    e_sub = band_proxy(0.02, 0.08)
    e_mid = band_proxy(0.08, 0.35)
    e_high = band_proxy(0.35, 0.85)
    e_all = e_sub + e_mid + e_high + 1e-12
    bass_ratio = e_sub / e_all
    brightness = e_high / e_all
    mid_ratio = e_mid / e_all

    bandwidth = 4000.0
    for f_hi in (6000, 8000, 10000, 12000, 14000, 16000):
        # crude: more diff energy → higher bandwidth
        if e_high > r * (0.02 + (16000 - f_hi) / 16000 * 0.03):
            bandwidth = float(f_hi)

    speech = min(1.0, max(0.0, (zcr - 0.05) * 4.0 + (0.35 - bass_ratio) * 1.5))
    if mid_ratio > 0.45 and bass_ratio < 0.25:
        speech = min(1.0, speech + 0.25)

    return ToneFeatures(
        bass_ratio=round(bass_ratio, 4),
        brightness=round(brightness, 4),
        crest_db=round(crest_db, 3),
        zcr=round(zcr, 4),
        dynamic_range_db=round(dr_db, 3),
        speech_likelihood=round(speech, 4),
        bandwidth_hz=bandwidth,
        mid_ratio=round(mid_ratio, 4),
    )


def features_from_analysis_dict(d: dict) -> ToneFeatures:
    """Build features from dynamo_eq.MediaAnalysis-like dict."""
    return ToneFeatures(
        bass_ratio=float(d.get("bass_ratio", 0.2)),
        brightness=float(d.get("brightness", 0.25)),
        crest_db=float(d.get("crest_db", 10)),
        zcr=float(d.get("zcr", 0.08)),
        dynamic_range_db=float(d.get("dynamic_range_db", 12)),
        speech_likelihood=float(d.get("speech_likelihood", 0.1)),
        bandwidth_hz=float(d.get("bandwidth_hz", 10000)),
        mid_ratio=float(d.get("mid_ratio", 0.33)),
    )


# ---------------------------------------------------------------------------
# Offline training (developer machine) — weights only, never store audio
# ---------------------------------------------------------------------------


def _synthetic_prototypes() -> List[Tuple[str, ToneFeatures]]:
    """Handcrafted feature prototypes for each genre (no audio stored)."""
    proto = {
        "pop": ToneFeatures(0.22, 0.32, 9.0, 0.09, 10.0, 0.08, 12000, 0.40),
        "classical": ToneFeatures(0.12, 0.30, 16.0, 0.06, 22.0, 0.05, 14000, 0.35),
        "electronic": ToneFeatures(0.42, 0.28, 7.0, 0.08, 8.0, 0.04, 13000, 0.28),
        "hiphop": ToneFeatures(0.48, 0.18, 6.5, 0.07, 7.0, 0.06, 10000, 0.25),
        "rock": ToneFeatures(0.25, 0.30, 10.0, 0.10, 11.0, 0.05, 12000, 0.42),
        "jazz": ToneFeatures(0.18, 0.26, 13.0, 0.07, 16.0, 0.04, 13000, 0.38),
        "speech": ToneFeatures(0.10, 0.28, 11.0, 0.22, 14.0, 0.75, 8000, 0.55),
        "ambient": ToneFeatures(0.28, 0.35, 5.0, 0.04, 12.0, 0.03, 14000, 0.30),
        "metal": ToneFeatures(0.30, 0.27, 8.0, 0.12, 7.0, 0.04, 11000, 0.48),
        "folk": ToneFeatures(0.15, 0.24, 12.0, 0.06, 15.0, 0.05, 12000, 0.40),
        "unknown": ToneFeatures(0.22, 0.25, 10.0, 0.08, 12.0, 0.1, 11000, 0.33),
    }
    out: List[Tuple[str, ToneFeatures]] = []
    for g, f in proto.items():
        out.append((g, f))
        # Mild jitter copies for margin
        for j in range(4):
            scale = 0.92 + 0.04 * j
            out.append(
                (
                    g,
                    ToneFeatures(
                        _clamp01(f.bass_ratio * scale),
                        _clamp01(f.brightness * (2 - scale)),
                        f.crest_db * scale,
                        _clamp01(f.zcr * scale),
                        f.dynamic_range_db * scale,
                        _clamp01(f.speech_likelihood * scale),
                        f.bandwidth_hz,
                        _clamp01(f.mid_ratio * scale),
                    ),
                )
            )
    return out


def train_weights(
    samples: Sequence[Tuple[str, ToneFeatures]],
    epochs: int = 80,
    lr: float = 0.35,
) -> List[List[float]]:
    """
    Multinomial logistic regression (one-vs-all style softmax).
    In-memory only; returns new weight matrix. Does not write datasets.
    """
    g_index = {g: i for i, g in enumerate(GENRES)}
    w = [row[:] for row in _WEIGHTS]
    n_f = len(FEATURE_KEYS)

    for _ in range(epochs):
        for genre, feat in samples:
            if genre not in g_index:
                continue
            y = g_index[genre]
            x = feat.vector()
            logits = [sum(w[i][j] * x[j] for j in range(n_f)) for i in range(len(GENRES))]
            p = _softmax(logits)
            for i in range(len(GENRES)):
                err = p[i] - (1.0 if i == y else 0.0)
                for j in range(n_f):
                    w[i][j] -= lr * err * x[j]
    return w


def set_weights(w: List[List[float]]) -> None:
    global _WEIGHTS
    assert len(w) == len(GENRES)
    assert all(len(row) == len(FEATURE_KEYS) for row in w)
    _WEIGHTS = [row[:] for row in w]


def load_pcm_dir(root: Path) -> List[Tuple[str, ToneFeatures]]:
    """
    Load labeled PCM for training. Supports .f32le (mono/stereo interleaved float32)
    and .wav. Audio is read, features extracted, samples discarded — never saved.
    """
    out: List[Tuple[str, ToneFeatures]] = []
    if not root.is_dir():
        return out
    for genre_dir in sorted(root.iterdir()):
        if not genre_dir.is_dir():
            continue
        genre = genre_dir.name.lower().replace(" ", "").replace("-", "")
        # normalize
        aliases = {
            "hip-hop": "hiphop",
            "hiphop": "hiphop",
            "rnb": "hiphop",
            "edm": "electronic",
            "classicalmusic": "classical",
        }
        genre = aliases.get(genre, genre)
        if genre not in GENRES:
            continue
        for path in genre_dir.rglob("*"):
            if path.suffix.lower() not in (".f32le", ".raw", ".wav", ".pcm"):
                continue
            try:
                mono, sr = _read_audio_file(path)
            except Exception:
                continue
            if len(mono) < 1024:
                continue
            feats = features_from_mono(mono, sr)
            out.append((genre, feats))
            # Explicitly drop audio references
            del mono
    return out


def _read_audio_file(path: Path) -> Tuple[List[float], float]:
    if path.suffix.lower() == ".wav":
        with wave.open(str(path), "rb") as w:
            sr = w.getframerate()
            nch = w.getnchannels()
            sw = w.getsampwidth()
            nframes = w.getnframes()
            raw = w.readframes(min(nframes, sr * 4))
        if sw == 2:
            ints = struct.unpack("<" + "h" * (len(raw) // 2), raw)
            samples = [i / 32768.0 for i in ints]
        elif sw == 4:
            ints = struct.unpack("<" + "i" * (len(raw) // 4), raw)
            samples = [i / 2147483648.0 for i in ints]
        else:
            samples = [0.0]
        if nch > 1:
            mono = [
                sum(samples[i : i + nch]) / nch for i in range(0, len(samples) - nch + 1, nch)
            ]
        else:
            mono = samples
        return mono, float(sr)

    # float32 LE interleaved stereo assumed @ 48k unless name has _44100
    data = path.read_bytes()
    n = len(data) // 4
    floats = list(struct.unpack("<" + "f" * n, data[: n * 4]))
    sr = 44100.0 if "44100" in path.name else 48000.0
    # assume stereo interleaved
    if len(floats) >= 4:
        mono = [(floats[i] + floats[i + 1]) * 0.5 for i in range(0, len(floats) - 1, 2)]
    else:
        mono = floats
    return mono, sr


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _cmd_selftest() -> int:
    # Metadata: Mozart → classical
    v = classify_features(
        ToneFeatures(0.15, 0.3, 14, 0.06, 18, 0.05, 14000, 0.35),
        metadata_text="Mozart Piano Concerto classical orchestral",
    )
    assert v.genre == "classical", v
    assert v.confidence > 0.3

    # Bass-heavy electronic-like features
    v2 = classify_features(
        ToneFeatures(0.45, 0.25, 7, 0.08, 8, 0.04, 12000, 0.28),
        metadata_text=None,
    )
    assert v2.genre in ("electronic", "hiphop", "unknown"), v2

    # Speech
    v3 = classify_features(
        ToneFeatures(0.1, 0.3, 10, 0.22, 12, 0.8, 8000, 0.5),
        metadata_text="Podcast interview",
    )
    assert v3.genre == "speech", v3

    # Pop metadata
    v4 = classify_features(
        ToneFeatures(0.22, 0.32, 9, 0.09, 10, 0.08, 12000, 0.4),
        metadata_text="Dance Pop",
    )
    assert v4.genre == "pop", v4

    # Train synthetic refines without error
    w = train_weights(_synthetic_prototypes(), epochs=20, lr=0.4)
    assert len(w) == len(GENRES)

    # No genre bias mutation crashes
    class B:
        def __init__(self, label: str, g: float):
            self.label = label
            self.gain_db = g

    bands = [B("punch", 0.0), B("presence", 0.0)]
    apply_genre_bias_to_bands(bands, "pop", 0.5)
    assert bands[0].gain_db != 0.0

    print("dynamo_tone_ai selftest OK")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(description="Dynamo on-device tone / genre AI")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("selftest")

    c = sub.add_parser("classify")
    c.add_argument("--features", required=True, help="JSON feature object")
    c.add_argument("--metadata", default="", help="local genre/title/artist text")

    a = sub.add_parser("analyze")
    a.add_argument("--sr", type=float, default=48000)
    a.add_argument("--metadata", default="")
    a.add_argument("--channels", type=int, default=2)

    t = sub.add_parser("train")
    t.add_argument("--synthetic", action="store_true")
    t.add_argument("--pcm-dir", type=str, default="")
    t.add_argument("--epochs", type=int, default=80)
    t.add_argument("--export", action="store_true", help="print weights JSON after train")

    sub.add_parser("export-weights")
    sub.add_parser("list-genres")

    args = p.parse_args(argv)

    if args.cmd == "selftest":
        return _cmd_selftest()

    if args.cmd == "list-genres":
        print(json.dumps({"genres": list(GENRES), "features": list(FEATURE_KEYS)}, indent=2))
        return 0

    if args.cmd == "export-weights":
        print(json.dumps({"genres": list(GENRES), "features": list(FEATURE_KEYS), "weights": _WEIGHTS}, indent=2))
        return 0

    if args.cmd == "classify":
        d = json.loads(args.features)
        feats = features_from_analysis_dict(d) if "bass_ratio" in d else ToneFeatures(**d)
        v = classify_features(feats, metadata_text=args.metadata or None)
        print(json.dumps(v.to_dict(), indent=2))
        return 0

    if args.cmd == "analyze":
        raw = sys.stdin.buffer.read()
        n = len(raw) // 4
        floats = list(struct.unpack("<" + "f" * n, raw[: n * 4])) if n else []
        ch = max(1, args.channels)
        if ch > 1 and floats:
            mono = [
                sum(floats[i : i + ch]) / ch for i in range(0, len(floats) - ch + 1, ch)
            ]
        else:
            mono = floats
        feats = features_from_mono(mono, args.sr)
        v = classify_features(feats, metadata_text=args.metadata or None)
        print(json.dumps({"features": asdict(feats), "verdict": v.to_dict()}, indent=2))
        return 0

    if args.cmd == "train":
        samples: List[Tuple[str, ToneFeatures]] = []
        if args.synthetic or not args.pcm_dir:
            samples.extend(_synthetic_prototypes())
        if args.pcm_dir:
            loaded = load_pcm_dir(Path(args.pcm_dir))
            samples.extend(loaded)
            print(f"# loaded {len(loaded)} feature vectors from PCM (audio discarded)", file=sys.stderr)
        if not samples:
            print("no training samples", file=sys.stderr)
            return 2
        w = train_weights(samples, epochs=args.epochs)
        set_weights(w)
        print(f"# trained on {len(samples)} in-memory feature rows", file=sys.stderr)
        if args.export:
            print(json.dumps({"genres": list(GENRES), "features": list(FEATURE_KEYS), "weights": w}, indent=2))
        else:
            print("train complete — use --export to emit weights JSON (audio never written)")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
