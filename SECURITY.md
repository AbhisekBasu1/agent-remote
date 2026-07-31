# Security policy

## Supported versions

Security fixes are made on the latest tagged release and `main`. Pre-release
builds and old snapshots may receive a fix only by upgrading.

## Reporting a vulnerability

Use the repository's **Security → Report a vulnerability** form so details stay
private. If private reporting is unavailable, open a minimal issue asking the
maintainer to enable a private channel; do not include exploit details, private
transcripts, credentials, or audio recordings in a public issue.

Please include the affected version or commit, macOS and CPU architecture,
whether the optional audio driver is installed, reproduction steps using
synthetic data where possible, and the expected impact. You should receive an
acknowledgement within seven days.

## Security-sensitive boundaries

Agent Remote:

- reads local Codex and Claude Code transcript files when passive watching is
  enabled;
- can emit keyboard and pointer events after Accessibility permission;
- can edit agent configuration only after an explicit confirmation;
- runs a narrowly scoped driver installer or uninstaller with administrator
  privileges after an explicit macOS authorization prompt;
- does not include a network client or transmit user data.

The project treats unexpected transcript writes, command injection, unsafe
path handling, overbroad privileged operations, unsigned component
substitution, and disclosure of transcript-derived data as security issues.

Ad-hoc signatures provide code-integrity sealing but no publisher identity.
Users should build from reviewed source or obtain binaries through a channel
they independently trust.
