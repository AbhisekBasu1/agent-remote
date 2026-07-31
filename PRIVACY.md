# Privacy

Agent Remote is local-only software. It contains no telemetry, analytics,
advertising, update checker, or network client. Controller input, microphone
audio, agent events, and transcript-derived metadata stay on the Mac.

## Data the app reads

When **Watch Sessions Automatically** is enabled (the default), Agent Remote
reads new lines from Claude Code transcripts under `~/.claude/projects` and
Codex transcripts under `~/.codex/sessions`. It uses those lines to infer:

- whether a session is working, waiting, finished, or idle;
- a short local display name for the Sessions menu;
- the working directory and local session identifier needed to focus the
  correct terminal tab or Codex task.

Transcript contents are not copied into an Agent Remote database or sent over
the network. In-memory session state expires after the session becomes stale.
The user can disable passive watching from **Agent Feedback → Watch Sessions
Automatically**.

## Local files and preferences

- Agent hook events use
  `~/Library/Application Support/DualSenseBridge/agent-events/`. The directory
  is restricted to the current user (`0700`), each event is consumed and
  deleted, and Codex JSON notifications are reduced to an event type before
  being written.
- Diagnostics use `~/Library/Logs/Agent Remote/Agent Remote.log`, restricted
  to the current user (`0600`). Logs rotate at 1 MiB and avoid transcript
  text, working directories, window titles, and session identifiers.
- Preferences, button mappings, and local terminal bindings use macOS
  `UserDefaults` for `io.github.abhisekbasu1.AgentRemote`.
- The optional hook installers edit `~/.claude/settings.json` or
  `~/.codex/config.toml` only after confirmation and keep a
  `.agent-remote-backup` copy beside the original file.

## Microphone handling

USB microphone use selects the controller's existing Core Audio input.
Bluetooth microphone use decodes the controller's Opus-over-HID stream and
writes PCM locally to the bundled virtual microphone. Agent Remote does not
record microphone audio to disk unless a developer explicitly runs one of the
separate Audio Lab tools.

## Privileged changes

Installing or uninstalling the optional Bluetooth virtual microphone requires
an administrator password because the driver lives in
`/Library/Audio/Plug-Ins/HAL`. The installer stages and verifies a complete
replacement before changing the live driver. No other feature needs
administrator privileges.

## Removing local data

After quitting Agent Remote, its disposable data can be removed with:

```sh
rm -rf "$HOME/Library/Application Support/DualSenseBridge/agent-events"
rm -rf "$HOME/Library/Logs/Agent Remote"
defaults delete io.github.abhisekbasu1.AgentRemote
defaults delete local.controllerproject.DualSenseBridge
```

Review the targets before running these commands. Remove installed agent hooks
from their respective config files, or restore the adjacent backup. The audio
driver can be removed from the Agent Remote menu.
