# Fleet: multi-session awareness and control

Fleet is Agent Remote's answer to running several coding agents at once:
the five player LEDs show *which session is focused*, the lightbar and
haptics show agent state, and one button brings the focused session's window
to the front. This document describes how it works, how to configure it, and
where its current edges are.

Nothing in fleet requires setup. Sessions are discovered by passive
transcript watching; if **Watch Sessions Automatically** is on (the
default), the fleet builds itself.

## Where sessions come from

Every Claude Code and Codex session writes a transcript
(`~/.claude/projects/…/*.jsonl`, `~/.codex/sessions/…/*.jsonl`). The app
tails these read-only and runs a per-session state machine:

| State | Meaning | Derived from |
|---|---|---|
| Working | busy, needs nothing | prompt submitted / tool results flowing |
| Needs Attention | blocked on you | Codex approval events (explicit), or a Claude tool call sitting in a quiet transcript ~20 s (heuristic — shown as "Waiting?") |
| Done | turn finished, output waiting for review | final assistant message (`stop_reason` end_turn) / Codex `task_complete` |
| Error | failed | explicit error markers |
| Idle | quiet for a while | 5 min after Done (15 min abandonment for Working/Attention) |

Idle sessions **stay in the fleet** — a quiet session's process is still
alive in your terminal, and it is exactly the thing you raise to hand new
work. Sessions leave the fleet only after their transcript has been
untouched for two hours. This also covers sessions in the ChatGPT app's
Codex, which writes the same rollout files.

Codex's internal child rollouts (for example its guardian subagent) are
identified from `session_meta` and excluded. They are implementation details,
not tasks you can open, so they never consume a Fleet slot or steal focus from
their user-visible parent task.

## The player LEDs: a counted focus marker

The five white lights under the touchpad deliberately have one meaning:
the number of illuminated dots identifies the session targeted by d-pad ↑.
They never double as a status display, so an agent finishing cannot make an
unrelated pattern blink.

Newer DualSense hardware revisions electrically join the outer pair and the
inner pair. They cannot display a freely moving individual dot: requesting
one outer LED illuminates both outer LEDs, and requesting one inner LED
illuminates both inner LEDs. Fleet therefore uses Sony's symmetric,
revision-safe player patterns:

| Position on page | Physical pattern | Meaning |
|---|---|---|
| **1** | `○○●○○` | one dot |
| **2** | `○●○●○` | two dots |
| **3** | `●○●○●` | three dots |
| **4** | `●●○●●` | four dots |
| **5** | `●●●●●` | five dots |

Every live session gets a sticky Fleet number for its lifetime. The five
counts form pages:

| Fleet sessions | Cursor page |
|---|---|
| **F1–F5** | page 1, one through five dots |
| **F6–F10** | page 2, one through five dots again |
| **F11–F15** | page 3, one through five dots again |

Moving from F5 to F6 therefore changes from five dots back to one dot on page
2. The Sessions menu shows the Fleet number and page whenever more than five
sessions are live.

Agent state remains visible in the menu and through the existing lightbar
colors and haptic alerts. Player-LED writes pause during microphone capture
and the same focus pattern is restored when capture ends.

## The menu: Sessions

**Agent Feedback → Sessions** is the roster in text:

    ▶ F1 · page 1 ○○●○○  Working — project · 11111111
      F2 · page 1 ○●○●○  Waiting? — codex · 14:58
      F6 · page 2 ○○●○○  Idle — otherproject · 91c2aa04

- The five-dot picture is the exact player-number pattern. Count its filled
  dots for the position; the page label disambiguates repeated counts.
- **▶** marks controller focus.
- "Waiting?" (with the question mark) is inferred attention — could be a
  permission prompt, could be a slow build. Confident attention reads
  "Needs Attention".
- **Clicking a session focuses and raises it** in one gesture. Clicking a
  session that left the fleet between render and click refuses with a
  buzz rather than doing nothing.

The submenu title summarizes at a glance: `Sessions: 3 (1 waiting)`.

## Focus: which session the controller points at

The controller holds one *focused* session — the target of fleet actions.

- **Manual**: d-pad ← / → cycles through sessions in Fleet-number order,
  wrapping around. Each step gives a haptic tick and advances the steady
  one-to-five-dot count. The controller's fade is disabled so old and new
  patterns do not overlap. D-pad ↑ raises that session and leaves its focus
  pattern in place.
- **Automatic**: when a session starts waiting and you haven't cycled in
  the last 30 seconds, focus snaps to it — the session that needs you is
  almost always the one you're about to act on. Manual cycling pins focus
  for 30 seconds (the pin re-evaluates the moment it expires, so
  attention that arrived mid-pin still snaps). Focus is never pulled away
  from a session that itself needs you.

## Raise: d-pad ↑

Brings the focused session's host window to the front. Both harnesses
close their transcripts between writes, so the "who is writing this
file?" evidence often doesn't exist at the moment you press — the
strategy therefore depends on the session's source:

**Claude Code sessions** are terminal-hosted by definition:

1. In Ghostty 1.3+, use its official scripting API to narrow terminals by
   the transcript's full working directory. A new terminal session's first
   prompt also teaches Fleet the selected terminal's stable ID while Ghostty
   is still in front, so later raises can return to that exact tab/split.
2. If a pre-existing session has not been learned yet, match Ghostty's task
   title against Claude's session slug and first prompt. When two terminals
   remain indistinguishable, pressing d-pad Up again within four seconds
   cycles to the next same-directory terminal and remembers that correction.
3. For other terminal apps, match the working-directory folder against
   Accessibility window titles, preferring the writer's own app when one
   is found.
4. No match → activate the writer's terminal app if known.
5. Still nothing → if exactly one known terminal is running, activate it
   (the session is in there somewhere).

**Codex sessions** may live in a terminal *or* in the ChatGPT/Codex desktop
app. Their first `session_meta` record identifies both the host and thread:

1. A `Codex Desktop` rollout opens `codex://threads/<thread-id>`, which
   foregrounds the app **and navigates to that exact task**. Both the current
   `com.openai.codex` app and older `com.openai.chat` builds are recognized.
2. An explicit CLI/exec rollout stays on the terminal path above even when
   the desktop app is also running.
3. For an old/incomplete rollout, `lsof` the transcript and walk each
   writer's parent chain, then use the same desktop/terminal fallbacks.

A raise that fails end-to-end — no window found, activation refused —
plays the refusal buzz. Success ticks are genuine: the resolver checks
the actual result of `AXRaise` and app activation before confirming.

Known terminals: Ghostty, iTerm2, Terminal.app, kitty, Alacritty,
WezTerm. Generic terminal matching uses the Accessibility permission the app
already holds. Ghostty's exact tab/split selection additionally causes macOS
to ask once for **Agent Remote → Ghostty** under Privacy & Security →
Automation; no terminal text or input is read or written.

## The safety rule: fleet buttons never type

A button bound to a fleet action is removed from the keystroke system
entirely — no key-down, no repeat, nothing on release (including the
edge where a button is rebound while physically held: its old shortcut's
release is still delivered so no key can stick). A fleet control can
refuse, but it can never leak a character into whatever window has
keyboard focus.

## Configuration

Use **Button Mapping → Assignment** to see or change Fleet ownership alongside
every keyboard shortcut. The equivalent **Agent Feedback → Fleet Controls**
menu remains available for quick changes. Each action is bindable to any of
the 27 controls, or Off. One button drives one action; binding steals the
button from any previous owner. Defaults, chosen from buttons the shipped
layout leaves free:

| Action | Default |
|---|---|
| Focus Previous Session | D-pad Left |
| Focus Next Session | D-pad Right |
| Raise Focused Session | D-pad Up |

**Agent Feedback → Player LEDs Show Focus** — toggles the focus cursor; off
restores the controller's default player-one light.

D-pad Down, Cross, L3, R3, Create, and Options remain deliberately free —
Cross is *not* approve (Circle-as-Return already fills that role once the
right window is up), and D-pad Down is reserved for a future interrupt.

## Troubleshooting

The resolver writes privacy-redacted outcomes to
`~/Library/Logs/Agent Remote/Agent Remote.log`:

- `window resolver: found N transcript writer process(es)` — process-ancestry
  evidence was available.
- `window resolver: none of N window title(s) … matched` — the Accessibility
  title fallback could not identify a window; actual titles are not logged.
- `window resolver: opened the selected Codex task` — the exact-task deep link
  was handed to the desktop app without recording its task ID.
- `window resolver: learned a Ghostty terminal binding …` — a fresh foreground
  prompt established an exact local association.
- `window resolver: chose among N Ghostty … candidates by …` — duplicate-
  directory candidates were resolved by `remembered`, `titleHint`, `cycled`,
  or deterministic fallback.
- `window resolver: focused a Ghostty terminal …` — the native tab/split was
  selected. An Automation denial is logged by error number only.
- `passive session event: …` — the state transitions feeding the fleet.

If a Ghostty raise buzzes refusal, first allow Agent Remote to control Ghostty
in Privacy & Security → Automation. For another terminal, verify that the
window title contains the project folder; private titles are deliberately not
copied into diagnostics.

## Current limits, and what comes next

- **Duplicate Ghostty working directories**: Ghostty 1.3 exposes terminal
  IDs, names, and working directories but not child PIDs/TTYs. Fleet learns
  the stable ID when a prompt begins, otherwise uses task-title similarity.
  If two old tabs still look identical, press d-pad Up again within four
  seconds to cycle; the corrected tab is remembered for that transcript.
  Distinct project directories remain deterministic, including split panes.
- **Split panes outside Ghostty**: generic AX title matching can identify a
  window but cannot distinguish splits that share its title.
- **More than five sessions**: the one-through-five count repeats on logical
  pages; the menu labels the page because the controller has no sixth LED.
- **One state per session on the lightbar**: the bar still shows the
  aggregate (most demanding state across sessions) plus transient
  flashes; a focus-follows-lightbar mode is deliberately deferred.

**Phase 2 — routed input**: approve/deny/interrupt delivered to the
*focused* session without raising it, with state guards (approve only
lands on a session that is actually waiting). The transcript already
names the pending tool call, so the menu will be able to show "F2 wants:
Bash(git push --force)" before you press anything.

**Phase 3 — routed dictation**: hold-to-talk targeted at the focused
session, eventually with on-device transcription over the controller-mic
pipeline, so speaking to F4 never touches your screen.
