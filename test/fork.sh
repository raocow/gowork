#!/usr/bin/env bash
# Tests for `gp fork sync` (gw fork sync): a clone whose origin is the fork and
# whose upstream is what it was forked from. Real git against bare repos in a
# throwaway $HOME, no network. Runs the commands under /bin/bash (macOS's bash
# 3.2) when there is one, since that's the stricter of the two.
# Run: test/fork.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SH=/bin/bash; [ -x "$SH" ] || SH=bash
pass=0 fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
saw()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (output: $2)" ;; esac; }
nosaw(){ case "$2" in *"$3"*) bad "$1 (output: $2)" ;; *) ok "$1" ;; esac; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
# Never run against an empty path: every repo below is created under it, and
# the git commands would otherwise land in whatever repo the caller is in.
[ -n "$TMP" ] && [ -d "$TMP" ] && [ "$TMP" != / ] || { echo "no temp dir; aborting" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" GIT_CONFIG_GLOBAL="$TMP/.gitconfig" GIT_CONFIG_NOSYSTEM=1 NO_COLOR=1
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch master

UP="$TMP/upstream.git" FORK="$TMP/fork.git" SEED="$TMP/seed" CLONE="$TMP/clone"
git init -q --bare "$UP"
git clone -q "$UP" "$SEED" 2>/dev/null
n=0
# A new commit on upstream's master, as if merged there by someone else.
upstream_commit() {
  n=$((n + 1)); echo "$n" > "$SEED/up$n"
  git -C "$SEED" add -A && git -C "$SEED" commit -qm "upstream $n" && git -C "$SEED" push -q origin master
}
upstream_commit
git clone -q --bare "$UP" "$FORK"            # the fork on GitHub
git clone -q "$FORK" "$CLONE" 2>/dev/null    # your clone of it
cd "$CLONE" || { echo "couldn't cd into $CLONE; aborting" >&2; exit 1; }

fs()  { "$SH" "$ROOT/bin/gp-fork" sync "$@" 2>&1; }
rev() { git -C "$1" rev-parse "$2"; }

echo "== guards =="
out="$(fs)"; rc=$?
check "no upstream remote: fails"           "$rc" "1"
saw   "no upstream remote: says how to add" "$out" "git remote add upstream <url>"
git remote add upstream "$UP"
out="$(fs -b nope)"; rc=$?
check "upstream lacks the branch: fails"    "$rc" "1"
saw   "upstream lacks the branch: says so"  "$out" "upstream has no 'nope' branch"
out="$("$SH" "$ROOT/bin/gp-fork" 2>&1)"; rc=$?
check "no subcommand: usage error"          "$rc" "2"

echo "== on the base branch =="
upstream_commit
out="$(fs)"; rc=$?
check "exit 0"                              "$rc" "0"
check "local master caught up"              "$(rev "$CLONE" master)" "$(rev "$UP" master)"
check "fork caught up"                      "$(rev "$FORK" master)" "$(rev "$UP" master)"
saw   "says it fast-forwarded"              "$out" "master fast-forwarded to upstream/master (1 new commit)"
saw   "says it pushed"                      "$out" "pushed to origin/master"

out="$(fs)"
saw   "nothing new: one line"               "$out" "master already up to date with upstream/master, here and on origin"

upstream_commit
git fetch -q upstream && git merge -q --ff-only upstream/master
out="$(fs)"
check "clone current, fork behind: fork caught up" "$(rev "$FORK" master)" "$(rev "$UP" master)"
saw   "clone current, fork behind: says so" "$out" "pushed it to origin, which was behind"

echo "== from another branch =="
git checkout -q -b feat && echo f > feat && git add feat && git commit -qm feat
feat="$(rev "$CLONE" feat)"
upstream_commit; upstream_commit
out="$(fs)"
check "master moved without checking it out" "$(rev "$CLONE" master)" "$(rev "$UP" master)"
check "still on feat"                       "$(git rev-parse --abbrev-ref HEAD)" "feat"
check "feat untouched"                      "$(rev "$CLONE" feat)" "$feat"
check "fork caught up"                      "$(rev "$FORK" master)" "$(rev "$UP" master)"
saw   "counts commits"                      "$out" "(2 new commits)"

echo "== base checked out in another worktree =="
WT="$TMP/wt"; git worktree add -q "$WT" master
upstream_commit
out="$(fs)"
check "worktree's master caught up"         "$(rev "$CLONE" master)" "$(rev "$UP" master)"
check "worktree's files updated too"        "$(cat "$WT/up$n" 2>/dev/null)" "$n"
git worktree remove "$WT"

echo "== commits of your own =="
git checkout -q master
echo mine > mine && git add mine && git commit -qm "mine on master"
mine="$(rev "$CLONE" master)"
upstream_commit
out="$(fs)"; rc=$?
check "local master with own commits: exit 1" "$rc" "1"
check "local master left as is"             "$(rev "$CLONE" master)" "$mine"
saw   "says why"                            "$out" "master has commits upstream/master doesn't"
check "fork still follows upstream"         "$(rev "$FORK" master)" "$(rev "$UP" master)"
git reset -q --hard upstream/master

git -C "$SEED" fetch -q "$FORK" && git -C "$SEED" checkout -q -b forkonly "$(rev "$FORK" master)" \
  && echo x > "$SEED/x" && git -C "$SEED" add x && git -C "$SEED" commit -qm "fork-only" \
  && git -C "$SEED" push -q "$FORK" HEAD:master && git -C "$SEED" checkout -q master
forkonly="$(rev "$FORK" master)"
upstream_commit
out="$(fs)"; rc=$?
check "fork with own commits: exit 1"       "$rc" "1"
check "fork left as is"                     "$(rev "$FORK" master)" "$forkonly"
saw   "says why"                            "$out" "origin refused the push"
check "local master still caught up"        "$(rev "$CLONE" master)" "$(rev "$UP" master)"
git -C "$FORK" fetch -q "$UP" +master:master   # put the fork back on upstream

echo "== uncommitted changes in the way =="
upstream_commit
git fetch -q upstream
echo "mine" > "up$n"   # untracked, where upstream's next commit adds a file
out="$(fs)"; rc=$?
check "blocked fast-forward: exit 1"        "$rc" "1"
saw   "blocked fast-forward: says why"      "$out" "uncommitted changes in the way?"
check "blocked fast-forward: file kept"     "$(cat "up$n")" "mine"
rm "up$n"

echo "== dry run =="
upstream_commit
before_local="$(rev "$CLONE" master)" before_fork="$(rev "$FORK" master)"
out="$(fs -n)"
saw   "dry run: plans the fast-forward"     "$out" "fast-forward master (2 new commits)"
saw   "dry run: plans the push"             "$out" "push to origin/master"
check "dry run: local untouched"            "$(rev "$CLONE" master)" "$before_local"
check "dry run: fork untouched"             "$(rev "$FORK" master)" "$before_fork"

echo "== gw routing, and gw sync stays on origin =="
out="$("$SH" "$ROOT/bin/gowork" fork sync 2>&1)"
check "gw fork sync reaches gp-fork"        "$(rev "$CLONE" master)" "$(rev "$UP" master)"
upstream_commit
git -C "$FORK" fetch -q "$UP" master:master  # the fork moves on, upstream with it
upstream_commit                               # and upstream moves further
"$SH" "$ROOT/bin/gp-sync" >/dev/null 2>&1
check "gw sync pulls from origin, not upstream" "$(rev "$CLONE" master)" "$(rev "$FORK" master)"
nosaw "gw sync left the fork alone"         "$(rev "$FORK" master)" "$(rev "$UP" master)"

echo "== status =="
st()  { "$SH" "$ROOT/bin/gp-fork" status "$@" 2>&1; }
out="$(st)"
saw   "names upstream's tip"                "$out" "Against upstream/master ($(git rev-parse --short upstream/master)):"
saw   "local base behind"                   "$out" "master           1 behind"
saw   "fork's base behind"                  "$out" "origin/master    1 behind"
git checkout -q -b wip && echo w > wip && git add wip && git commit -qm wip && git commit -q --allow-empty -m wip2
git push -q origin wip 2>/dev/null
git checkout -q -b localonly master
git push -q origin "$(rev "$UP" master):refs/heads/merged" 2>/dev/null
git checkout -q master && git branch -q -D localonly 2>/dev/null; git branch -q localonly wip~1
git push -q "$UP" master:shared 2>/dev/null; git branch -q shared master
out="$(st)"
saw   "lists a pushed branch"               "$out" "here and on origin  2 commits upstream/master lacks"
saw   "lists a local-only branch"           "$out" "here only           1 commit upstream/master lacks"
saw   "lists an origin-only branch, merged" "$out" "on origin only      merged into upstream/master"
nosaw "skips branches upstream has"         "$out" "shared "
nosaw "skips the base"                      "${out#*have:}" "$(printf "\n  master ")"
out="$(st -n)"; rc=$?
check "status has no dry run"               "$rc" "2"

echo "== pr =="
# GitHub-style remote URLs, rewritten by git to the local repos, so the slug
# parsing sees what it would for real.
mkdir -p "$TMP/gh/the-org" "$TMP/gh/me"
ln -s "$UP" "$TMP/gh/the-org/proj.git"; ln -s "$FORK" "$TMP/gh/me/proj.git"
git config --global url."$TMP/gh/".insteadOf "https://github.com/"
git remote set-url upstream https://github.com/the-org/proj.git
git remote set-url origin git@github.com-me:me/proj.git
git config --global url."$TMP/gh/".insteadOf "git@github.com-me:" 2>/dev/null
git config --global --add url."$TMP/gh/".insteadOf "git@github.com-me:"
FB="$TMP/fakebin"; mkdir -p "$FB"
cat > "$FB/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in "auth token") exit 1 ;; esac
printf '%s\n' "\$*" >> "$TMP/gh-calls"
echo "https://github.com/the-org/proj/pull/1"
STUB
chmod +x "$FB/gh"
pr() { PATH="$FB:$PATH" "$SH" "$ROOT/bin/gp-fork" pr "$@" 2>&1; }

out="$(pr --fill)"; rc=$?
check "on the base: refuses"                "$rc" "1"
saw   "on the base: says so"                "$out" "open the PR from a feature branch"
git checkout -q -b topic && echo t > topic && git add topic && git commit -qm topic
rm -f "$TMP/gh-calls"
out="$(pr --title "Add topic" --draft)"; rc=$?
check "exit 0"                              "$rc" "0"
check "pushed the branch first"             "$(rev "$FORK" topic)" "$(rev "$CLONE" topic)"
saw   "says it pushed"                      "$out" "pushed topic to origin"
check "aims gh at upstream, from the fork"  "$(cat "$TMP/gh-calls")" "pr create --repo the-org/proj --head me:topic --base master --title Add topic --draft"
rm -f "$TMP/gh-calls"
out="$(pr -B shared --fill)"
check "caller's --base wins, no push needed" "$(cat "$TMP/gh-calls")" "pr create --repo the-org/proj --head me:topic -B shared --fill"
nosaw "no push when origin is current"      "$out" "pushed"
git -C "$SEED" fetch -q "$FORK" topic && git -C "$SEED" checkout -q -b t2 FETCH_HEAD \
  && git -C "$SEED" commit -q --allow-empty -m "someone else" && git -C "$SEED" push -q "$FORK" HEAD:topic \
  && git -C "$SEED" checkout -q master
rm -f "$TMP/gh-calls"
out="$(pr --fill)"; rc=$?
check "origin ahead: refuses"               "$rc" "1"
saw   "origin ahead: says why"              "$out" "pull or rebase first"
check "origin ahead: gh not called"         "$(cat "$TMP/gh-calls" 2>/dev/null)" ""
git checkout -q master

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
