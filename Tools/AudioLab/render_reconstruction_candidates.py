#!/usr/bin/env python3
"""Render round-4 reconstruction candidates from archived DualSense Opus takes.

Offline development tool; not part of the packaged app. For each archived
`... Opus.bin` it renders, with the exact live cleanup/finishing filters:

  base-ch0    current live pipeline (stereo decode, channel 0, fixed Sonic)
  base-ch1    same pipeline on the ASR lane (channel 1)
  base-mid    same pipeline on the (ch0+ch1)/2 mix
  seam-ch0    hole junctions phase-aligned/crossfaded before Sonic
  alloc1-ch0  counter-paced Sonic with transient-protected per-island ratios
  alloc2-ch0  conservative variant of alloc1
  allocseam1-ch0  seam alignment plus alloc1 allocation

Every candidate ends at the archive's exact counter duration, so recognition
differences reflect reconstruction quality, not speed errors.
"""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
from pathlib import Path
import struct

import numpy as np
from scipy.io import wavfile
from scipy.signal import lfilter


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SONIC_LIBRARY = PROJECT_ROOT / ".build/audio-lab/libsonic.dylib"


def default_opus_library() -> Path:
    candidates = (
        Path("/opt/homebrew/opt/opus/lib/libopus.0.dylib"),
        Path("/usr/local/opt/opus/lib/libopus.0.dylib"),
    )
    return next((path for path in candidates if path.is_file()), candidates[0])


RATE = 48_000
FRAME = 480


def read_archive(path: Path) -> list[tuple[int, bytes]]:
    data = path.read_bytes()
    if data[:8] != b"DSOPUS01":
        raise ValueError(f"not a DualSense Opus archive: {path}")
    records: list[tuple[int, bytes]] = []
    offset = 8
    while offset < len(data):
        counter = data[offset]
        size = struct.unpack_from("<H", data, offset + 1)[0]
        offset += 3
        records.append((counter, data[offset:offset + size]))
        offset += size
    if offset != len(data):
        raise ValueError("truncated Opus archive")
    return records


def safe_delta(previous: int, current: int) -> int:
    delta = (current - previous) % 256
    return delta if 1 <= delta <= 128 else 1


class OpusDecoder:
    def __init__(self, library_path: Path):
        self.library = ctypes.CDLL(str(library_path))
        self.library.opus_decoder_create.argtypes = [
            ctypes.c_int32,
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_int32),
        ]
        self.library.opus_decoder_create.restype = ctypes.c_void_p
        self.library.opus_decoder_destroy.argtypes = [ctypes.c_void_p]
        self.library.opus_decode.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_ubyte),
            ctypes.c_int32,
            ctypes.POINTER(ctypes.c_int16),
            ctypes.c_int,
            ctypes.c_int,
        ]
        self.library.opus_decode.restype = ctypes.c_int
        error = ctypes.c_int32()
        self.decoder = self.library.opus_decoder_create(
            RATE, 2, ctypes.byref(error)
        )
        if not self.decoder or error.value != 0:
            raise RuntimeError(f"opus_decoder_create failed: {error.value}")

    def close(self) -> None:
        self.library.opus_decoder_destroy(self.decoder)

    def decode(self, packet: bytes) -> np.ndarray:
        encoded = (ctypes.c_ubyte * len(packet)).from_buffer_copy(packet)
        output = (ctypes.c_int16 * (FRAME * 2))()
        count = self.library.opus_decode(
            self.decoder, encoded, len(packet), output, FRAME, 0
        )
        if count != FRAME:
            raise RuntimeError(f"opus_decode returned {count}")
        return np.ctypeslib.as_array(output).copy().reshape(count, 2)


class Sonic:
    """Streaming Sonic wrapper that allows per-frame speed updates."""

    def __init__(self, library_path: Path):
        self.library = ctypes.CDLL(str(library_path))
        self.library.sonicCreateStream.argtypes = [ctypes.c_int, ctypes.c_int]
        self.library.sonicCreateStream.restype = ctypes.c_void_p
        self.library.sonicDestroyStream.argtypes = [ctypes.c_void_p]
        self.library.sonicSetQuality.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.library.sonicSetSpeed.argtypes = [ctypes.c_void_p, ctypes.c_float]
        self.library.sonicWriteShortToStream.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_int16),
            ctypes.c_int,
        ]
        self.library.sonicWriteShortToStream.restype = ctypes.c_int
        self.library.sonicSamplesAvailable.argtypes = [ctypes.c_void_p]
        self.library.sonicSamplesAvailable.restype = ctypes.c_int
        self.library.sonicReadShortFromStream.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_int16),
            ctypes.c_int,
        ]
        self.library.sonicReadShortFromStream.restype = ctypes.c_int
        self.library.sonicFlushStream.argtypes = [ctypes.c_void_p]
        self.library.sonicFlushStream.restype = ctypes.c_int
        self.stream = self.library.sonicCreateStream(RATE, 1)
        if not self.stream:
            raise MemoryError("sonicCreateStream failed")
        self.library.sonicSetQuality(self.stream, 1)

    def set_time_ratio(self, ratio: float) -> None:
        self.library.sonicSetSpeed(self.stream, ctypes.c_float(1.0 / ratio))

    def write(self, samples: np.ndarray) -> list[np.ndarray]:
        frame = np.ascontiguousarray(samples, dtype=np.int16)
        pointer = frame.ctypes.data_as(ctypes.POINTER(ctypes.c_int16))
        if self.library.sonicWriteShortToStream(
            self.stream, pointer, len(frame)
        ) == 0:
            raise MemoryError("sonicWriteShortToStream failed")
        return self.drain()

    def drain(self) -> list[np.ndarray]:
        chunks: list[np.ndarray] = []
        while True:
            available = self.library.sonicSamplesAvailable(self.stream)
            if available <= 0:
                break
            output = (ctypes.c_int16 * available)()
            count = self.library.sonicReadShortFromStream(
                self.stream, output, available
            )
            if count <= 0:
                break
            chunks.append(np.ctypeslib.as_array(output)[:count].copy())
        return chunks

    def flush(self) -> list[np.ndarray]:
        if self.library.sonicFlushStream(self.stream) == 0:
            raise MemoryError("sonicFlushStream failed")
        return self.drain()

    def close(self) -> None:
        if self.stream:
            self.library.sonicDestroyStream(self.stream)
            self.stream = None


def rbj_pass(cutoff: float, high_pass: bool):
    q = 1.0 / np.sqrt(2.0)
    omega = 2.0 * np.pi * cutoff / RATE
    cosine = np.cos(omega)
    alpha = np.sin(omega) / (2.0 * q)
    a0 = 1.0 + alpha
    numerator = 1.0 + cosine if high_pass else 1.0 - cosine
    sign = -1.0 if high_pass else 1.0
    return (
        np.array([
            numerator * 0.5 / a0,
            sign * numerator / a0,
            numerator * 0.5 / a0,
        ]),
        np.array([1.0, -2.0 * cosine / a0, (1.0 - alpha) / a0]),
    )


def rbj_shelf(frequency: float, gain_db: float, q: float = 0.7):
    omega = 2.0 * np.pi * frequency / RATE
    cosine = np.cos(omega)
    alpha = np.sin(omega) / (2.0 * q)
    amplitude = 10.0 ** (gain_db / 40.0)
    beta = 2.0 * np.sqrt(amplitude) * alpha
    plus = amplitude + 1.0
    minus = amplitude - 1.0
    a0 = plus + minus * cosine + beta
    return (
        amplitude * np.array([
            plus - minus * cosine + beta,
            2.0 * (minus - plus * cosine),
            plus - minus * cosine - beta,
        ]) / a0,
        np.array([
            1.0,
            -2.0 * (minus + plus * cosine) / a0,
            (plus + minus * cosine - beta) / a0,
        ]),
    )


CLEANUP = [
    rbj_pass(70, True),
    rbj_shelf(180, 3.0),
    rbj_pass(5_000, False),
    rbj_pass(5_000, False),
]
FINISH = [rbj_shelf(180, 2.5)]


def filter_samples(samples: np.ndarray, coefficients) -> np.ndarray:
    values = samples.astype(np.float64)
    for numerator, denominator in coefficients:
        values = lfilter(numerator, denominator, values)
    return values


def to_int16(values: np.ndarray) -> np.ndarray:
    return np.int16(np.clip(np.rint(values), -32_768, 32_767))


@dataclass
class Take:
    stem: str
    islands_ch0: list[np.ndarray]
    islands_ch1: list[np.ndarray]
    positions: list[int]
    generated: int

    @property
    def received(self) -> int:
        return len(self.islands_ch0)

    @property
    def ratio(self) -> float:
        return self.generated / self.received


def decode_take(archive: Path, opus_library: Path) -> Take:
    records = read_archive(archive)
    decoder = OpusDecoder(opus_library)
    islands_ch0: list[np.ndarray] = []
    islands_ch1: list[np.ndarray] = []
    positions: list[int] = []
    position = 0
    previous: int | None = None
    try:
        for counter, packet in records:
            if previous is not None:
                position += safe_delta(previous, counter)
            samples = decoder.decode(packet)
            islands_ch0.append(samples[:, 0].copy())
            islands_ch1.append(samples[:, 1].copy())
            positions.append(position)
            previous = counter
    finally:
        decoder.close()
    return Take(
        stem=archive.stem.removesuffix(" Opus"),
        islands_ch0=islands_ch0,
        islands_ch1=islands_ch1,
        positions=positions,
        generated=position + 1,
    )


def seam_align(
    islands: list[np.ndarray],
    positions: list[int],
    max_shift: int = 96,
    window: int = 80,
    crossfade: int = 48,
) -> list[np.ndarray]:
    """Phase-align each post-hole island against the running tail.

    Returns per-island sample arrays whose concatenation is the aligned
    compacted stream. Contiguous islands are left untouched; at each hole
    junction the incoming island is shifted by up to `max_shift` samples for
    maximum normalized cross-correlation with the existing tail, and the join
    is crossfaded. Sample loss is bounded by max_shift + crossfade per hole.
    """
    aligned: list[np.ndarray] = [islands[0].astype(np.float64)]
    for index in range(1, len(islands)):
        island = islands[index].astype(np.float64)
        contiguous = positions[index] == positions[index - 1] + 1
        tail = aligned[-1]
        if contiguous or len(tail) < window + crossfade:
            aligned.append(island)
            continue
        reference = tail[-window:]
        energy = np.sqrt(np.mean(reference**2))
        if energy < 40.0:
            aligned.append(island)
            continue
        best_shift = 0
        best_score = -2.0
        for shift in range(0, max_shift + 1, 4):
            candidate = island[shift:shift + window]
            denominator = (
                np.sqrt(np.sum(reference**2) * np.sum(candidate**2)) + 1e-9
            )
            score = float(np.dot(reference, candidate) / denominator)
            if score > best_score:
                best_score = score
                best_shift = shift
        shifted = island[best_shift:]
        fade = np.linspace(0.0, 1.0, crossfade, endpoint=False)
        blended = tail.copy()
        blended[-crossfade:] = (
            blended[-crossfade:] * (1.0 - fade) + shifted[:crossfade] * fade
        )
        aligned[-1] = blended
        aligned.append(shifted[crossfade:])
    return aligned


@dataclass
class AllocatorTuning:
    horizon_islands: int = 15
    silence_multiplier: float = 1.3
    silence_cap: float = 3.9
    voiced_cap: float = 3.2
    unvoiced_cap: float = 1.8
    onset_cap: float = 1.15


CONSERVATIVE = AllocatorTuning(
    horizon_islands=25,
    silence_multiplier=1.2,
    silence_cap=3.5,
    voiced_cap=3.0,
    unvoiced_cap=2.0,
    onset_cap=1.3,
)


def classify_island(
    samples: np.ndarray,
    previous_rms: float,
    noise_floor: float,
) -> str:
    rms = float(np.sqrt(np.mean(samples**2)))
    if rms < max(3.0 * noise_floor, 60.0):
        return "silence"
    difference = np.diff(samples)
    hf_ratio = float(
        np.sqrt(np.mean(difference**2)) / (rms + 1e-9)
    )
    if rms > 2.2 * max(previous_rms, 1.0) and rms > 400.0:
        return "onset"
    if hf_ratio > 0.80:
        return "unvoiced"
    return "voiced"


def allocate(
    islands: list[np.ndarray],
    positions: list[int],
    base_ratio: float,
    sonic_library: Path,
    tuning: AllocatorTuning,
) -> np.ndarray:
    """Counter-paced Sonic expansion with transient-protected ratios.

    Every island is written at a per-island ratio: transients stay near 1x,
    silence overpays, and a leaky debt controller spreads any pacing error
    over `horizon_islands` so speed never pumps audibly. The pacing target for
    island i is its true counter position, so overall duration stays exact
    without advancing the decoder or synthesizing hole content.
    """
    sonic = Sonic(sonic_library)
    chunks: list[np.ndarray] = []
    planned_out = 0.0
    noise_floor = 60.0
    previous_rms = 0.0
    horizon = float(tuning.horizon_islands * FRAME)
    try:
        for island, position in zip(islands, positions):
            values = island.astype(np.float64)
            rms = float(np.sqrt(np.mean(values**2))) if len(values) else 0.0
            noise_floor = min(noise_floor * 1.02 + 0.5, max(rms, 1.0))
            klass = classify_island(values, previous_rms, noise_floor)
            previous_rms = rms

            target_out = float((position + 1) * FRAME)
            debt = target_out - planned_out - len(values) * base_ratio
            correction = float(np.clip(debt / horizon, -0.6, 0.9))
            if klass == "silence":
                ratio = base_ratio * tuning.silence_multiplier + correction
                ratio = float(np.clip(ratio, 1.0, tuning.silence_cap))
            elif klass == "onset":
                ratio = float(np.clip(base_ratio + correction, 1.0, tuning.onset_cap))
            elif klass == "unvoiced":
                ratio = float(np.clip(base_ratio + correction, 1.0, tuning.unvoiced_cap))
            else:
                ratio = float(np.clip(base_ratio + correction, 1.0, tuning.voiced_cap))
            planned_out += len(values) * ratio
            sonic.set_time_ratio(ratio)
            chunks.extend(sonic.write(to_int16(values)))
        chunks.extend(sonic.flush())
    finally:
        sonic.close()
    return (
        np.concatenate(chunks) if chunks else np.empty(0, dtype=np.int16)
    )


def fixed_stretch(
    samples: np.ndarray, ratio: float, sonic_library: Path
) -> np.ndarray:
    sonic = Sonic(sonic_library)
    chunks: list[np.ndarray] = []
    try:
        sonic.set_time_ratio(ratio)
        for start in range(0, len(samples), FRAME):
            chunks.extend(sonic.write(samples[start:start + FRAME]))
        chunks.extend(sonic.flush())
    finally:
        sonic.close()
    return (
        np.concatenate(chunks) if chunks else np.empty(0, dtype=np.int16)
    )


def render_base(
    islands: list[np.ndarray],
    generated: int,
    sonic_library: Path,
) -> np.ndarray:
    compact = np.concatenate(islands)
    cleaned = to_int16(filter_samples(compact, CLEANUP))
    ratio = generated * FRAME / len(cleaned)
    stretched = fixed_stretch(cleaned, ratio, sonic_library)
    return to_int16(filter_samples(stretched, FINISH))


def render_alloc(
    islands: list[np.ndarray],
    positions: list[int],
    generated: int,
    sonic_library: Path,
    tuning: AllocatorTuning,
) -> np.ndarray:
    compact = np.concatenate([island.astype(np.float64) for island in islands])
    cleaned = filter_samples(compact, CLEANUP)
    cleaned_islands: list[np.ndarray] = []
    offset = 0
    for island in islands:
        cleaned_islands.append(cleaned[offset:offset + len(island)])
        offset += len(island)
    base_ratio = generated * FRAME / len(cleaned)
    stretched = allocate(
        cleaned_islands, positions, base_ratio, sonic_library, tuning
    )
    return to_int16(filter_samples(stretched, FINISH))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archives", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--opus",
        type=Path,
        default=default_opus_library(),
        help="Opus dynamic library (defaults to the Homebrew installation)",
    )
    parser.add_argument(
        "--sonic",
        type=Path,
        default=DEFAULT_SONIC_LIBRARY,
        help="Sonic dynamic library built by build-sonic-library.sh",
    )
    parser.add_argument("--raw", type=Path, default=None,
                        help="optional Raw.wav to validate channel-0 decode")
    args = parser.parse_args()
    args.opus = args.opus.expanduser().resolve()
    args.sonic = args.sonic.expanduser().resolve()
    if not args.opus.is_file():
        parser.error(f"Opus library does not exist: {args.opus}")
    if not args.sonic.is_file():
        parser.error(
            f"Sonic library does not exist: {args.sonic}; "
            "run Tools/AudioLab/build-sonic-library.sh"
        )

    for archive in args.archives:
        take = decode_take(archive, args.opus)
        destination = args.output / take.stem
        destination.mkdir(parents=True, exist_ok=True)

        if args.raw and len(args.archives) == 1:
            _, reference = wavfile.read(args.raw)
            decoded = np.concatenate(take.islands_ch0).astype(np.int32)
            difference = decoded - reference.astype(np.int32)
            print(
                f"{take.stem}: raw validation maxError={np.max(np.abs(difference))}"
            )

        mid = [
            np.rint((a.astype(np.float64) + b.astype(np.float64)) / 2.0)
            for a, b in zip(take.islands_ch0, take.islands_ch1)
        ]
        candidates: dict[str, np.ndarray] = {
            "base-ch0": render_base(
                take.islands_ch0, take.generated, args.sonic
            ),
            "base-ch1": render_base(
                take.islands_ch1, take.generated, args.sonic
            ),
            "base-mid": render_base(mid, take.generated, args.sonic),
            "seam-ch0": render_base(
                seam_align(take.islands_ch0, take.positions),
                take.generated,
                args.sonic,
            ),
            "alloc1-ch0": render_alloc(
                take.islands_ch0,
                take.positions,
                take.generated,
                args.sonic,
                AllocatorTuning(),
            ),
            "alloc2-ch0": render_alloc(
                take.islands_ch0,
                take.positions,
                take.generated,
                args.sonic,
                CONSERVATIVE,
            ),
            "allocseam1-ch0": render_alloc(
                seam_align(take.islands_ch0, take.positions),
                take.positions,
                take.generated,
                args.sonic,
                AllocatorTuning(),
            ),
        }
        target_seconds = take.generated * FRAME / RATE
        print(
            f"{take.stem}: received={take.received} generated={take.generated} "
            f"ratio={take.ratio:.4f} target={target_seconds:.2f}s"
        )
        for name, samples in candidates.items():
            wavfile.write(destination / f"{name}.wav", RATE, samples)
            print(
                f"  {name:14s} {len(samples) / RATE:6.2f}s "
                f"peak={int(np.max(np.abs(samples)))}"
            )


if __name__ == "__main__":
    main()
