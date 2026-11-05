#!/bin/bash
# secret-scan.sh: look for credentials and private files before they leave this machine.
# Prints only the file, the line, and the rule name, never the matched text,
# so the scan itself cannot leak a secret into a log, a run record, or a chat.
#
#   secret-scan.sh            staged changes (the default, for commits)
#   secret-scan.sh --all      every tracked or new file that is not ignored
#   secret-scan.sh --history  every commit on every branch
#
# Exit 0 clean, exit 1 findings, exit 2 could not run.
# This is a safety net for common token shapes, not proof that nothing leaked.

mode=${1:---staged}
case $mode in
  --staged | --all | --history) ;;
  *)
    echo "usage: secret-scan.sh [--staged|--all|--history]" >&2
    exit 2
    ;;
esac

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "secret-scan: not inside a git repository" >&2
  exit 2
fi

# name|extended regular expression
rules='openai-or-anthropic-key|sk-(ant-|proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}
github-token|gh[pousr]_[A-Za-z0-9]{36,}
github-fine-grained-token|github_pat_[A-Za-z0-9_]{22,}
aws-access-key|(AKIA|ASIA)[0-9A-Z]{16}
slack-token|xox[abeoprs]-[A-Za-z0-9-]{10,}
google-api-key|AIza[0-9A-Za-z_-]{35}
stripe-key|(sk|rk)_live_[A-Za-z0-9]{16,}
stripe-webhook-secret|whsec_[A-Za-z0-9]{16,}
supabase-secret-key|sb_secret_[A-Za-z0-9_-]{16,}
vercel-token|vc[pkai]_[A-Za-z0-9]{24,}
npm-token|npm_[A-Za-z0-9]{36,}
private-key-block|-----BEGIN [A-Z ]*PRIVATE KEY-----
json-web-token|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
oauth-token-in-json|"(access_token|refresh_token|id_token)"[[:space:]]*:[[:space:]]*"[^"]{16,}"
password-in-url|[a-z][a-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]{3,}@[A-Za-z0-9.-]+
assigned-secret|[A-Za-z_]*(api[_-]?key|apikey|secret|token|passwd|password)[A-Za-z_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+_=-]{24,}
local-home-path|(/Users/|/home/)[a-z][a-z0-9._-]+/'

# Files that should never be committed, whatever they contain.
bad_name() {
  case ${1##*/} in
    .env.example | .env.sample | .env.template) return 1 ;;
    .env | .env.* | auth.json | .credentials.json | credentials.json | hosts.yml | \
      id_rsa | id_ed25519 | id_ecdsa | id_dsa | .netrc | .npmrc | .pypirc | \
      *.pem | *.key | *.p12 | *.pfx | *.p8 | *.keystore | *.jks | *.mobileprovision | *.cer)
      return 0
      ;;
  esac
  return 1
}

found=0
report() {
  echo "secret-scan: $1"
  found=1
}

check_names() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if bad_name "$f"; then report "$f: private file type (rule: file-name)"; fi
  done
}

# Prints "path:line: rule" and drops the matched text.
strip_match() {
  awk -v rule="$1" -F: '{ print $1 ":" $2 ": rule " rule }'
}

case $mode in
  --staged)
    check_names < <(git diff --cached --name-only --diff-filter=ACMR)
    ;;
  --all)
    check_names < <(git ls-files --cached --others --exclude-standard)
    ;;
  --history)
    check_names < <(git log --all --name-only --format= --diff-filter=ACMR | sort -u)
    ;;
esac

while IFS='|' read -r name pattern; do
  # Variable names come in any case (API_KEY, apiKey). Token shapes are exact.
  flags=-nIE
  [ "$name" = assigned-secret ] && flags=-inIE
  case $mode in
    --staged) hits=$(git grep --cached "$flags" -e "$pattern" 2>/dev/null | strip_match "$name") ;;
    --all) hits=$(git grep --untracked "$flags" -e "$pattern" 2>/dev/null | strip_match "$name") ;;
    --history)
      hits=$(git rev-list --all | while read -r rev; do
        git grep "$flags" -e "$pattern" "$rev" 2>/dev/null | awk -v rule="$name" -F: '{ print substr($1, 1, 12) " " $2 ":" $3 ": rule " rule }'
      done | sort -u)
      ;;
  esac
  if [ -n "$hits" ]; then
    while IFS= read -r line; do report "$line"; done <<<"$hits"
  fi
done <<<"$rules"

if [ "$found" -ne 0 ]; then
  echo "secret-scan: findings above. Do not commit or push until each one is explained." >&2
  exit 1
fi
echo "secret-scan: clean ($mode)"
exit 0
