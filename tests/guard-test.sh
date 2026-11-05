#!/bin/bash
# Table tests for skill/hooks/crew-guard.sh. Run: bash tests/guard-test.sh
# Needs git, and jq or python3. Creates only a temporary folder.
root=$(cd "$(dirname "$0")/.." && pwd)
guard="$root/skill/hooks/crew-guard.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A throwaway repo on a feature branch, so branch aware checks have something to read.
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b crew/1-demo
git -C "$repo" -c user.name=test -c user.email=test@example.test commit -q --allow-empty -m init

# Same, but on main.
onmain="$tmp/onmain"
mkdir -p "$onmain"
git -C "$onmain" init -q -b main
git -C "$onmain" -c user.name=test -c user.email=test@example.test commit -q --allow-empty -m init

pass=0
fail=0
run() { # expected_exit cwd command
  local json code
  json=$(python3 -I -c 'import json,sys;print(json.dumps({"cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$2" "$3")
  "$guard" <<<"$json" >/dev/null 2>&1
  code=$?
  if [ "$code" -eq "$1" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL expected %s got %s: %s\n' "$1" "$code" "$3"
  fi
}
block() { run 2 "$repo" "$1"; }
allow() { run 0 "$repo" "$1"; }

# --- the original acceptance list ---
block 'codex exec -c sandbox_workspace_write.network_access=true -'
block 'git -C ../x reset --hard'
block 'git push origin +main'
block 'git branch --delete --force crew/1-x'
allow 'gh issue comment 5 --body "don'"'"'t run git reset --hard"'
allow 'git commit -m "remove git clean step"'
allow 'codex exec --model m --sandbox workspace-write -C . -'

# --- git: never run list ---
block 'git reset --hard HEAD~1'
block 'git clean -fd'
block 'git --no-pager clean -n'
block 'git commit --amend'
block 'git push --force'
block 'git push -f origin crew/1-demo'
block 'git push --force-with-lease origin crew/1-demo'
block 'git push --force-with-lease=crew/1-demo:abc origin crew/1-demo'
block 'git push --mirror'
block 'git push --delete origin crew/1-demo'
block 'git push origin :crew/1-demo'
block 'git branch -D crew/1-demo'
block 'git branch -df crew/1-demo'
block 'git worktree remove --force .claude/worktrees/crew-1'
block 'git worktree prune -f'

# --- git: abbreviated long options, which git accepts ---
block 'git commit --am -m x'
block 'git commit --amen -m x'
block 'git reset --ha'
block 'git reset --har HEAD'
block 'git push --forc origin crew/1-demo'
block 'git push --mirr'
block 'git branch --del --forc x'
block 'git worktree remove --forc .claude/worktrees/crew-1'

# --- git: hiding a command behind an alias or a variable ---
block 'git -c alias.x="reset --hard" x'
block 'git -c alias.x=!rm x'
block 'git --config-env=alias.x=EVIL x'
block 'git config alias.nuke "reset --hard"'
block 'git config --global alias.nuke "reset --hard"'
block 'x=clean; git $x -fd'
block 'git $(echo clean) -fd'
allow 'git -c user.name=me status'
allow 'git config --get alias.st'
allow 'git config user.name'

# --- git: nobody merges, so no direct pushes to the main branch ---
block 'git push origin main'
block 'git push origin master'
block 'git push origin HEAD:main'
block 'git push origin HEAD:refs/heads/main'
block 'git push origin crew/1-demo:main'
block 'git push --all origin'
allow 'git push -u origin crew/1-demo'
allow 'git push origin HEAD:crew/1-demo'
allow 'git push'
run 2 "$onmain" 'git push'
run 2 "$onmain" 'git push -u origin'
run 0 "$onmain" 'git push origin crew/1-demo'

# A remote with no main yet: the first push of a new repo has nothing to protect.
bare_empty="$tmp/empty.git"
git init -q --bare "$bare_empty"
git -C "$onmain" remote add origin "$bare_empty"
run 0 "$onmain" 'git push -u origin main'
run 0 "$onmain" 'git push'
# Once main exists on the remote, the same pushes are blocked.
git -C "$onmain" push -q origin main
run 2 "$onmain" 'git push -u origin main'
run 2 "$onmain" 'git push'
run 2 "$onmain" 'git push origin HEAD:main'
# A remote that cannot be reached counts as "main exists".
git -C "$onmain" remote set-url origin "$tmp/does-not-exist.git"
run 2 "$onmain" 'git push -u origin main'

# --- git: discarding the owner's work outside a crew worktree ---
block 'git checkout -- file.txt'
block 'git checkout .'
block 'git checkout -f main'
block 'git checkout --forc main'
block 'git checkout main file.txt'
block 'git restore file.txt'
block 'git switch --discard-changes main'
block 'git stash'
block 'git stash drop'
allow 'git stash list'
allow 'git restore --staged file.txt'
allow 'git checkout crew/1-demo'
allow 'git checkout -b crew/2-next'
allow 'git switch crew/1-demo'
wt="$repo/.claude/worktrees/crew-1"
mkdir -p "$wt"
run 0 "$wt" 'git checkout -- file.txt'
run 0 "$wt" 'git restore file.txt'
run 0 "$wt" 'git stash'
run 2 "$wt" 'git clean -fd'
run 2 "$wt" 'git -C ../../.. checkout -- file.txt'

# --- gh ---
block 'gh pr merge 5'
block 'gh -R o/r pr merge 5 --squash'
block 'gh issue delete 5'
block 'gh issue transfer 5 o/other'
block 'gh project delete 1'
block 'gh label delete bug'
block 'gh repo delete o/r --yes'
block 'gh api -X DELETE repos/o/r/issues/1'
block 'gh api --method delete repos/o/r/git/refs/heads/x'
block 'gh api -XDELETE repos/o/r'
block 'gh api repos/o/r/pulls/1/merge -X PUT'
block 'gh api graphql -f query="mutation { mergePullRequest(input:{}) { clientMutationId } }"'
block 'gh alias set m "pr merge"'
block 'gh alias import aliases.yml'
allow 'gh pr view 5 --json state'
allow 'gh pr create --base main --head crew/1-demo --title t --body-file b.md'
allow 'gh issue create --title t --body-file b.md --parent 3 --blocked-by 4,5'
allow 'gh api rate_limit --jq .resources'
allow 'gh alias list'
allow 'gh issue comment 5 --body "gh pr merge is not allowed"'

# --- codex: sandbox and approvals ---
block 'codex exec --dangerously-bypass-approvals-and-sandbox -'
block 'codex exec --dangerously-bypass-hook-trust -'
block 'codex exec --sandbox danger-full-access -'
block 'codex exec -s danger-full-access -'
block 'codex exec -sdanger-full-access -'
block 'codex exec --sandbox=danger-full-access -'
block 'codex exec --add-dir /etc -'
block 'codex exec -p fast -'
block 'codex exec -pfast -'
block 'codex exec --profile fast -'
block 'codex -a never exec -'
block 'codex -anever exec -'
block 'codex exec --approve-for-me -'
block 'codex exec --ignore-rules -'
block 'codex exec --ignore-user-config -'
block 'codex --search exec -'
block 'codex exec --enable some_feature -'
block 'codex exec --disable some_feature -'
block 'codex --remote ws://example.test exec -'
block 'codex exec -c sandbox_mode=danger-full-access -'
block 'codex exec -c approval_policy=never -'
block 'codex exec --config=sandbox_mode=danger-full-access -'
block 'codex exec -c shell_environment_policy.inherit=all -'
block 'codex exec -c mcp_servers.x.command=evil -'
block 'codex exec -c notify=["evil"] -'
block 'codex exec -c profile=fast -'
block 'codex exec -csandbox_mode=danger-full-access -'
block 'CODEX_HOME=/tmp/x codex exec -'
block 'env CODEX_HOME=/tmp/x codex exec -'
block 'codex delete abc'
block 'codex logout'
block 'codex login'
block 'codex login --with-api-key'
block 'codex exec -c sandbox_mode=workspace-write -'
block 'codex exec resume abc -c sandbox_mode=danger-full-access -'
allow 'codex login status'
allow 'codex --version'
allow 'codex exec --model m --sandbox read-only -C . -c model_reasoning_effort=high --json -o out.md - < in.md > log 2>&1'
allow 'cd wt && codex exec resume abc --model m -c sandbox_mode="workspace-write" -c model_reasoning_effort=medium --json -o r.md - < p.md > l.log 2>&1'

# --- credentials stay out of reach ---
block 'gh auth token'
block 'gh auth status --show-token'
block 'gh auth status -t'
block 'cat ~/.codex/auth.json'
block 'cp ~/.codex/auth.json /tmp/x'
block 'cat ~/.claude/.credentials.json'
block 'cat "$HOME/.config/gh/hosts.yml"'
allow 'gh auth status'
allow 'codex login status'
allow 'grep -rn "auth.json is a password" README.md'

# --- deploy and publish commands ---
block 'vercel'
block 'vercel --prod'
block 'vercel deploy'
block 'npx vercel deploy --prod'
block 'pnpm dlx vercel deploy'
block 'netlify deploy --prod'
block 'fly deploy'
block 'firebase deploy'
block 'wrangler deploy'
block 'railway up'
block 'eas submit'
block 'terraform apply'
block 'kubectl apply -f x.yml'
block 'helm upgrade x y'
block 'docker push x/y'
block 'npm publish'
block 'pnpm publish'
block 'supabase db push'
block 'supabase db reset --linked'
block 'supabase functions deploy chat'
block 'supabase secrets set KEY=value'
allow 'vercel dev'
allow 'vercel env pull .env.local'
allow 'vercel logs'
allow 'supabase start'
allow 'supabase db reset'
allow 'supabase db push --local'
allow 'supabase functions serve'
allow 'npm test'
allow 'npm install'
allow 'docker ps'
allow 'cat ./vercel'
allow 'ls supabase'
allow 'grep -r "vercel deploy" docs'

# --- wrappers and nesting ---
block 'bash -c "git reset --hard"'
block 'sh -lc "git clean -fd"'
block 'eval "git reset --hard"'
block 'echo "$(git reset --hard)"'
block 'echo `git clean -fd`'
block 'bash <<EOF
git reset --hard
EOF'
block 'cat script | bash'
block 'printf "git reset --hard" | sh'
block 'cat x |& bash'
block 'cd /tmp && git reset --hard'
block 'true; git clean -fd'
block 'false || git clean -fd'
block '/usr/bin/git reset --hard'
block 'command git reset --hard'
block 'env FOO=1 git clean'
block 'find . -name x -exec git clean \;'
block 'gi""t re"se"t --hard'
allow 'cat <<EOF
git reset --hard
EOF'
allow 'git commit -m "$(cat <<EOF
git reset --hard and git clean are both mentioned here
EOF
)"'
allow 'echo hello | tee out.txt'
allow 'false || sh script.sh'
allow 'bash script.sh'
allow 'cat x | bash script.sh'
allow 'git status # git reset --hard'
allow 'git log --oneline'

# --- edge cases that used to read stale words ---
allow 'git status; cd'
allow 'gh api rate_limit -X; gh pr view 1'

# --- fails closed: the command is blocked if the checker cannot finish ---
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
printf '#!/bin/sh\nexit 1\n' >"$fakebin/awk"
chmod +x "$fakebin/awk"
json='{"cwd":"/tmp","tool_input":{"command":"git status"}}'
PATH="$fakebin:$PATH" "$guard" <<<"$json" >/dev/null 2>&1
if [ $? -eq 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo 'FAIL guard did not fail closed when awk failed'; fi
printf '#!/bin/sh\nexit 0\n' >"$fakebin/awk"
PATH="$fakebin:$PATH" "$guard" <<<"$json" >/dev/null 2>&1
if [ $? -eq 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo 'FAIL guard did not fail closed when awk printed nothing'; fi
"$guard" <<<'not json' >/dev/null 2>&1
if [ $? -eq 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo 'FAIL guard did not fail closed on bad JSON'; fi

echo "guard tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
