#!/bin/bash
# Tests for skill/scripts/readiness.sh, using a throwaway HOME. Run: bash tests/readiness-test.sh
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
expect() { # description, regex, output
  if grep -Eq -- "$2" <<<"$3"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi
}
expect_not() {
  if grep -Eq -- "$2" <<<"$3"; then fail=$((fail + 1)); echo "FAIL $1"; else pass=$((pass + 1)); fi
}

export HOME="$tmp/home"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR CODEX_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
"$root/install.sh" >/dev/null
script="$HOME/.claude/skills/crew/scripts/readiness.sh"
cd "$tmp" || exit 1

# A clean install passes.
out=$("$script")
code=$?
[ "$code" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL clean install should exit 0, got $code"; }
expect "guard checked" '^OK +guard hook' "$out"
expect "runs private" '^OK +run records folder is private' "$out"
expect "model reported" 'codex_model from config: gpt-' "$out"
expect_not "no FAIL on clean install" '^FAIL' "$out"

# A set CODEX_API_KEY stops the run, and its value is never printed.
marker="value-that-must-not-be-printed"
out=$(CODEX_API_KEY=$marker "$script")
code=$?
[ "$code" -eq 1 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL CODEX_API_KEY should exit 1, got $code"; }
expect "CODEX_API_KEY reported by name" '^FAIL +CODEX_API_KEY is set' "$out"
expect_not "CODEX_API_KEY value hidden" "$marker" "$out"

# The owner can opt in to API billing, which downgrades it to a warning.
echo 'allow_api_billing: yes' >>"$HOME/.crew/config.md"
out=$(CODEX_API_KEY=$marker "$script")
code=$?
[ "$code" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL opt in should exit 0, got $code"; }
expect "opt in warns" '^WARN +CODEX_API_KEY is set' "$out"
expect_not "opt in hides value" "$marker" "$out"

# Anthropic keys warn without stopping, and stay hidden.
out=$(ANTHROPIC_API_KEY=$marker ANTHROPIC_AUTH_TOKEN=$marker "$script")
expect "ANTHROPIC_API_KEY warned" '^WARN +ANTHROPIC_API_KEY is set' "$out"
expect "ANTHROPIC_AUTH_TOKEN warned" '^WARN +ANTHROPIC_AUTH_TOKEN is set' "$out"
expect_not "anthropic values hidden" "$marker" "$out"

# Effort mode.
out=$(CLAUDE_EFFORT=high CLAUDE_CODE_EFFORT_LEVEL='' "$script" --effort)
expect "effort line" '^high\|$' "$out"

# Loose run record permissions fail.
chmod 755 "$HOME/.crew/runs"
out=$("$script")
expect "loose permissions fail" '^FAIL +run records folder has permissions 755' "$out"
chmod 700 "$HOME/.crew/runs"

# Risky Codex settings warn. Nothing else in that file is printed.
mkdir -p "$CODEX_HOME"
cat >"$CODEX_HOME/config.toml" <<'EOF'
model = "m"
private_note = "do-not-print-me"
sandbox_mode = "danger-full-access"
approval_policy = "never"
model_reasoning_effort = "low"
[sandbox_workspace_write]
network_access = true
EOF
out=$("$script")
expect "danger mode warned" '^WARN +Codex config: sandbox_mode' "$out"
expect "approval warned" '^WARN +Codex config: approval_policy' "$out"
expect "network warned" '^WARN +Codex config: workspace-write network' "$out"
expect "low effort warned" '^WARN +Codex config: default effort' "$out"
expect_not "other config not printed" 'do-not-print-me' "$out"

# A login file is never read.
echo 'do-not-print-this-login' >"$CODEX_HOME/auth.json"
out=$("$script")
expect_not "login file untouched" 'do-not-print-this-login' "$out"

# Repo notes are found from the remote, for both URL styles.
repo="$tmp/app"
mkdir -p "$repo"
git -C "$repo" init -q
echo 'profile body' >"$HOME/.claude/skills/crew/repos/someone__app.md"
printf 'board confirmed: yes\n' >"$HOME/.claude/skills/crew/boards/someone__1.md"
for url in https://github.com/someone/app.git git@github.com:someone/app.git; do
  git -C "$repo" remote remove origin 2>/dev/null
  git -C "$repo" remote add origin "$url"
  out=$(cd "$repo" && "$script")
  expect "profile found for $url" '^OK +repo profile exists: repos/someone__app.md' "$out"
  expect "profile printed for $url" '^PROFILE +profile body' "$out"
  expect "board found for $url" '^OK +board cache confirmed' "$out"
done

# A broken guard fails the check.
printf '#!/bin/sh\nexit 0\n' >"$HOME/.claude/skills/crew/hooks/crew-guard.sh"
out=$("$script")
expect "broken guard fails" '^FAIL +guard hook failed' "$out"

echo "readiness tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
