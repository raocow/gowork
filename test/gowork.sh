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
