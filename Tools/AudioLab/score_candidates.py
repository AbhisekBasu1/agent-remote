#!/usr/bin/env python3
"""Score rendered reconstruction candidates against paired MacBook transcripts.

Run with: uv run --no-project --with faster-whisper python3 score_candidates.py \
    /path/to/candidates /path/to/private-audio-fixtures

For every archive directory produced by render_reconstruction_candidates.py,
this transcribes the nearest-in-time MacBook reference and each candidate with
the same repeatable Faster Whisper settings the project has used in every
handoff round, then reports per-archive and total word edit distances. The
shipped live recording ("live-app") is included for context.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import json
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
        "candidates_root",
        type=Path,
        help="directory produced by render_reconstruction_candidates.py",
    )
    parser.add_argument(
        "reference_root",
        type=Path,
        help="directory containing paired DualSense and MacBook WAV files",
    )
    parser.add_argument(
        "--model-cache",
        type=Path,
        default=DEFAULT_MODEL_CACHE,
        help="Faster Whisper model cache directory",
    )
    args = parser.parse_args()
    candidates_root = args.candidates_root.expanduser().resolve()
    reference_root = args.reference_root.expanduser().resolve()
    if not candidates_root.is_dir():
        parser.error(f"candidate directory does not exist: {candidates_root}")
    if not reference_root.is_dir():
        parser.error(f"reference directory does not exist: {reference_root}")
    archives = sorted(path for path in candidates_root.iterdir() if path.is_dir())
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

    totals: dict[str, list[int]] = {}
    report: dict[str, dict] = {}
    for archive in archives:
        controller_time = timestamp(
            reference_root / f"{archive.name}.wav", "DualSense Mic "
        )
        mac_path = min(
            mac_paths,
            key=lambda path: abs(
                (timestamp(path, "MacBook Mic Reference ") - controller_time)
                .total_seconds()
            ),
        )
        reference_text = transcribe(mac_path)
        reference = words(reference_text)
        print(f"\n{archive.name}\n  reference | {reference_text}", flush=True)
        rows: dict[str, dict] = {}

        candidate_paths = {
            "live-app": reference_root / f"{archive.name}.wav"
        }
        for wav in sorted(archive.glob("*.wav")):
            candidate_paths[wav.stem] = wav
        for name, path in candidate_paths.items():
            if not path.exists():
                continue
            text = transcribe(path)
            edits = distance(reference, words(text))
            totals.setdefault(name, [0, 0])
            totals[name][0] += edits
            totals[name][1] += len(reference)
            rows[name] = {"edits": edits, "text": text}
            print(
                f"  {name:15s} {edits:2d}/{len(reference):2d} "
                f"({edits / max(len(reference), 1):.3f}) | {text}",
                flush=True,
            )
        report[archive.name] = {
            "reference": reference_text,
            "referenceWords": len(reference),
            "candidates": rows,
        }

    print("\nTOTALS", flush=True)
    for name, (edits, count) in sorted(
        totals.items(), key=lambda item: item[1][0] / max(item[1][1], 1)
    ):
        print(f"  {name:15s} {edits}/{count} ({edits / max(count, 1):.4f})", flush=True)
    (candidates_root / "scores.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
