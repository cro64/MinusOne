#!/usr/bin/env python3
"""Pulls MUSDB18 tracks (via the `musdb` pip package) and dumps them to wav files in the layout
SeparationQualityBenchmarkTests.swift and evaluate_separation.py expect:

    .musdb18/tracks/<track-name>/{mixture,vocals,drums,bass,other}.wav

`.musdb18/` is gitignored -- nothing this script writes belongs in version control. MUSDB18 is
CC-BY-NC-SA 4.0 (Rafii et al., https://doi.org/10.5281/zenodo.1117372): non-commercial evaluation
use only, and this script downloads it to your own machine -- it does not redistribute it.

Requires ffmpeg on PATH (musdb's STEMS files are decoded via stempeg -> ffmpeg):
    brew install ffmpeg
    pip install musdb

Usage:
    # Default: auto-downloads the small 7-second-preview subset (fast, no manual steps).
    python3 Scripts/fetch_musdb18.py --limit 5

    # Full-length tracks: requires MUSDB18 already downloaded and extracted by hand from
    # https://sigsep.github.io/datasets/musdb.html (the full dataset needs you to accept its
    # terms on Zenodo -- it can't be auto-downloaded), pointed at with --root.
    python3 Scripts/fetch_musdb18.py --limit 5 --full --root ~/Downloads/musdb18
    python3 Scripts/fetch_musdb18.py --limit 5 --full --hq --root ~/Downloads/musdb18-hq

Then:
    swift test --filter SeparationQualityBenchmarkTests
"""
import argparse
import sys
import wave
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROOT = REPO_ROOT / ".musdb18" / "raw"
DEFAULT_OUT = REPO_ROOT / ".musdb18" / "tracks"

# Matches SeparationStem.allCases exactly (confirmed against musdb's own configs/mus.yaml).
TARGET_NAMES = ("vocals", "drums", "bass", "other")


def write_wav(path: Path, audio: np.ndarray, samplerate: float, sampwidth: int = 2) -> None:
    if audio.ndim == 1:
        audio = audio[:, None]
    max_val = float(2 ** (8 * sampwidth - 1) - 1)
    clipped = np.clip(audio, -1.0, 1.0)
    ints = (clipped * max_val).astype({2: np.int16, 4: np.int32}[sampwidth])
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(audio.shape[1])
        wf.setsampwidth(sampwidth)
        wf.setframerate(int(round(samplerate)))
        wf.writeframes(ints.tobytes())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", type=int, default=5, help="number of tracks to dump (default: 5)")
    parser.add_argument("--subset", choices=["train", "test"], default="test")
    parser.add_argument(
        "--full", action="store_true",
        help="use a manually-downloaded full dataset at --root instead of auto-downloading the 7s preview"
    )
    parser.add_argument("--hq", action="store_true", help="with --full: the dataset at --root is MUSDB18-HQ (wav), not the original STEMS (mp4)")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="musdb's own dataset root (default: .musdb18/raw)")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="where to write the dumped per-track wav files")
    args = parser.parse_args()

    try:
        import musdb
    except ImportError:
        print("error: the `musdb` package is required -- run: pip install musdb", file=sys.stderr)
        return 1

    if args.full:
        if not args.root.exists():
            print(
                f"error: --full requires an already-extracted MUSDB18 at --root (got: {args.root}, does not exist).\n"
                "Download it by hand from https://sigsep.github.io/datasets/musdb.html (accepting its terms is "
                "required, so this can't be automated) and point --root at the extracted folder.",
                file=sys.stderr,
            )
            return 1
        db = musdb.DB(root=str(args.root), subsets=[args.subset], download=False, is_wav=args.hq)
    else:
        args.root.mkdir(parents=True, exist_ok=True)
        print(f"Downloading MUSDB18 7s-preview subset={args.subset} to {args.root} ...")
        db = musdb.DB(root=str(args.root), subsets=[args.subset], download=True, is_wav=False)

    tracks = db.tracks[: args.limit]
    if not tracks:
        print("error: musdb returned no tracks -- check --subset/--full/--root", file=sys.stderr)
        return 1

    args.out.mkdir(parents=True, exist_ok=True)
    for track in tracks:
        track_dir = args.out / track.name.replace("/", "_")
        print(f"  {track.name} -> {track_dir}")
        write_wav(track_dir / "mixture.wav", track.audio, track.rate)
        for name in TARGET_NAMES:
            target = track.targets.get(name)
            if target is None:
                print(f"    warning: no '{name}' target for {track.name}", file=sys.stderr)
                continue
            write_wav(track_dir / f"{name}.wav", target.audio, target.rate)

    print(f"Dumped {len(tracks)} track(s) to {args.out}")
    print("Run: swift test --filter SeparationQualityBenchmarkTests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
