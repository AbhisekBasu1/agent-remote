# Audio lab

These scripts reproduce the offline Bluetooth-microphone experiments described
in `docs/research/`. They are development tools, not part of the packaged app,
and they never upload recordings.

The replay tools require Python 3.11 or newer, NumPy, SciPy, Homebrew Opus, and
a native Sonic library compiled from the source already in this repository:

```sh
brew install opus
Tools/AudioLab/build-sonic-library.sh
```

The scoring tools additionally require FFmpeg and Faster Whisper. Keep private
recordings outside the repository and pass their location explicitly:

```sh
uv run --no-project --with faster-whisper \
  python3 Tools/AudioLab/score_candidates.py \
  /path/to/rendered-candidates /path/to/private-audio-fixtures

uv run --no-project --with faster-whisper \
  python3 Tools/AudioLab/score_sonic_quality.py \
  /path/to/private-audio-fixtures /path/to/sonic-replays
```

Run a script with `--help` for all inputs. Generated audio, transcripts, model
caches, and score files belong in ignored `.build/` paths or outside the
repository.
