#!/usr/bin/env python3
"""Replay a DualSense Opus archive through decoder-state experiments.

This is an offline development tool; it is not part of the packaged app.
It validates the live decoder's channel-0 output against the archived Raw.wav,
then renders fixed-ratio Sonic candidates without risking the live path.
"""

from __future__ import annotations

import argparse
import ctypes
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
    def __init__(self, library_path: Path, channel_count: int = 2):
        self.channel_count = channel_count
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
        self.decoder: int | None = None
        self.reset()

    def reset(self) -> None:
        if self.decoder:
            self.library.opus_decoder_destroy(self.decoder)
        error = ctypes.c_int32()
        self.decoder = self.library.opus_decoder_create(
            RATE,
            self.channel_count,
            ctypes.byref(error),
        )
        if not self.decoder or error.value != 0:
            raise RuntimeError(f"opus_decoder_create failed: {error.value}")

    def close(self) -> None:
        if self.decoder:
            self.library.opus_decoder_destroy(self.decoder)
            self.decoder = None

    def decode(self, packet: bytes | None) -> np.ndarray:
        output = (ctypes.c_int16 * (FRAME * self.channel_count))()
        if packet is None:
            encoded = None
            size = 0
        else:
            encoded = (ctypes.c_ubyte * len(packet)).from_buffer_copy(packet)
            size = len(packet)
        count = self.library.opus_decode(
            self.decoder,
            encoded,
            size,
            output,
            FRAME,
            0,
        )
        if count != FRAME:
            raise RuntimeError(f"opus_decode returned {count}")
        return np.ctypeslib.as_array(output).copy().reshape(count, self.channel_count)


class Sonic:
    def __init__(self, library_path: Path, time_ratio: float):
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
        self.library.sonicSetSpeed(self.stream, ctypes.c_float(1.0 / time_ratio))

    def drain(self) -> list[np.ndarray]:
        chunks: list[np.ndarray] = []
        while True:
            available = self.library.sonicSamplesAvailable(self.stream)
            if available <= 0:
                break
            output = (ctypes.c_int16 * available)()
            count = self.library.sonicReadShortFromStream(
                self.stream,
                output,
                available,
            )
            if count <= 0:
                break
            chunks.append(np.ctypeslib.as_array(output)[:count].copy())
        return chunks

    def process(self, samples: np.ndarray) -> np.ndarray:
        chunks: list[np.ndarray] = []
        for start in range(0, len(samples), FRAME):
            frame = np.ascontiguousarray(samples[start:start + FRAME], dtype=np.int16)
            pointer = frame.ctypes.data_as(ctypes.POINTER(ctypes.c_int16))
            if self.library.sonicWriteShortToStream(
                self.stream,
                pointer,
                len(frame),
            ) == 0:
                raise MemoryError("sonicWriteShortToStream failed")
            chunks.extend(self.drain())
        if self.library.sonicFlushStream(self.stream) == 0:
            raise MemoryError("sonicFlushStream failed")
        chunks.extend(self.drain())
        return np.concatenate(chunks) if chunks else np.empty(0, dtype=np.int16)

    def close(self) -> None:
        if self.stream:
            self.library.sonicDestroyStream(self.stream)
            self.stream = None


def rbj_pass(cutoff: float, high_pass: bool) -> tuple[np.ndarray, np.ndarray]:
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


def filter_samples(samples: np.ndarray, coefficients) -> np.ndarray:
    values = samples.astype(np.float64)
    for numerator, denominator in coefficients:
        values = lfilter(numerator, denominator, values)
    return values


def decode_variant(
    records: list[tuple[int, bytes]],
    opus_library: Path,
    mode: str,
) -> np.ndarray:
    decoder = OpusDecoder(opus_library)
    result: list[np.ndarray] = []
    previous_counter: int | None = None
    try:
        for counter, packet in records:
            delta = 1 if previous_counter is None else safe_delta(previous_counter, counter)
            if mode == "advance" and previous_counter is not None:
                for _ in range(delta - 1):
                    decoder.decode(None)
            elif mode == "reset-gap" and previous_counter is not None and delta > 1:
                decoder.reset()
            elif mode == "reset-every":
                decoder.reset()
            result.append(decoder.decode(packet)[:, 0])
            previous_counter = counter
    finally:
        decoder.close()
    return np.concatenate(result)


def write_wav(path: Path, samples: np.ndarray) -> None:
    wavfile.write(
        path,
        RATE,
        np.int16(np.clip(np.rint(samples), -32_768, 32_767)),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--raw", type=Path)
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

    records = read_archive(args.archive)
    generated = 1
    for left, right in zip(records, records[1:]):
        generated += safe_delta(left[0], right[0])
    ratio = generated / len(records)
    args.output_directory.mkdir(parents=True, exist_ok=True)

    cleanup = [
        rbj_pass(70, True),
        rbj_shelf(180, 3.0),
        rbj_pass(5_000, False),
        rbj_pass(5_000, False),
    ]
    finish = [rbj_shelf(180, 2.5)]
    for mode in ("skip", "advance", "reset-gap", "reset-every"):
        decoded = decode_variant(records, args.opus, mode)
        if mode == "skip" and args.raw:
            rate, reference = wavfile.read(args.raw)
            difference = decoded.astype(np.int32) - reference.astype(np.int32)
            print(
                f"skip validation: rate={rate} maxError={np.max(np.abs(difference))} "
                f"different={np.count_nonzero(difference)}"
            )
        cleaned = filter_samples(decoded, cleanup)
        cleaned_int16 = np.int16(np.clip(np.rint(cleaned), -32_768, 32_767))
        sonic = Sonic(args.sonic, ratio)
        try:
            stretched = sonic.process(cleaned_int16)
        finally:
            sonic.close()
        finished = filter_samples(stretched, finish)
        destination = args.output_directory / f"{mode}-sonic.wav"
        write_wav(destination, finished)
        print(
            f"{mode}: decoded={len(decoded)} output={len(finished)} "
            f"duration={len(finished) / RATE:.3f}s ratio={ratio:.6f} "
            f"peak={np.max(np.abs(finished)):.1f} path={destination}"
        )


if __name__ == "__main__":
    main()
