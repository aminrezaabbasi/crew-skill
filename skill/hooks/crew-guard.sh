#!/bin/bash
# crew-guard.sh: PreToolUse hook for the Bash tool. Blocks crew's never run list.
# Reads the hook JSON on stdin. Exit 2 with a reason on stderr blocks; exit 0 allows.
#
# How it matches: the command is split into shell words the way bash would see
# them. Quoted strings stay single words and heredoc bodies are dropped, so a
# commit message or issue comment that mentions a command never matches. Words
# are split into parts on ; && || | ( ) ` $( and newlines, and each part is
# checked on its own, with flags matched anywhere after the subcommand.
# Code that really runs is still checked: "$(...)" inside double quotes,
# bash/sh -c "...", eval, and heredocs fed to a shell.
#
# It fails closed: if the checker cannot run or finish, the command is blocked.
#
# What it is not: a sandbox. It stops honest mistakes and commands written
# directly in a Bash call. It cannot see inside scripts, or inside other
# languages (python -c, node -e). The README lists these limits.

input=$(cat)
if command -v jq >/dev/null 2>&1; then
  cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null) || cmd=__unparsed__
  cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null)
else
  # Fallback without jq: python3 standard library only.
  cmd=$(python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("tool_input",{}).get("command",""),end="")' <<<"$input" 2>/dev/null) || cmd=__unparsed__
  cwd=$(python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("cwd",""),end="")' <<<"$input" 2>/dev/null)
fi
if [ "$cmd" = __unparsed__ ]; then
  echo "crew-guard: could not read the command (needs jq or python3), so it is blocked to be safe." >&2
  exit 2
fi

read -r -d '' PROG <<'AWK'
function base(p,   n, parts) { n = split(p, parts, "/"); return parts[n] }
function resolve(d, p) {
  if (p == "" || p == "~") return HOME
  if (substr(p, 1, 2) == "~/") return HOME substr(p, 2)
  if (substr(p, 1, 1) == "/") return p
  return d "/" p
}
function block(why) { if (BLOCKED == "") BLOCKED = why }
function push(s) { Q[++NQ] = s }
function endtok() { if (intok) T[++NT] = tok; tok = ""; intok = 0 }
function endseg(   z) {
  endtok()
  if (NT > 0) check()
  for (z = 1; z <= NT; z++) delete T[z]
  NT = 0; PIPED = 0; CUT = 0
}
function has(from, x,   i) { for (i = from; i <= NT; i++) if (T[i] == x) return 1; return 0 }
# A bundle of short flags such as -f, -fu or -df that contains the letter.
function isshort(t, letter) { return t ~ /^-[A-Za-z0-9]+$/ && index(t, letter) > 0 }
# Git accepts any unique start of a long option (--am means --amend), so match those too.
function longopt(t, full, min,   name) {
  name = t; sub(/=.*/, "", name)
  return length(name) >= min && index(full, name) == 1
}
function close_paren(s, m,   depth, ch) {
  for (depth = 1; m <= length(s); m++) {
    ch = substr(s, m, 1)
    if (ch == "(") depth++
    if (ch == ")" && --depth == 0) return m
  }
  return length(s) + 1
}

# Split one command string into words and parts.
function parse(s,   L, i, c, n2, j, k, e, ch, x, h, nh, hd, hs, hx, line, body, delim, strip, shell) {
  L = length(s); NT = 0; tok = ""; intok = 0; nh = 0; PIPED = 0; CUT = 0
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1); n2 = substr(s, i + 1, 1)
    if (c == "\\") { if (n2 != "\n") { tok = tok n2; intok = 1 }; i++; continue }
    if (c == "'") {
      j = index(substr(s, i + 1), "'"); if (j == 0) j = L - i + 1
      tok = tok substr(s, i + 1, j - 1); intok = 1; i += j; continue
    }
    if (c == "\"") {
      intok = 1
      for (k = i + 1; k <= L; k++) {
        ch = substr(s, k, 1); x = substr(s, k + 1, 1)
        if (ch == "\\" && x != "" && index("$`\"\\\n", x)) { tok = tok x; k++; continue }
        if (ch == "\"") break
        if (ch == "$" && x == "(") { e = close_paren(s, k + 2); push(substr(s, k + 2, e - k - 2)); k = e; continue }
        if (ch == "`") { e = index(substr(s, k + 1), "`"); if (e == 0) e = L - k + 1; push(substr(s, k + 1, e - 1)); k += e; continue }
        tok = tok ch
      }
      i = k; continue
    }
    if (c == "#" && !intok) { j = index(substr(s, i), "\n"); i = (j ? i + j - 2 : L); continue }
    if (c == " " || c == "\t") { endtok(); continue }
    if (c == "<" && n2 == "<" && substr(s, i + 2, 1) == "<") { tok = tok "<<<"; intok = 1; i += 2; continue }
    if (c == "<" && n2 == "<") {
      # Heredoc: remember the delimiter; the body is skipped after the newline.
      endtok(); j = i + 2; strip = 0
      if (substr(s, j, 1) == "-") { strip = 1; j++ }
      while (substr(s, j, 1) ~ /[ \t]/) j++
      delim = ""
      while (j <= L && (ch = substr(s, j, 1)) !~ /[ \t\n;&|<>()]/) { if (ch !~ /["'\\]/) delim = delim ch; j++ }
      shell = 0
      for (k = 1; k <= NT; k++) if (base(T[k]) ~ /^(bash|sh|zsh|dash|ksh)$/) shell = 1
      hd[++nh] = delim; hs[nh] = strip; hx[nh] = shell
      i = j - 1; continue
    }
    if (c == "&" && (n2 == ">" || substr(s, i - 1, 1) ~ /[<>]/)) { tok = tok c; intok = 1; continue }
    if (c == "$" && n2 == "(") { endtok(); CUT = 1; endseg(); i++; continue }
    if (c == "|") {
      endseg()
      if (n2 == "|") i++
      else { if (n2 == "&") i++; PIPED = 1 }
      continue
    }
    if (index(";&()`", c)) { endseg(); continue }
    if (c == "\n") {
      endseg()
      for (h = 1; h <= nh; h++) {
        body = ""
        while (i < L) {
          e = index(substr(s, i + 1), "\n"); if (e == 0) e = L - i + 1
          line = substr(s, i + 1, e - 1); i += e
          x = line; if (hs[h]) sub(/^\t+/, "", x)
          if (x == hd[h]) break
          body = body line "\n"
        }
        if (hx[h]) push(body)   # a heredoc fed to a shell is code, so check it
      }
      nh = 0; continue
    }
    tok = tok c; intok = 1
  }
  endseg()
}

# Check one part (words T[1..NT]).
function check(   i, j, p, b, joined, c, script) {
  for (i = 1; i <= NT; i++) {
    b = base(T[i])
    if (T[i] ~ /(^|\/)\.codex\/auth\.json$|(^|\/)\.claude\/\.credentials\.json$|(^|\/)\.config\/gh\/hosts\.yml$/) block("touching a credential file (" b ")")
    if (b ~ /^(bash|sh|zsh|dash|ksh)$/)
      for (j = i + 1; j < NT; j++) if (T[j] ~ /^-[A-Za-z]*c[A-Za-z]*$/) { push(T[j + 1]); break }
    if (T[i] == "eval") { joined = ""; for (j = i + 1; j <= NT; j++) joined = joined " " T[j]; push(joined) }
  }
  if (T[1] == "cd") { DIR = (NT >= 2 ? resolve(DIR, T[2]) : HOME); return }
  c = cmdpos()
  if (c <= NT) {
    b = base(T[c])
    if (PIPED && b ~ /^(bash|sh|zsh|dash|ksh)$/) {
      script = 0
      for (j = c + 1; j <= NT; j++) if (T[j] !~ /^-/) script = 1
      if (!script) block("piping text into a shell")
    }
    check_deploy(c, b)
  }
  for (p = 1; p <= NT; p++) { b = base(T[p]); if (b == "git" || b == "gh" || b == "codex") break }
  if (p > NT) return
  if (b == "git") check_git(p)
  else if (b == "gh") check_gh(p)
  else check_codex(p)
}

# Where the real command sits, past VAR=value prefixes and wrappers like npx.
function cmdpos(   i, b) {
  for (i = 1; i <= NT; i++) {
    if (T[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || T[i] ~ /^-/) continue
    b = base(T[i])
    if (b ~ /^(env|command|exec|sudo|time|nice|nohup|npx|bunx|xargs)$/) continue
    if (b ~ /^(npm|pnpm|yarn|bun)$/ && T[i + 1] ~ /^(dlx|exec|x)$/) { i++; continue }
    return i
  }
  return NT + 1
}

# Common deploy and publish commands. Local work (supabase start, vercel dev) stays allowed.
function check_deploy(c, b,   i, words) {
  if (b == "vercel") {
    words = 0
    for (i = c + 1; i <= NT; i++) if (T[i] !~ /^-/) words++
    if (!words || has(c + 1, "deploy") || has(c + 1, "promote") || has(c + 1, "rollback") || has(c + 1, "redeploy") || has(c + 1, "--prod") || has(c + 1, "--production")) block("vercel deploy")
  }
  else if (b ~ /^(netlify|fly|flyctl|firebase)$/ && has(c + 1, "deploy")) block(b " deploy")
  else if (b == "wrangler" && (has(c + 1, "deploy") || has(c + 1, "publish"))) block("wrangler deploy")
  else if (b == "railway" && has(c + 1, "up")) block("railway up")
  else if (b == "eas" && has(c + 1, "submit")) block("eas submit")
  else if (b == "terraform" && (has(c + 1, "apply") || has(c + 1, "destroy"))) block("terraform apply or destroy")
  else if (b == "kubectl" && (has(c + 1, "apply") || has(c + 1, "delete"))) block("kubectl apply or delete")
  else if (b == "helm" && (has(c + 1, "install") || has(c + 1, "upgrade") || has(c + 1, "uninstall"))) block("helm change")
  else if (b == "docker" && has(c + 1, "push")) block("docker push")
  else if (b ~ /^(npm|pnpm|yarn|bun)$/ && has(c + 1, "publish")) block(b " publish")
  else if (b == "supabase") {
    if (has(c + 1, "db") && has(c + 1, "push") && !has(c + 1, "--local")) block("supabase db push to a remote project")
    else if (has(c + 1, "db") && has(c + 1, "reset") && has(c + 1, "--linked")) block("supabase db reset --linked")
    else if (has(c + 1, "functions") && has(c + 1, "deploy")) block("supabase functions deploy")
    else if (has(c + 1, "secrets") && has(c + 1, "set")) block("supabase secrets set")
  }
}

function check_git(p,   k, t, d, sc, i, del, force) {
  d = DIR
  for (k = p + 1; k <= NT; k++) {   # skip git's global options to find the subcommand
    t = T[k]
    if (t == "-C") { d = resolve(d, T[++k]); continue }
    if (t == "-c" || t == "--config-env") {
      if (T[k + 1] ~ /^alias\./) block("git " t " " T[k + 1] " (an inline alias could hide any command)")
      k++; continue
    }
    if (t ~ /^--config-env=alias\./) { block("git inline alias"); continue }
    if (t ~ /^(--git-dir|--work-tree|--namespace|--super-prefix)$/) { k++; continue }
    if (t ~ /^--work-tree=/) { d = resolve(d, substr(t, 13)); continue }
    if (t ~ /^-/) continue
    break
  }
  sc = T[k]
  if (k > NT && CUT) block("git with its subcommand from $(...)")
  if (sc ~ /^[$`]/) block("git with its subcommand from a variable")
  if (sc == "push") check_push(k, d)
  else if (sc == "commit") {
    for (i = k + 1; i <= NT; i++) if (longopt(T[i], "--amend", 4)) block("git commit --amend")
  }
  else if (sc == "reset") {
    for (i = k + 1; i <= NT; i++) if (longopt(T[i], "--hard", 4)) block("git reset --hard")
  }
  else if (sc == "clean") block("git clean")
  else if (sc ~ /^(checkout|restore|switch)$/ && !inworktree(d)) check_discard(sc, k, d)
  else if (sc == "stash" && !inworktree(d) && T[k + 1] !~ /^(list|show)$/) block("git stash outside a crew worktree")
  else if (sc == "branch") {
    for (i = k + 1; i <= NT; i++) {
      t = T[i]
      if (longopt(t, "--delete", 5) || isshort(t, "d")) del = 1
      if (longopt(t, "--force", 4) || isshort(t, "f")) force = 1
      if (isshort(t, "D")) block("git branch -D")
    }
    if (del && force) block("git branch --delete --force")
  }
  else if (sc == "worktree" && T[k + 1] ~ /^(remove|prune)$/) {
    for (i = k + 2; i <= NT; i++) if (longopt(T[i], "--force", 3) || isshort(T[i], "f")) block("git worktree " T[k + 1] " --force")
  }
  else if (sc == "config" && !has(k + 1, "--get") && !has(k + 1, "--list") && !has(k + 1, "-l")) {
    for (i = k + 1; i <= NT; i++) if (T[i] ~ /^alias\./ && i < NT) block("git config " T[i] " (an alias could hide any command)")
  }
}

# A path is inside a crew worktree only if it names one and does not climb back out.
function inworktree(d) { return d ~ /\/\.claude\/worktrees\/crew-/ && d !~ /\/\.\.(\/|$)/ }

function protected_branch(r) { sub(/^refs\/heads\//, "", r); return r ~ /^(main|master)$/ }

function check_push(k, d,   i, t, n, r, dst, remote) {
  n = 0; remote = "origin"
  for (i = k + 1; i <= NT; i++) {
    t = T[i]
    if (t ~ /^(-o|--push-option|--repo|--receive-pack|--exec)$/) { i++; continue }
    if (longopt(t, "--force-with-lease", 5) || longopt(t, "--force-if-includes", 5) || longopt(t, "--mirror", 4) || longopt(t, "--delete", 4) || longopt(t, "--prune", 4) || t == "--all" || t == "--branches" || isshort(t, "f") || isshort(t, "d")) block("git push " t)
    else if (t ~ /^-/) continue
    else if (++n == 1) remote = t
    else {
      r = t
      if (r ~ /^[+:]/) { block("git push with refspec " r); continue }
      dst = r; if (index(r, ":")) sub(/^[^:]*:/, "", dst)
      # A first push that creates the branch has nothing to protect; bash asks the remote.
      if (protected_branch(dst)) { sub(/^refs\/heads\//, "", dst); print "CHECKMAIN\t" d "\t" remote "\t" dst }
    }
  }
  # With no branch named, git pushes the current one, so ask git what that is.
  if (n < 2) print "CHECKPUSH\t" d "\t" remote
}

# checkout, restore, or switch outside a crew worktree: block anything that
# would overwrite uncommitted work. A lone checkout argument is sent back to
# bash, which asks git whether it is a branch or commit (fine) or a path (block).
function check_discard(sc, k, d,   i, t, n, args, staged, wt, newb) {
  n = 0
  for (i = k + 1; i <= NT; i++) {
    t = T[i]
    if (t == "--") { block("git " sc " -- <paths>"); return }
    if (t ~ /^(-f|-p|-m|--pathspec-from-file.*)$/ || longopt(t, "--force", 3) || longopt(t, "--patch", 4) || longopt(t, "--ours", 3) || longopt(t, "--theirs", 3) || longopt(t, "--merge", 3) || longopt(t, "--discard-changes", 3)) { block("git " sc " " t); return }
    if (t ~ /^(-W|--worktree)$/) wt = 1
    else if (t ~ /^(-S|--staged)$/) staged = 1
    else if (t ~ /^(-b|-B|-c|-C|--orphan)$/) newb = 1
    else if (t !~ /^-/) args[++n] = t
  }
  if (sc == "restore") { if (!staged || wt) block("git restore (discards uncommitted changes)"); return }
  if (sc == "switch" || newb) return
  if (n >= 2) { block("git checkout <ref> <paths>"); return }
  if (n == 1 && args[1] != "-") print "CHECKREF\t" d "\t" args[1]
}

function check_gh(p,   k, t, n, w, i) {
  n = 0
  for (k = p + 1; k <= NT && n < 2; k++) {
    t = T[k]
    if (t == "-R" || t == "--repo") { k++; continue }
    if (t ~ /^-/) continue
    w[++n] = t
  }
  if (n == 0 && CUT) block("gh with its subcommand from $(...)")
  if (w[1] ~ /^[$`]/) block("gh with its subcommand from a variable")
  if (w[1] == "api") {
    for (i = p + 1; i <= NT; i++) {
      t = T[i]
      if ((t == "-X" || t == "--method") && toupper(T[i + 1]) == "DELETE") block("gh api DELETE")
      if (toupper(t) == "-XDELETE" || toupper(t) == "--METHOD=DELETE") block("gh api DELETE")
      if (t ~ /\/merges?(\?|$)/) block("gh api merge endpoint")
      if (t ~ /(merge|delete|transfer)[A-Z]|AutoMerge/) block("gh api GraphQL merge, delete, or transfer mutation")
    }
  }
  else if (w[1] == "auth" && (w[2] == "token" || has(p + 1, "--show-token") || has(p + 1, "-t"))) block("gh auth printing a token")
  else if (w[1] == "alias" && w[2] ~ /^(set|import)$/) block("gh alias " w[2] " (an alias could hide any command)")
  else if (w[2] ~ /delete/) block("gh " w[1] " " w[2])
  else if (w[1] == "pr" && w[2] == "merge") block("gh pr merge")
  else if (w[1] == "issue" && w[2] == "transfer") block("gh issue transfer")
}

function check_codex(p,   i, t, v, opt, key, resume, sub1) {
  for (i = 1; i < p; i++) if (T[i] ~ /^CODEX_HOME=/) block("codex with a different CODEX_HOME")
  sub1 = T[p + 1]
  if (sub1 ~ /^(delete|logout)$/) block("codex " sub1)
  if (sub1 == "login" && T[p + 2] != "status") block("codex login (the owner signs in)")
  for (i = p + 1; i <= NT; i++) if (T[i] == "resume") resume = 1
  for (i = p + 1; i <= NT; i++) {
    t = T[i]
    if (t !~ /^-/) continue
    opt = t; v = ""
    if (t ~ /^--[^=]+=/) { opt = substr(t, 1, index(t, "=") - 1); v = substr(t, index(t, "=") + 1) }
    else if (t ~ /^-[casp]./) { opt = substr(t, 1, 2); v = substr(t, 3); sub(/^=/, "", v) }
    else if (t ~ /^(-c|--config|-s|--sandbox|-a|--ask-for-approval|--enable|--disable)$/) v = T[++i]
    if (tolower(t " " v) ~ /danger-full-access|dangerously|bypass|yolo/) { block("codex " t " " v); continue }
    if (opt ~ /^(--add-dir|-p|--profile|--approve-for-me|--ignore-rules|--ignore-user-config|--search|--cyber-access-program|--remote|--remote-auth-token-env|--enable|--disable)$/) block("codex " opt)
    else if (opt == "-c" || opt == "--config") {
      # An allow list, because a config override can change almost anything:
      # sandbox, network, environment passed to Codex, or commands it starts.
      # Only exception: resume may restate a safe sandbox, because
      # `codex exec resume` has no --sandbox flag.
      key = tolower(v); sub(/=.*/, "", key)
      if (key == "model_reasoning_effort" || key == "model") continue
      if (resume && v ~ /^sandbox_mode=["']?(workspace-write|read-only)["']?$/) continue
      block("codex -c " v)
    }
    else if ((opt == "-s" || opt == "--sandbox") && v !~ /^(read-only|workspace-write)$/) block("codex --sandbox " v)
    else if ((opt == "-a" || opt == "--ask-for-approval") && v == "never") block("codex " opt " never")
  }
}

BEGIN {
  HOME = ENVIRON["HOME"]; DIR = ENVIRON["CREW_CWD"]
  push(ENVIRON["CREW_CMD"])
  for (q = 1; q <= NQ && q <= 50; q++) parse(Q[q])
  if (NQ > 50) block("too many nested commands to check")
  if (BLOCKED != "") print "BLOCK\t" BLOCKED
  print "DONE"
}
AWK

out=$(CREW_CMD="$cmd" CREW_CWD="${cwd:-$PWD}" awk "$PROG" </dev/null 2>/dev/null)
status=$?
reason=""
done_seen=""
# Exit 2 from ls-remote means the remote answered and the branch does not exist.
# Anything else, including no network, counts as "it exists", so the push is blocked.
main_exists() { git -C "$1" ls-remote --exit-code --heads "$2" "$3" >/dev/null 2>&1; [ $? -ne 2 ]; }

while IFS=$'\t' read -r kind a b c; do
  case $kind in
    DONE) done_seen=1 ;;
    BLOCK) reason=$a ;;
    CHECKREF)
      git -C "$a" rev-parse --verify --quiet "$b^{commit}" >/dev/null 2>&1 ||
        git -C "$a" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1 ||
        reason="git checkout $b (not a branch or commit here, so it would discard changes to that path)" ;;
    CHECKPUSH)
      current=$(git -C "$a" branch --show-current 2>/dev/null)
      case $current in
        main|master) main_exists "$a" "$b" "$current" && reason="git push from $current (open a pull request instead)" ;;
      esac ;;
    CHECKMAIN)
      main_exists "$a" "$b" "$c" && reason="git push straight to $c (open a pull request instead)" ;;
  esac
done <<<"$out"

if [ "$status" -ne 0 ] || [ -z "$done_seen" ]; then
  echo "crew-guard: the checker could not finish, so this command is blocked to be safe." >&2
  exit 2
fi
if [ -n "$reason" ]; then
  echo "crew-guard blocked: $reason. This is on crew's never run list. Ask the owner to run it themselves if it is truly needed." >&2
  exit 2
fi
exit 0
