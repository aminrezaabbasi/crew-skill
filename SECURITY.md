# Security policy

## Reporting a problem

Please do not open a public issue for a security problem. Report it privately instead:

1. Open the repo's **Security** tab.
2. Choose **Report a vulnerability**.

Useful things to include:

- What you ran, and what crew or the guard hook did.
- Your OS, and your Claude Code, Codex CLI, and gh versions.
- For a guard bypass, the exact command that got through.

Never include a real token, key, or login file. A fake value that shows the same shape is enough.

## What counts

- A command on crew's never run list that gets past `skill/hooks/crew-guard.sh` when written directly.
- A way for crew, its scripts, or the installer to print, copy, or send a login or secret.
- The installer writing outside `~/.claude/skills/crew/` and `~/.crew/`, or loosening their permissions.
- Something in the skill telling Claude or Codex to weaken a safety setting.

These are known limits, already in the README, so they are not new findings on their own:

- The guard reads command text. It cannot see inside scripts, `python -c`, or flags held in variables.
- Codex's sandbox allows reading any file your user can read.
- The secret scan matches patterns, so it can miss a secret.

## Supported versions

Only the latest commit on `main` gets fixes. Update with `git pull` and `./install.sh`.
