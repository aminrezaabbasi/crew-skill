#!/bin/bash
# Tests for install.sh, using a throwaway HOME. Run: bash tests/install-test.sh
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
check() { # description, then a command that should succeed
  local what=$1
  shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $what"; fi
}
# GNU stat first: on Linux, stat -f means something else and still succeeds.
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
is_mode() { [ "$(mode "$1")" = "$2" ]; }

export HOME="$tmp/home"
unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME"
dest="$HOME/.claude/skills/crew"

# Dry run changes nothing.
"$root/install.sh" --dry-run >/dev/null
check "dry run creates nothing" test ! -e "$HOME/.crew"
check "dry run installs nothing" test ! -e "$dest"

# First install.
"$root/install.sh" --codex-model my-model >/dev/null
check "SKILL.md installed" test -f "$dest/SKILL.md"
check "guard is executable" test -x "$dest/hooks/crew-guard.sh"
check "scanner is executable" test -x "$dest/scripts/secret-scan.sh"
check "runs folder is private" is_mode "$HOME/.crew/runs" 700
check "crew home is private" is_mode "$HOME/.crew" 700
check "repos folder is private" is_mode "$dest/repos" 700
check "boards folder is private" is_mode "$dest/boards" 700
check "config is private" is_mode "$HOME/.crew/config.md" 600
check "chosen model was saved" grep -q '^codex_model: my-model$' "$HOME/.crew/config.md"

# Personal data survives an update, and the old version is backed up.
echo "profile" >"$dest/repos/me__app.md"
echo "board" >"$dest/boards/me__1.md"
printf 'codex_model: kept\n' >"$HOME/.crew/config.md"
mkdir -p "$HOME/.crew/runs/me__app/1"
echo "state" >"$HOME/.crew/runs/me__app/1/state.md"
echo "old skill" >"$dest/SKILL.md"
sleep 1
"$root/install.sh" --codex-model ignored >/dev/null
check "repo profile kept" grep -q profile "$dest/repos/me__app.md"
check "board cache kept" grep -q board "$dest/boards/me__1.md"
check "config kept" grep -q '^codex_model: kept$' "$HOME/.crew/config.md"
check "run records kept" grep -q state "$HOME/.crew/runs/me__app/1/state.md"
check "SKILL.md updated" cmp -s "$root/skill/SKILL.md" "$dest/SKILL.md"
backup_found() { grep -lq 'old skill' "$dest"/SKILL.md.bak-*; }
check "old SKILL.md backed up" backup_found

# Default model on a clean install.
export HOME="$tmp/home2"
mkdir -p "$HOME"
"$root/install.sh" >/dev/null
check "default model written" grep -q '^codex_model: gpt-' "$HOME/.crew/config.md"

# It refuses a symlinked install folder, so private notes cannot land in a checkout.
export HOME="$tmp/home3"
mkdir -p "$HOME/.claude/skills" "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$HOME/.claude/skills/crew"
refused() { ! "$root/install.sh" >/dev/null 2>&1; }
check "symlinked install refused" refused

# It rejects odd model names, since they end up in a command line later.
export HOME="$tmp/home4"
mkdir -p "$HOME"
bad_model() { ! "$root/install.sh" --codex-model 'x; rm -rf /' >/dev/null 2>&1; }
check "unsafe model name refused" bad_model

# CLAUDE_CONFIG_DIR is respected.
export HOME="$tmp/home5"
mkdir -p "$HOME"
CLAUDE_CONFIG_DIR="$tmp/altconfig" "$root/install.sh" >/dev/null
check "custom config dir used" test -f "$tmp/altconfig/skills/crew/SKILL.md"

# The hook command in the frontmatter must not name any one person's home folder.
check "hook path is not hard coded" grep -q 'CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crew/hooks/crew-guard.sh' "$root/skill/SKILL.md"
check "guard fails closed if it times out" grep -q 'onFailure: block' "$root/skill/SKILL.md"

echo "install tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
