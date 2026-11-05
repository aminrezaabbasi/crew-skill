#!/bin/bash
# install.sh: copy the crew skill into your Claude Code skills folder.
#
#   ./install.sh                         install or update
#   ./install.sh --codex-model <name>    choose the Codex model on first install
#   ./install.sh --dry-run               show what would happen and change nothing
#
# What it touches: <claude config>/skills/crew/ and ~/.crew/.
# What it never touches or reads: your logins, API keys, shell profile,
# Claude Code settings, or Codex config.
set -euo pipefail

repo=$(cd "$(dirname "$0")" && pwd)
dest="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crew"
crew_home="$HOME/.crew"
default_model="gpt-6.1-sol"
model=""
dry=0

while [ $# -gt 0 ]; do
  case $1 in
    --codex-model)
      [ $# -ge 2 ] || { echo "--codex-model needs a model name" >&2; exit 1; }
      model=$2
      shift 2
      ;;
    --dry-run)
      dry=1
      shift
      ;;
    -h | --help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

case $model in
  *[!A-Za-z0-9._-]*)
    echo "that does not look like a model name: $model" >&2
    exit 1
    ;;
esac

for tool in git awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  echo "the guard hook needs jq or python3; install one and run this again" >&2
  exit 1
fi

# Never install through a symlink into this repo: repo profiles and board notes
# are written next to SKILL.md, and they must not land inside a git checkout.
if [ -L "$dest" ]; then
  echo "$dest is a symlink. Remove it first, then run this again." >&2
  exit 1
fi
case "$dest/" in
  "$repo"/*)
    echo "the install folder is inside this repo; that could commit private notes" >&2
    exit 1
    ;;
esac

say() { printf '%s\n' "$*"; }

if [ "$dry" -eq 1 ]; then
  say "Would install to: $dest"
  say "Would create:     $crew_home/runs (private to your user)"
  [ -f "$crew_home/config.md" ] || say "Would write:      $crew_home/config.md with codex_model: ${model:-$default_model}"
  [ -f "$dest/SKILL.md" ] && say "Would back up:    your current SKILL.md and guard hook"
  say "Nothing was changed."
  exit 0
fi

umask 077
mkdir -p "$dest/hooks" "$dest/scripts" "$dest/repos" "$dest/boards" "$crew_home/runs"
chmod 700 "$crew_home" "$crew_home/runs" "$dest/repos" "$dest/boards"

stamp=$(date +%Y%m%d-%H%M%S)
backup_skill=""
backup_guard=""
if [ -f "$dest/SKILL.md" ]; then
  backup_skill="$dest/SKILL.md.bak-$stamp"
  cp -p "$dest/SKILL.md" "$backup_skill"
fi
if [ -f "$dest/hooks/crew-guard.sh" ]; then
  backup_guard="$dest/hooks/crew-guard.sh.bak-$stamp"
  cp -p "$dest/hooks/crew-guard.sh" "$backup_guard"
fi

# Test the new guard before it replaces the one in use, and swap each file in one move.
check_guard() {
  local json='{"cwd":"/tmp","tool_input":{"command":"git reset --hard"}}' code=0
  "$1" <<<"$json" >/dev/null 2>&1 || code=$?
  [ "$code" -eq 2 ] || return 1
  json='{"cwd":"/tmp","tool_input":{"command":"git log --oneline"}}'
  "$1" <<<"$json" >/dev/null 2>&1
}
place() { # source target mode
  local tmp="$2.new.$$"
  cp "$1" "$tmp"
  chmod "$3" "$tmp"
  mv -f "$tmp" "$2"
}

if ! check_guard "$repo/skill/hooks/crew-guard.sh"; then
  echo "the guard hook failed its self test here, so nothing was replaced" >&2
  exit 1
fi
place "$repo/skill/scripts/secret-scan.sh" "$dest/scripts/secret-scan.sh" 755
place "$repo/skill/hooks/crew-guard.sh" "$dest/hooks/crew-guard.sh" 755
place "$repo/skill/SKILL.md" "$dest/SKILL.md" 644

# Your settings survive updates. This file is only written the first time.
if [ ! -f "$crew_home/config.md" ]; then
  printf 'codex_model: %s\n' "${model:-$default_model}" >"$crew_home/config.md"
  chmod 600 "$crew_home/config.md"
elif [ -n "$model" ]; then
  say "Kept $crew_home/config.md as it is. Edit codex_model there to change the model."
fi

say "Installed crew to $dest"
[ -z "$backup_skill" ] || say "Backed up your previous SKILL.md to $backup_skill"
[ -z "$backup_guard" ] || say "Backed up your previous guard to $backup_guard"

# Run records can hold private code and logs, so warn if they would sync to a cloud drive.
resolved=$(cd "$crew_home" && pwd -P)
case $resolved in
  *"Mobile Documents"* | *iCloud* | *Dropbox* | *"Google Drive"* | *GoogleDrive* | *OneDrive* | *CloudStorage*)
    say "WARNING: $resolved looks like a synced folder. Run records can hold private code and logs."
    say "         Move ~/.crew somewhere that does not sync."
    ;;
esac

say ""
say "Next: connect your accounts if you have not (README, step 2), then run these in Claude Code:"
say "  /reload-plugins"
say "  /crew doctor"
