#!/bin/bash
# readiness.sh: the local half of crew's readiness check, in one approved command.
# It only reads and reports, and it changes nothing. It prints the names of
# environment variables, never their values, and never opens a login file.
#
#   readiness.sh            all local checks, one result per line
#   readiness.sh --effort   only the session's effort: CLAUDE_EFFORT|CLAUDE_CODE_EFFORT_LEVEL
#
# Each line starts with OK, WARN, or FAIL. Exit 1 if any line is FAIL.

if [ "${1:-}" = "--effort" ]; then
  printf '%s|%s\n' "${CLAUDE_EFFORT:-}" "${CLAUDE_CODE_EFFORT_LEVEL:-}"
  exit 0
fi

skill_dir=$(cd "$(dirname "$0")/.." && pwd)
crew_home="$HOME/.crew"
runs="$crew_home/runs"
config="$crew_home/config.md"
readiness="$crew_home/readiness.md"
codex_config="${CODEX_HOME:-$HOME/.codex}/config.toml"
failed=0

ok() { echo "OK    $1"; }
warn() { echo "WARN  $1"; }
fail() {
  echo "FAIL  $1"
  failed=1
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
is_set() { printenv "$1" >/dev/null 2>&1; }
config_value() { [ -f "$config" ] && sed -n "s/^$1:[[:space:]]*//p" "$config" | head -n 1; }

# --- which account pays ---
if is_set CODEX_API_KEY; then
  if [ "$(config_value allow_api_billing)" = yes ]; then
    warn "CODEX_API_KEY is set, and config allows it: Codex is billed through the API, not your ChatGPT plan"
  else
    fail "CODEX_API_KEY is set: Codex would bill the API instead of your ChatGPT plan. Run: unset CODEX_API_KEY, and remove it from where it is exported"
  fi
else
  ok "CODEX_API_KEY is not set"
fi
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  if is_set "$v"; then
    warn "$v is set: Claude usage may be billed outside your subscription. Check /status"
  else
    ok "$v is not set"
  fi
done
is_set OPENAI_API_KEY && echo "NOTE  OPENAI_API_KEY is set (it did not replace the ChatGPT login when tested on Codex 0.164.0)"

# --- session effort ---
echo "INFO  effort: CLAUDE_EFFORT=${CLAUDE_EFFORT:-unknown} CLAUDE_CODE_EFFORT_LEVEL=${CLAUDE_CODE_EFFORT_LEVEL:-unset}"

# --- crew's own files ---
guard="$skill_dir/hooks/crew-guard.sh"
if [ -x "$guard" ]; then
  code=0
  "$guard" <<<'{"cwd":"/tmp","tool_input":{"command":"git reset --hard"}}' >/dev/null 2>&1 || code=$?
  if [ "$code" -eq 2 ] && "$guard" <<<'{"cwd":"/tmp","tool_input":{"command":"git log --oneline"}}' >/dev/null 2>&1; then
    ok "guard hook is executable and passes its self tests"
  else
    fail "guard hook failed its self tests. Run ./install.sh again"
  fi
else
  fail "guard hook is missing or not executable: $guard. Run ./install.sh again"
fi
if [ -x "$skill_dir/scripts/secret-scan.sh" ]; then
  ok "secret scanner is executable"
else
  fail "secret scanner is missing or not executable. Run ./install.sh again"
fi
for d in repos boards; do
  if [ -d "$skill_dir/$d" ]; then ok "$d folder exists"; else fail "$d folder is missing. Run ./install.sh again"; fi
done

# --- run records ---
if [ -d "$runs" ]; then
  m=$(mode_of "$runs")
  if [ "$m" = 700 ]; then ok "run records folder is private (700)"; else fail "run records folder has permissions $m, not 700. Run: chmod 700 ~/.crew/runs"; fi
  resolved=$(cd "$runs" && pwd -P)
  case $resolved in
    *"Mobile Documents"* | *iCloud* | *Dropbox* | *"Google Drive"* | *GoogleDrive* | *OneDrive* | *CloudStorage*)
      fail "run records are in a synced folder. Move ~/.crew somewhere that does not sync"
      ;;
    *) ok "run records are not in a synced folder" ;;
  esac
else
  fail "run records folder is missing. Run ./install.sh again"
fi

# --- settings ---
model=$(config_value codex_model)
echo "INFO  codex_model from config: ${model:-not set, so the skill default applies}"

# --- Codex safety, reading only the settings named here ---
if [ -f "$codex_config" ]; then
  flagged=0
  check_setting() { # regex, message
    if grep -Eq "^[[:space:]]*$1" "$codex_config"; then
      warn "Codex config: $2"
      flagged=1
    fi
  }
  check_setting 'sandbox_mode[[:space:]]*=[[:space:]]*"danger-full-access"' 'sandbox_mode is danger-full-access (crew passes its own flags, but your other Codex use is unsandboxed)'
  check_setting 'approval_policy[[:space:]]*=[[:space:]]*"never"' 'approval_policy is never'
  check_setting 'network_access[[:space:]]*=[[:space:]]*true' 'workspace-write network access is on, so Codex could reach the network'
  check_setting 'model_reasoning_effort[[:space:]]*=[[:space:]]*"low"' 'default effort is low (crew passes its own effort, so this does not affect crew runs)'
  [ "$flagged" -eq 1 ] || ok "Codex config has none of the flagged settings"
else
  ok "no Codex config file, so Codex uses its safe defaults"
fi

# --- this repo's notes ---
if url=$(git remote get-url origin 2>/dev/null); then
  slug=$(sed -E 's#\.git$##; s#^.*[:/]([^/:]+)/([^/]+)$#\1__\2#' <<<"$url")
  profile="$skill_dir/repos/$slug.md"
  if [ -f "$profile" ]; then
    ok "repo profile exists: repos/$slug.md"
    cat "$profile" | sed 's/^/PROFILE  /'
  else
    echo "INFO  no repo profile yet for $slug (crew builds it on the first task)"
  fi
  owner=${slug%%__*}
  found=0
  for b in "$skill_dir/boards/$owner"__*.md; do
    [ -f "$b" ] || continue
    found=1
    if grep -q 'board confirmed: yes' "$b"; then ok "board cache confirmed: boards/${b##*/}"; else warn "board cache not confirmed yet: boards/${b##*/}"; fi
    sed 's/^/BOARD  /' "$b"
  done
  [ "$found" -eq 1 ] || echo "INFO  no board cache yet for $owner (crew creates one on the first task)"
else
  echo "INFO  not in a repo with a GitHub remote"
fi

# --- last full check ---
if [ -f "$readiness" ]; then
  sed 's/^/LAST  /' "$readiness"
else
  echo "INFO  no earlier readiness file, so run the full check"
fi

exit "$failed"
