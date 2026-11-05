#!/bin/bash
# Tests for skill/scripts/secret-scan.sh. Run: bash tests/secret-scan-test.sh
# Fake secrets are built from pieces, so this file does not trip the scanner.
root=$(cd "$(dirname "$0")/.." && pwd)
scan="$root/skill/scripts/secret-scan.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

fresh() {
  rm -rf "$tmp/r"
  mkdir -p "$tmp/r"
  cd "$tmp/r" || exit 1
  git init -q -b main .
  git config user.name test
  git config user.email test@example.test
}

long=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP0123456789
expect_found() { # rule-name file-content
  fresh
  printf '%s\n' "$2" >code.txt
  git add code.txt
  local out code
  out=$("$scan" --staged 2>&1)
  code=$?
  if [ "$code" -eq 1 ] && grep -q "$1" <<<"$out"; then ok; else bad "should find $1 (exit $code)"; fi
  # The scan must never echo the secret itself.
  if grep -qF "${long:0:24}" <<<"$out"; then bad "scan printed the secret for $1"; else ok; fi
}

expect_found openai-or-anthropic-key "key = s""k-ant-$long"
expect_found openai-or-anthropic-key "s""k-proj-$long"
expect_found github-token "g""hp_$long"
expect_found github-fine-grained-token "github""_pat_$long"
expect_found aws-access-key "AK""IAABCDEFGHIJKLMNOP $long"
expect_found slack-token "xo""xb-$long"
expect_found google-api-key "AI""zaSy${long:0:33}"
expect_found stripe-key "s""k_live_$long"
expect_found supabase-secret-key "sb_""secret_$long"
expect_found private-key-block "-----BEGIN RSA PRIVATE ""KEY----- $long"
expect_found json-web-token "ey""J${long:0:20}.ey""J${long:0:20}.${long:0:20}"
expect_found oauth-token-in-json "\"refresh_""token\": \"$long\""
expect_found password-in-url "postgres:""//admin:hunter2pass@db.example.test/app $long"
expect_found assigned-secret "MY_API_""KEY=$long"
expect_found local-home-path "see /Us""ers/somebody/project ${long:0:24}"

# Clean content passes.
fresh
cat >code.txt <<'EOF'
const token = process.env.API_TOKEN
Set OPENAI_API_KEY in your environment, never in a file.
Your login lives in ~/.codex/auth.json. Treat it like a password.
git push -u origin crew/1-demo
https://github.com/example/repo
EOF
git add code.txt
if "$scan" --staged >/dev/null 2>&1; then ok; else bad "clean file was flagged"; fi

# Private file names are flagged even when empty, and templates are not.
for name in .env .env.local auth.json .credentials.json hosts.yml id_rsa key.pem server.p12 AuthKey.p8; do
  fresh
  : >"$name"
  git add -f "$name"
  if "$scan" --staged >/dev/null 2>&1; then bad "should flag file name $name"; else ok; fi
done
fresh
: >.env.example
git add .env.example
if "$scan" --staged >/dev/null 2>&1; then ok; else bad ".env.example should be allowed"; fi

# --all sees untracked files, and respects .gitignore.
fresh
echo "g""hp_$long" >new.txt
if "$scan" --all >/dev/null 2>&1; then bad "--all missed an untracked secret"; else ok; fi
fresh
echo '.env' >.gitignore
echo "g""hp_$long" >.env
git add .gitignore
if "$scan" --all >/dev/null 2>&1; then ok; else bad "--all flagged an ignored file"; fi

# --history finds a secret that was committed and later removed.
fresh
echo "g""hp_$long" >old.txt
git add old.txt
git commit -qm add
git rm -q old.txt
git commit -qm remove
if "$scan" --all >/dev/null 2>&1; then ok; else bad "--all should be clean after removal"; fi
if "$scan" --history >/dev/null 2>&1; then bad "--history missed a removed secret"; else ok; fi

# Exit 2 outside a repo and on a bad option.
cd "$tmp" || exit 1
"$scan" --staged >/dev/null 2>&1
if [ $? -eq 2 ]; then ok; else bad "outside a repo should exit 2"; fi
fresh
"$scan" --nonsense >/dev/null 2>&1
if [ $? -eq 2 ]; then ok; else bad "bad option should exit 2"; fi

echo "secret scan tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
