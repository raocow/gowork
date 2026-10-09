#!/usr/bin/env bash
# Tests for the gowork router (bin/gowork, gw) and `gw migrate`, run inside a
# throwaway $HOME. Run: test/gowork.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GW="$ROOT/bin/gw"
pass=0 fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
saw()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" ;; esac; }
nosaw(){ case "$2" in *"$3"*) bad "$1" ;; *) ok "$1" ;; esac; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
# Never run against an empty path: every file below is written under it.
[ -n "$TMP" ] && [ -d "$TMP" ] && [ "$TMP" != / ] || { echo "no temp dir; aborting" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" GIT_CONFIG_GLOBAL="$TMP/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export RIGOR_RC="$TMP/.zshrc"
: > "$TMP/.gitconfig"

# A git that answers `git help <cmd>` for a few real commands and records
# every other call, so passthrough can be checked without running git.
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
REALGIT="$(command -v git)"
cat > "$FAKE/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = help ]; then
  case "\$2" in status|push|pull|log|init|stash) exit 0 ;; esac
  exit 1
fi
case "\$1" in -C|config|rev-parse|describe|init|remote|worktree|commit) exec "$REALGIT" "\$@" ;; esac
echo "git \$*" >> "$TMP/git-calls"
EOF
chmod +x "$FAKE/git"
gw() { PATH="$FAKE:$PATH" "$GW" "$@"; }

echo "== router =="
out="$(gw help)"
saw "help lists the git commands"     "$out" "pr          pull requests"
saw "help lists identity"             "$out" "account setup|status|off"
saw "help lists notify, not push"     "$out" "notify setup|status|test|off"
saw "help names the old aliases"      "$out" "Old names keep working: gp <cmd>, gp-<cmd>, rigor <cmd>."

rm -f "$TMP/git-calls"
gw status --short >/dev/null 2>&1
check "gw status is git status (no longer rigor's)" "$(cat "$TMP/git-calls" 2>/dev/null)" "git status --short"
rm -f "$TMP/git-calls"
gw push origin main >/dev/null 2>&1
check "gw push is git push (notifications moved to notify)" "$(cat "$TMP/git-calls" 2>/dev/null)" "git push origin main"
out="$(gw definitely-not-a-command 2>&1)"; rc=$?
check "unknown command fails" "$rc" "1"
saw "unknown command says so" "$out" "gw: unknown command 'definitely-not-a-command'"

out="$(gw shell status 2>&1)"
saw "gw shell status is rigor's feature status" "$out" "autovenv"
out="$(gw shell 2>&1)"; rc=$?
check "gw shell needs a subcommand" "$rc" "2"
out="$(gw notify 2>&1)"
saw "gw notify routes to push, named as notify" "$out" "gw notify: specify a subcommand"
out="$(gw account 2>&1)"
saw "gw account with no subcommand lists accounts" "$out" "no accounts registered"
out="$(gw account status 2>&1)"
saw "gw account status is identity status" "$out" "not set up — run: gw account setup"
out="$(gw aws 2>&1)"; rc=$?
check "gw aws needs a subcommand" "$rc" "2"
out="$(gw pr -h 2>&1)"
saw "gw pr reaches gp pr" "$out" "pr"
out="$(PATH="$FAKE:$PATH" "$ROOT/bin/gowork" version 2>&1)"
saw "gowork version" "$out" "gowork "
out="$(PATH="$FAKE:$PATH" "$ROOT/bin/gp" help 2>&1)"
saw "old gp name still works" "$out" "gp (gitplus)"
out="$(PATH="$FAKE:$PATH" "$ROOT/bin/rigor" version 2>&1)"
saw "old rigor name still works" "$out" "rigor "

echo "== sleep =="
# A pmset that reports $SLEEP_STATE and a sudo that only records, so no
# password is ever asked for and no setting changes.
cat > "$FAKE/pmset" <<'EOF2'
#!/bin/sh
printf ' SleepDisabled\t\t%s\n' "$SLEEP_STATE"
EOF2
cat > "$FAKE/sudo" <<EOF2
#!/bin/sh
echo "sudo \$*" >> "$TMP/sudo-calls"
EOF2
chmod +x "$FAKE/pmset" "$FAKE/sudo"
for st in 0 1; do
  if [ "$st" = 0 ]; then same=on; change=off; word=enabled; else same=off; change=on; word=disabled; fi
  rm -f "$TMP/sudo-calls"
  out="$(SLEEP_STATE=$st gw sleep "$same" 2>&1)"; rc=$?
  check "sleep $same when already $word fails" "$rc" "1"
  saw   "sleep $same when already $word says so" "$out" "sleep is already $word"
  check "sleep $same when already $word never calls sudo" "$(cat "$TMP/sudo-calls" 2>/dev/null)" ""
  out="$(SLEEP_STATE=$st gw sleep "$change" 2>&1)"; rc=$?
  check "sleep $change from $word succeeds" "$rc" "0"
  check "sleep $change from $word calls sudo pmset" "$(cat "$TMP/sudo-calls" 2>/dev/null)" \
    "sudo pmset -a disablesleep $([ "$change" = off ] && echo 1 || echo 0)"
done
rm -f "$FAKE/pmset" "$FAKE/sudo"

echo "== pr latest =="
# A gh that answers `pr list` from canned JSON, run through the caller's own
# --jq, so the ordering and formatting under test are the real ones. Merged
# and closed PRs come back in creation order, the way gh returns them; #7
# was opened first but merged last, and #10 was closed without merging.
cat > "$FAKE/gh" <<EOF2
#!/usr/bin/env bash
echo "gh \$*" >> "$TMP/gh-calls"
args="\$*"
[ "\$1 \$2" = "pr view" ] && { echo "\$3"; exit 0; }
[ "\$1 \$2" = "pr list" ] || exit 0
jq_expr=""; state=""
while [ \$# -gt 0 ]; do
  case "\$1" in --jq) jq_expr="\$2"; shift ;; --state) state="\$2"; shift ;; esac
  shift
done
if [ "\$state" = closed ]; then
  # -f's checks ask for 50; by then #13 has merged.
  extra=""
  case "\$args" in *"--limit 50"*) extra=',{"number":13,"url":"u/13","title":"thirteen","state":"MERGED","closedAt":"2026-10-08T17:00:00Z","author":{"login":"me"}}' ;; esac
  printf '%s' '[{"number":9,"url":"u/9","title":"nine","state":"MERGED","closedAt":"2026-10-03T20:15:00Z","author":{"login":"me"}},
               {"number":8,"url":"u/8","title":"eight","state":"MERGED","closedAt":"2026-10-02T18:00:00Z","author":{"login":"me"}},
               {"number":10,"url":"u/10","title":"ten","state":"CLOSED","closedAt":"2026-10-01T16:00:00Z","author":{"login":"me"}},
               {"number":7,"url":"u/7","title":"seven","state":"MERGED","closedAt":"2026-10-06T02:30:00Z","author":{"login":"ana"}}'"\$extra]"
else
  printf '%s' '[{"number":12,"url":"u/12","title":"twelve","createdAt":"2026-10-07T16:05:00Z"},
               {"number":11,"url":"u/11","title":"eleven","createdAt":"2026-10-06T23:40:00Z"}]'
fi | jq -r "\$jq_expr"
EOF2
chmod +x "$FAKE/gh"
PRREPO="$TMP/prrepo"; git init -q "$PRREPO"
pl() { (cd "$PRREPO" && TZ=America/Los_Angeles PATH="$FAKE:$PATH" "$GW" "$@" 2>&1); }
out="$(pl pll)"
# #7 merged 02:30 UTC on the 6th, which is the evening of the 5th in
# California: the time shown is local, and so is the day.
check "pll lists merged and closed PRs, oldest first, tagged, in local American time" "$out" "u/10 -- ten [CLOSED] (Oct 1, 2026, 9:00 AM)
u/8 -- eight [MERGED] (Oct 2, 2026, 11:00 AM)
u/9 -- nine [MERGED] (Oct 3, 2026, 1:15 PM)
u/7 -- seven [MERGED] (Oct 5, 2026, 7:30 PM)"
check "GOWORK_TIME_FORMAT=eu shows day first, 24-hour" "$(GOWORK_TIME_FORMAT=eu pl pll -1)" "u/7 -- seven [MERGED] (5 Oct 2026, 19:30)"
git config --global gowork.timeFormat iso
check "gowork.timeFormat=iso shows ISO" "$(pl pll -1)" "u/7 -- seven [MERGED] (2026-10-05 19:30)"
git config --global --unset gowork.timeFormat
out="$(GOWORK_TIME_FORMAT=uk pl pll)"; rc=$?
check "an unknown time format is refused" "$rc" "2"
check "pl latest is the same" "$(pl pl latest)" "$(pl pll)"
check "pll -2 shows the latest two, oldest first" "$(pl pll -2 -nt)" "u/9 [MERGED]
u/7 [MERGED]"
check "pll -x drops a PR before counting" "$(pl pll -2 -nt -x 7)" "u/8 [MERGED]
u/9 [MERGED]"
rm -f "$TMP/gh-calls"; pl pll -30 >/dev/null
saw "pll asks for closed PRs (merged ones included) by update time" "$(cat "$TMP/gh-calls")" "--state closed --search sort:updated-desc --limit 60"
rm -f "$TMP/gh-calls"; out="$(pl pll -e -2)"
check "pll -e shows anyone's, with the author" "$out" "u/9 -- nine [MERGED] (Oct 3, 2026, 1:15 PM, by me)
u/7 -- seven [MERGED] (Oct 5, 2026, 7:30 PM, by ana)"
check "...because it doesn't ask for yours alone" "$(grep -c -- '--author' "$TMP/gh-calls")" "0"
out="$(pl pll -g -e)"; rc=$?
check "pll -g -e is refused" "$rc" "2"
out="$(pl pl -f)"; rc=$?
check "-f goes with latest only" "$rc" "2"
out="$(pl pll -f -c)"; rc=$?
check "pll -f -c is refused" "$rc" "2"
out="$(pl pll -f 10/1..10/5)"; rc=$?
check "pll -f with a window that ends is refused" "$rc" "2"
# -f: the latest, then each PR that closes afterwards, once, though every
# check returns it again. exec, so the signal reaches gp-pr itself.
rm -f "$TMP/gh-calls"
(cd "$PRREPO" && TZ=America/Los_Angeles PATH="$FAKE:$PATH" GOWORK_FOLLOW_INTERVAL=0.2 \
  exec "$GW" pll -f -nt -2 >"$TMP/follow.out" 2>"$TMP/follow.err") & fpid=$!
sleep 2; kill "$fpid" 2>/dev/null; wait "$fpid"; rc=$?
check "pll -f lists the latest, then each PR as it closes, once" "$(cat "$TMP/follow.out")" "u/9 [MERGED]
u/7 [MERGED]
u/13 [MERGED]"
check "pll -f stops cleanly on a signal" "$rc" "0"
saw "pll -f says it's watching" "$(cat "$TMP/follow.err")" "watching for PRs that merge or close"
saw "pll -f asks what closed lately" "$(cat "$TMP/gh-calls")" "--search closed:>="
rm -f "$TMP/gh-calls"; out="$(pl pl -5)"
check "pl lists open PRs with when each was opened, in local time" "$out" "u/11 -- eleven (opened Oct 6, 2026, 4:40 PM)
u/12 -- twelve (opened Oct 7, 2026, 9:05 AM)"
check "pl -nt is bare URLs" "$(pl pl -nt)" "u/11
u/12"
saw "pl -5 limits the open listing" "$(cat "$TMP/gh-calls")" "--state open --limit 5"
# A date argument becomes GitHub's closed: qualifier, in local time with its
# offset, so GitHub does the filtering. With a date there is no default cap.
rm -f "$TMP/gh-calls"; pl pll 2026-10-05 >/dev/null
saw "pll <date> asks GitHub for PRs closed since that local midnight" "$(cat "$TMP/gh-calls")" \
  "--search closed:>=2026-10-05T00:00:00-07:00 sort:updated-desc --limit 1000"
rm -f "$TMP/gh-calls"; pl pll 2026-10-05 14:30 -5 >/dev/null
saw "pll <date> <time>, as two words, is one point; -N still caps" "$(cat "$TMP/gh-calls")" \
  "--search closed:>=2026-10-05T14:30:00-07:00 sort:updated-desc --limit 20"
rm -f "$TMP/gh-calls"; pl pl latest 2026-10-01..2026-10-05 >/dev/null
saw "a window's end date runs to the end of that day" "$(cat "$TMP/gh-calls")" \
  "closed:2026-10-01T00:00:00-07:00..2026-10-05T23:59:59-07:00"
rm -f "$TMP/gh-calls"; pl pll ..2026-12-01T09:00 >/dev/null
saw "..<when> means up to then (standard time in December)" "$(cat "$TMP/gh-calls")" \
  "closed:<=2026-12-01T09:00:00-08:00"
out="$(pl pll 3)"; rc=$?
check "pll takes no ids" "$rc" "2"
saw "...and says what it does take" "$out" "isn't a date or time"
out="$(pl pll 2026-02-31)"; rc=$?
check "pll refuses a date that doesn't exist" "$rc" "2"
rm -f "$TMP/gh-calls"; pl pll 10/5/2026 2:30pm..10/6/26 9am >/dev/null
saw "American dates and 12-hour times" "$(cat "$TMP/gh-calls")" \
  "closed:2026-10-05T14:30:00-07:00..2026-10-06T09:00:00-07:00"
rm -f "$TMP/gh-calls"; GOWORK_TIME_FORMAT=eu pl pll 5/10/2026..6/10/2026 >/dev/null
saw "eu reads a slashed date day first" "$(cat "$TMP/gh-calls")" \
  "closed:2026-10-05T00:00:00-07:00..2026-10-06T23:59:59-07:00"
rm -f "$TMP/gh-calls"; pl pll 12am..12pm >/dev/null
saw "12am is midnight..." "$(cat "$TMP/gh-calls")" "T00:00:00-0"
saw "...and 12pm is noon" "$(cat "$TMP/gh-calls")" "T12:00:00-0"
for bad in 13/5 13pm 0am 9:60 10/5/123; do
  out="$(pl pll "$bad")"; rc=$?
  check "pll refuses '$bad'" "$rc" "2"
done
out="$(pl pm 3 -5)"; rc=$?
check "a count doesn't apply to merge" "$rc" "2"
out="$(pl pll -0)"; rc=$?
check "pll -0 is refused" "$rc" "2"
rm -f "$FAKE/gh"

echo "== migrate =="
# A setup the way rigor and gitplus left it: brew paths and checkout paths.
OLDCO="$TMP/brew-tools"; mkdir -p "$OLDCO/rigor/bin" "$OLDCO/gitplus/bin"
touch "$OLDCO/rigor/bin/rigor" "$OLDCO/gitplus/bin/gp" "$OLDCO/gitplus/bin/gp-pr"
cat > "$TMP/.zshrc" <<'EOF'
fpath=(/usr/share/zsh/site-functions "$HOME/brew-tools/gitplus/share/zsh/site-functions" $fpath)
export PATH="$HOME/.local/bin:$PATH"
[ -r "$HOME/brew-tools/rigor/share/rigor/autovenv.zsh" ] && source "$HOME/brew-tools/rigor/share/rigor/autovenv.zsh"  # rigor:autovenv
source "/opt/homebrew/opt/rigor/share/rigor/pyf.zsh"  # rigor:pyf
[ -r "$HOME/brew-tools/gitplus/share/zsh/ghswitch.zsh" ] && source "$HOME/brew-tools/gitplus/share/zsh/ghswitch.zsh"  # gitplus:ghswitch
alias ll='ls -l'
EOF
ENV_LINE='[ -d "'"$TMP"'/.local/share/rigor/identity/bin" ] && path=("'"$TMP"'/.local/share/rigor/identity/bin" ${path:#'"$TMP"'/.local/share/rigor/identity/bin})  # rigor:identity'
echo "$ENV_LINE" > "$TMP/.zshenv"
mkdir -p "$TMP/.claude" "$TMP/.codex"
cat > "$TMP/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "\"/opt/homebrew/opt/rigor/share/rigor/push/claude-stop\"", "shell": "bash" } ] } ]
  },
  "model": "opus"
}
EOF
printf 'notify = ["/opt/homebrew/Cellar/rigor/0.9.0/share/rigor/push/codex-notify"]\n' > "$TMP/.codex/config.toml"
mkdir -p "$TMP/.local/share/rigor/identity/bin" "$TMP/.local/bin"
ln -s "$OLDCO/rigor/share/rigor/identity/gh" "$TMP/.local/share/rigor/identity/bin/gh"
ln -s "$OLDCO/rigor/bin/rigor" "$TMP/.local/bin/rigor"
ln -s "$OLDCO/gitplus/bin/gp" "$TMP/.local/bin/gp"
ln -s "$OLDCO/gitplus/bin/gp-pr" "$TMP/.local/bin/gp-pr"
ln -s /usr/bin/true "$TMP/.local/bin/unrelated"
snap() { cat "$TMP/.zshrc" "$TMP/.zshenv" "$TMP/.claude/settings.json" "$TMP/.codex/config.toml"; ls -l "$TMP/.local/bin" "$TMP/.local/share/rigor/identity/bin"; }

before="$(snap)"
out="$(gw migrate --dry-run 2>&1)"
check "--dry-run writes nothing" "$(snap)" "$before"
saw "--dry-run shows the changes" "$out" "nothing written"

gw migrate >/dev/null 2>&1
zrc="$(cat "$TMP/.zshrc")"
# Written back in the form it was written in when gowork is under $HOME
# ("$HOME/…"); here the checkout isn't under the throwaway HOME, so absolute.
case "$ROOT" in
  "$HOME"/*) want_av="\"\$HOME${ROOT#$HOME}/share/rigor/autovenv.zsh\"" ;;
  *)         want_av="\"$ROOT/share/rigor/autovenv.zsh\"" ;;
esac
saw   "checkout source line now points at gowork" "$zrc" "$want_av"
nosaw "no rigor checkout path left"               "$zrc" "brew-tools/rigor/"
saw   "brew path rewritten too"                   "$zrc" "source \"$ROOT/share/rigor/pyf.zsh\""
saw   "completion path now gowork's"              "$zrc" "${ROOT#$TMP}/share/zsh/site-functions"
nosaw "ghswitch line dropped"                     "$zrc" "ghswitch"
saw   "unrelated lines untouched"                 "$zrc" "alias ll='ls -l'"
check "identity PATH line untouched" "$(cat "$TMP/.zshenv")" "$ENV_LINE"
saw   "Claude hook now gowork's" "$(cat "$TMP/.claude/settings.json")" "$ROOT/share/rigor/push/claude-stop"
check "settings.json still parses" "$(perl -MJSON::PP -e 'local $/; JSON::PP->new->decode(<STDIN>); print "yes"' < "$TMP/.claude/settings.json" 2>/dev/null)" "yes"
saw   "Codex notify (Cellar path) now gowork's" "$(cat "$TMP/.codex/config.toml")" "$ROOT/share/rigor/push/codex-notify"
check "identity shim relinked" "$(readlink "$TMP/.local/share/rigor/identity/bin/gh")" "$ROOT/share/rigor/identity/gh"
check "checkout link relinked (rigor)" "$(readlink "$TMP/.local/bin/rigor")" "$ROOT/bin/rigor"
check "checkout link relinked (gp-pr)" "$(readlink "$TMP/.local/bin/gp-pr")" "$ROOT/bin/gp-pr"
check "gw link added"     "$(readlink "$TMP/.local/bin/gw")" "$ROOT/bin/gw"
check "gowork link added" "$(readlink "$TMP/.local/bin/gowork")" "$ROOT/bin/gowork"
check "unrelated link untouched" "$(readlink "$TMP/.local/bin/unrelated")" "/usr/bin/true"
[ -f "$TMP/.zshrc.gowork-bak" ] && ok "zshrc backed up" || bad "zshrc backed up"
saw "backup is the original" "$(cat "$TMP/.zshrc.gowork-bak")" "brew-tools/rigor/share/rigor/autovenv.zsh"

out="$(gw migrate 2>&1)"
saw "second run: already migrated" "$out" "already migrated"

# The usual case: gowork itself lives under $HOME, so a "$HOME/…" line must
# come back as "$HOME/…". Run a copy of this checkout from inside the fake home.
mkdir -p "$TMP/co" && cp -R "$ROOT/bin" "$ROOT/libexec" "$ROOT/share" "$TMP/co/"
printf '%s\n' '[ -r "$HOME/brew-tools/rigor/share/rigor/envup.zsh" ] && source "$HOME/brew-tools/rigor/share/rigor/envup.zsh"  # rigor:envup' > "$TMP/.zshrc"
PATH="$FAKE:$PATH" "$TMP/co/bin/gw" migrate >/dev/null 2>&1
check "\$HOME form kept when gowork is under HOME" "$(cat "$TMP/.zshrc")" \
  '[ -r "$HOME/co/share/rigor/envup.zsh" ] && source "$HOME/co/share/rigor/envup.zsh"  # rigor:envup'

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
