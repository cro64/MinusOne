#!/usr/bin/env python3
"""Scores MinusOne's separated stems against known-clean ground truth using SI-SDR.

SI-SDR (scale-invariant signal-to-distortion ratio) is the same metric family
Demucs's own paper and the MUSDB18/SiSEC leaderboards report. It projects the
estimate onto the reference before measuring residual energy, so a stem that's
merely quieter or louder than the reference isn't penalized -- only actual
distortion, leakage from other stems, and pipeline artifacts are.

    SI-SDR(ref, est) = 10 * log10( ||alpha*ref||^2 / ||est - alpha*ref||^2 )
    where alpha = <est, ref> / <ref, ref>   (least-squares scale alignment)

Usage:
    python3 Scripts/evaluate_separation.py \
        --reference-dir /path/to/original_stems \
        --estimate-dir  /path/to/minusone_exported_stems

Expects both directories to contain vocals.wav, drums.wav, bass.wav, other.wav.
Also reports a "naive baseline" (SI-SDR if you just guessed each stem was silence,
and if you guessed each stem was the full mix) so the pipeline's numbers have
something concrete to beat, not just an abstract dB figure.
"""
import argparse
import sys
import wave
from pathlib import Path

import numpy as np

STEM_NAMES = ("vocals", "drums", "bass", "other")


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
    data /= float(2 ** (8 * sampwidth - 1))
    return data.reshape(-1, n_channels), framerate


def si_sdr(reference: np.ndarray, estimate: np.ndarray, eps: float = 1e-10) -> float:
    """Scale-invariant SDR in dB, flattened across channels."""
    ref = reference.flatten().astype(np.float64)
    est = estimate.flatten().astype(np.float64)
    n = min(ref.size, est.size)
    ref, est = ref[:n], est[:n]

    ref_energy = np.dot(ref, ref) + eps
    alpha = np.dot(est, ref) / ref_energy
    projection = alpha * ref
    noise = est - projection

    num = np.dot(projection, projection) + eps
    den = np.dot(noise, noise) + eps
    return 10.0 * np.log10(num / den)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reference-dir", type=Path, required=True)
    parser.add_argument("--estimate-dir", type=Path, required=True)
    parser.add_argument("--mix", type=Path, help="optional: the mixdown, to report the naive 'guess = mix' baseline")
    args = parser.parse_args()

    mix = None
    if args.mix:
        mix, _ = load_wav(args.mix)

    print(f"{'stem':<8} | {'SI-SDR (dB)':>12} | {'baseline: silence':>18} | {'baseline: mix':>14}")
    print("-" * 62)

    scores = []
    for stem in STEM_NAMES:
        ref_path = args.reference_dir / f"{stem}.wav"
        est_path = args.estimate_dir / f"{stem}.wav"
        if not ref_path.exists() or not est_path.exists():
            print(f"{stem:<8} | missing file(s): {ref_path if not ref_path.exists() else est_path}", file=sys.stderr)
            continue

        ref, _ = load_wav(ref_path)
        est, _ = load_wav(est_path)
        score = si_sdr(ref, est)
        scores.append(score)

        silence_baseline = si_sdr(ref, np.zeros_like(ref))
        mix_baseline = si_sdr(ref, mix) if mix is not None else float("nan")

        print(f"{stem:<8} | {score:>12.2f} | {silence_baseline:>18.2f} | {mix_baseline:>14.2f}")

    if scores:
        print("-" * 62)
        print(f"{'mean':<8} | {np.mean(scores):>12.2f}")
    else:
        print("no stems scored -- check --reference-dir / --estimate-dir contents", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
