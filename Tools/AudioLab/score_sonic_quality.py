#!/usr/bin/env python3
"""Compare Sonic quality/tone variants against paired MacBook transcripts."""

from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import re

from faster_whisper import WhisperModel


DEFAULT_MODEL_CACHE = (
    Path(__file__).resolve().parents[2]
    / ".build/audio-lab/faster-whisper-models"
)


def timestamp(path: Path, prefix: str) -> datetime:
    return datetime.strptime(path.stem.removeprefix(prefix), "%Y-%m-%d %H.%M.%S")


def words(text: str) -> list[str]:
    return re.sub(r"[^a-z0-9 ]", "", text.lower()).split()


def distance(left: list[str], right: list[str]) -> int:
    previous = list(range(len(right) + 1))
    for row, left_word in enumerate(left, 1):
        current = [row]
        for column, right_word in enumerate(right, 1):
            current.append(min(
                previous[column] + 1,
                current[-1] + 1,
                previous[column - 1] + (left_word != right_word),
            ))
        previous = current
    return previous[-1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "reference_root",
        type=Path,
        help="directory containing paired DualSense and MacBook WAV files",
    )
    parser.add_argument(
        "replays_root",
        type=Path,
        help="directory containing rendered Sonic replay directories",
    )
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--end", type=int)
    parser.add_argument(
        "--model-cache",
        type=Path,
        default=DEFAULT_MODEL_CACHE,
        help="Faster Whisper model cache directory",
    )
    args = parser.parse_args()
    reference_root = args.reference_root.expanduser().resolve()
    replays_root = args.replays_root.expanduser().resolve()
    if not reference_root.is_dir():
        parser.error(f"reference directory does not exist: {reference_root}")
    if not replays_root.is_dir():
        parser.error(f"replay directory does not exist: {replays_root}")
    archives = sorted(replays_root.glob("DualSense Mic *"))
    archives = archives[args.start:args.end]
    mac_paths = sorted(reference_root.glob("MacBook Mic Reference *.wav"))
    if not mac_paths:
        parser.error("reference directory contains no MacBook Mic Reference WAV files")
    model = WhisperModel(
        "tiny.en",
        device="cpu",
        compute_type="int8",
        download_root=str(args.model_cache.expanduser()),
    )

    def transcribe(path: Path) -> str:
        segments, _ = model.transcribe(
            str(path),
            language="en",
            beam_size=5,
            condition_on_previous_text=False,
            vad_filter=False,
        )
        return " ".join(segment.text.strip() for segment in segments)

    totals = {name: [0, 0] for name in (
        "quality0-plain",
        "quality0-shelf",
        "quality1-plain",
        "quality1-shelf",
    )}
    for archive in archives:
        controller_path = reference_root / f"{archive.name}.wav"
        controller_time = timestamp(controller_path, "DualSense Mic ")
        mac_path = min(
            mac_paths,
            key=lambda path: abs(
                (timestamp(path, "MacBook Mic Reference ") - controller_time)
                .total_seconds()
            ),
        )
        candidates = {
            "quality0-plain": archive / "sonic-default-plain.wav",
            "quality0-shelf": archive / "sonic-default-shelf.wav",
            "quality1-plain": archive / "sonic-quality-plain.wav",
            "quality1-shelf": archive / "sonic-quality-shelf.wav",
        }
        reference_text = transcribe(mac_path)
        reference = words(reference_text)
        print(f"\n{archive.name} | {reference_text}", flush=True)
        for name, path in candidates.items():
            text = transcribe(path)
            edits = distance(reference, words(text))
            totals[name][0] += edits
            totals[name][1] += len(reference)
            print(
                f"  {name:15s} {edits:2d}/{len(reference):2d} "
                f"({edits / max(len(reference), 1):.3f}) | {text}",
                flush=True,
            )
    print("\nTOTALS", flush=True)
    for name, (edits, count) in totals.items():
        print(f"  {name:15s} {edits}/{count} ({edits / max(count, 1):.4f})", flush=True)


if __name__ == "__main__":
    main()
