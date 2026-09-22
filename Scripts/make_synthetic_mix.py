#!/usr/bin/env python3
"""Sums known-isolated stems into a single mixdown, for separation-quality evaluation.

Usage:
    python3 Scripts/make_synthetic_mix.py \
        --vocals vocals.wav --drums drums.wav --bass bass.wav --other other.wav \
        --out mix.wav

Feed the resulting mix.wav into MinusOne's Practice import (or Live capture),
export MinusOne's 4 separated stems, then compare them against the *original*
vocals/drums/bass/other files with evaluate_separation.py. Because the mix was
built from perfectly isolated sources, the ground truth is exact -- any
difference in the output is degradation introduced somewhere in MinusOne's own
pipeline (resampling, windowing/hop-splice, OLA normalization), not ambiguity
in what "correct separation" means.
"""
import argparse
import sys
import wave
from pathlib import Path

import numpy as np


def load_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as wf:
        n_channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        raw = wf.readframes(n_frames)

    dtype = {1: np.int8, 2: np.int16, 4: np.int32}.get(sampwidth)
    if dtype is None:
        raise ValueError(f"Unsupported sample width {sampwidth} bytes in {path}")

    data = np.frombuffer(raw, dtype=dtype).astype(np.float64)
    max_val = float(2 ** (8 * sampwidth - 1))
    data /= max_val
    data = data.reshape(-1, n_channels)
    return data, framerate


def write_wav(path: Path, data: np.ndarray, framerate: int, sampwidth: int = 2) -> None:
    max_val = float(2 ** (8 * sampwidth - 1) - 1)
    clipped = np.clip(data, -1.0, 1.0)
    ints = (clipped * max_val).astype({2: np.int16, 4: np.int32}[sampwidth])
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(data.shape[1])
        wf.setsampwidth(sampwidth)
        wf.setframerate(framerate)
        wf.writeframes(ints.tobytes())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vocals", type=Path, required=True)
    parser.add_argument("--drums", type=Path, required=True)
    parser.add_argument("--bass", type=Path, required=True)
    parser.add_argument("--other", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    stems = {}
    rates = set()
    for name in ("vocals", "drums", "bass", "other"):
        path = getattr(args, name)
        data, rate = load_wav(path)
        stems[name] = data
        rates.add(rate)

    if len(rates) != 1:
        print(f"error: stems have mismatched sample rates: {rates}", file=sys.stderr)
        return 1
    (rate,) = rates

    min_len = min(s.shape[0] for s in stems.values())
    channels = max(s.shape[1] for s in stems.values())

    mix = np.zeros((min_len, channels), dtype=np.float64)
    for name, data in stems.items():
        trimmed = data[:min_len]
        if trimmed.shape[1] == 1 and channels == 2:
            trimmed = np.repeat(trimmed, 2, axis=1)
        mix += trimmed

    peak = np.abs(mix).max()
    if peak > 1.0:
        print(f"note: summed mix peak={peak:.3f}, normalizing by {1.0 / peak:.4f} to avoid clipping")
        mix /= peak

    args.out.parent.mkdir(parents=True, exist_ok=True)
    write_wav(args.out, mix, rate)
    print(f"wrote {args.out} ({min_len / rate:.1f}s @ {rate}Hz, {channels}ch)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
