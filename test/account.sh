#!/usr/bin/env bash
# End-to-end test for `gw account`, run entirely inside a throwaway $HOME.
#
# This exists because the account commands write to ~/.ssh/config and
# ~/.gitconfig — the two files where a bad edit hurts most. Everything is
# redirected via HOME plus the GITPLUS_* overrides, so a run can never touch your
# real config. Run: test/account.sh
set -uo pipefail

ACCT="$(cd "$(dirname "$0")/.." && pwd)/bin/gp-account"
pass=0 fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { if grep -qF "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
# Match captured output with a bash pattern instead of piping into `grep -q`:
# grep exits on the first match, upstream gp-account takes SIGPIPE, and `pipefail`
# then reports the whole pipeline as failed even though nothing went wrong.
saw()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" ;; esac; }

# Resolve physically: on macOS mktemp hands back a /var path that is really
# /private/var, and git matches includeIf against real paths (see _acct_abspath).
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export GITPLUS_SSH_CONFIG="$TMP/.ssh/config"
export GITPLUS_GITCONFIG="$TMP/.gitconfig"
export GITPLUS_SSH_KEY_DIR="$TMP/.ssh"
export GITPLUS_RC="$TMP/.zshrc"
# Keep the test's own git calls from reading the developer's real config.
export GIT_CONFIG_GLOBAL="$TMP/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1

echo "== add =="
mkdir -p "$TMP/code/work"
"$ACCT" add work --email me@work.com --dir "$TMP/code/work" >/dev/null 2>&1
[ -f "$TMP/.ssh/id_ed25519_work" ]     && ok "private key created"  || bad "private key created"
[ -f "$TMP/.ssh/id_ed25519_work.pub" ] && ok "public key created"   || bad "public key created"
has "ssh host alias written"  "Host github.com-work"  "$GITPLUS_SSH_CONFIG"
has "IdentitiesOnly set"      "IdentitiesOnly yes"    "$GITPLUS_SSH_CONFIG"
has "ssh sentinel written"    "# gitplus:account:work BEGIN" "$GITPLUS_SSH_CONFIG"
has "identity file written"   "me@work.com"           "$TMP/.gitconfig-work"
has "includeIf written"       "gitdir:$TMP/code/work/" "$GITPLUS_GITCONFIG"
check "ssh config perms" "$(stat -f '%Lp' "$GITPLUS_SSH_CONFIG" 2>/dev/null || stat -c '%a' "$GITPLUS_SSH_CONFIG")" "600"

echo "== idempotence =="
before="$(cat "$GITPLUS_SSH_CONFIG")"
"$ACCT" add work --email me@work.com >/dev/null 2>&1
check "re-add does not duplicate ssh block" "$(cat "$GITPLUS_SSH_CONFIG")" "$before"
check "one sentinel only" "$(grep -c '# gitplus:account:work BEGIN' "$GITPLUS_SSH_CONFIG")" "1"

echo "== identity actually applies =="
git init -q "$TMP/code/work/repo" 2>/dev/null
check "git resolves the bound identity" \
  "$(git -C "$TMP/code/work/repo" config user.email)" "me@work.com"

echo "== list / key =="
out="$("$ACCT" list)"
saw "list shows account"     "$out" "work"
saw "list shows bound dir"   "$out" "code/work"
saw "key prints pubkey"      "$("$ACCT" key work)" "ssh-ed25519"

echo "== check: healthy =="
if "$ACCT" check >/dev/null 2>&1; then ok "check passes when healthy"
else bad "check passes when healthy"; fi
saw "check verifies end-to-end" "$("$ACCT" check 2>&1)" "verified"

echo "== check: catches the rename =="
# The whole reason this feature exists: move the bound directory and the
# includeIf silently stops applying. check must notice.
mv "$TMP/code/work" "$TMP/code/work-renamed"
if "$ACCT" check >/dev/null 2>&1; then bad "check fails after rename"
else ok "check fails after rename"; fi
saw "check reports BROKEN" "$("$ACCT" check 2>&1)" "BROKEN"

echo "== second account coexists =="
"$ACCT" add personal --email me@home.com >/dev/null 2>&1
out="$("$ACCT" list)"
saw "work still listed"     "$out" "work"
saw "personal now listed"   "$out" "personal"

echo "== validation =="
"$ACCT" add "bad name" --email x@y.com >/dev/null 2>&1 \
  && bad "rejects invalid name" || ok "rejects invalid name"
"$ACCT" add nomail >/dev/null 2>&1 \
  && bad "requires --email" || ok "requires --email"
"$ACCT" bind ghost /tmp >/dev/null 2>&1 \
  && bad "bind rejects unknown account" || ok "bind rejects unknown account"

echo "== --gh-user =="
"$ACCT" add work --email me@work.com --gh-user work-gh >/dev/null 2>&1
has "gh user recorded"  "# gitplus:ghuser:work work-gh"  "$GITPLUS_SSH_CONFIG"
out="$("$ACCT" list)"
saw "list shows gh user" "$out" "gh: work-gh"

before="$(cat "$GITPLUS_SSH_CONFIG")"
"$ACCT" add work --email me@work.com --gh-user work-gh >/dev/null 2>&1
check "re-add same gh-user does not duplicate" "$(cat "$GITPLUS_SSH_CONFIG")" "$before"

out="$("$ACCT" add work --email me@work.com --gh-user someone-else 2>&1)"
saw "conflicting gh-user warns instead of overwriting" "$out" "already set to 'work-gh'"
check "conflicting gh-user left the original in place" "$(cat "$GITPLUS_SSH_CONFIG")" "$before"

echo "== acct_gh_for_dir (internal resolver, used by the ghswitch feature) =="
# Fresh account + directory, dedicated to these tests — 'work' is bound to
# $TMP/code/work, which the earlier rename-detection section already moved
# away from, so reusing it here would test a path that was never bound.
mkdir -p "$TMP/code/outer/sub"
"$ACCT" add outer --email outer@work.com --gh-user outer-gh \
  --dir "$TMP/code/outer" >/dev/null 2>&1
check "resolves the bound dir itself" \
  "$("$ACCT" _gh-for-dir "$TMP/code/outer")" "outer-gh"
check "resolves a subdirectory of the bound dir" \
  "$("$ACCT" _gh-for-dir "$TMP/code/outer/sub")" "outer-gh"
check "unrelated directory resolves to nothing" \
  "$("$ACCT" _gh-for-dir "$TMP")" ""

mkdir -p "$TMP/code/outer/nested"
"$ACCT" add nested --email nested@work.com --gh-user nested-gh \
  --dir "$TMP/code/outer/nested" >/dev/null 2>&1
check "nested binding is more specific and wins" \
  "$("$ACCT" _gh-for-dir "$TMP/code/outer/nested")" "nested-gh"
check "outside the nested binding still resolves to the outer one" \
  "$("$ACCT" _gh-for-dir "$TMP/code/outer/sub")" "outer-gh"

echo "== check: gh user verification =="
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"

# No gh on PATH: check should say so, not blow up or silently pass. Use bare
# system dirs (real core utils gp-account itself needs — grep/sed/git — but gh is
# always Homebrew-installed, never bundled there) rather than an empty PATH,
# which would also break gp-account's own use of those utilities.
out="$(PATH="/usr/bin:/bin" "$ACCT" check 2>&1)"
saw "no gh installed is reported, not silent" "$out" "can't verify (gh CLI not installed)"

# Fake gh reporting the account as logged in.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = auth ] && [ "$2" = status ]; then
  echo "  ✓ Logged in to github.com account work-gh (keyring)"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKEBIN/gh"
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" check 2>&1)"
saw "logged-in gh user passes check" "$out" "gh user  : ok (work-gh logged in)"

# Fake gh reporting a DIFFERENT set of logged-in accounts.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = auth ] && [ "$2" = status ]; then
  echo "  ✓ Logged in to github.com account someone-unrelated (keyring)"
  exit 0
fi
exit 1
EOF
if PATH="$FAKEBIN:$PATH" "$ACCT" check >/dev/null 2>&1; then
  bad "not-logged-in gh user fails check"
else
  ok "not-logged-in gh user fails check"
fi
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" check 2>&1)"
saw "check reports NOT LOGGED IN" "$out" "NOT LOGGED IN as work-gh"

echo "== bind never touches gh's global active account =="
# gh's active account is machine-wide: writing it from here would yank the
# identity out from under every other terminal/agent session. Applying a new
# binding to the current shell is ghswitch's job, per-shell via GH_TOKEN.
SWITCHED_TO="$TMP/switched-to"
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = auth ] && [ "\$2" = switch ]; then
  echo "\$4" > "$SWITCHED_TO"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKEBIN/gh"

mkdir -p "$TMP/code/instant"
rm -f "$SWITCHED_TO"
out="$(cd "$TMP/code/instant" && PATH="$FAKEBIN:$PATH" "$ACCT" bind work "$TMP/code/instant" 2>&1)"
saw "bind still reports the binding" "$out" "bound:"
check "bind does NOT switch the global account, even from inside the dir" \
  "$(cat "$SWITCHED_TO" 2>/dev/null)" ""

mkdir -p "$TMP/code/elsewhere" "$TMP/code/nothere"
rm -f "$SWITCHED_TO"
(cd "$TMP/code/nothere" && PATH="$FAKEBIN:$PATH" "$ACCT" bind work "$TMP/code/elsewhere" >/dev/null 2>&1)
check "no global switch when binding another dir either" "$(cat "$SWITCHED_TO" 2>/dev/null)" ""

echo "== _access-for-dir (which account can actually push here) =="
# A real git repo with a real origin, so the remote parsing is exercised for
# real rather than mocked. Only `gh` itself is faked.
mkdir -p "$TMP/code/probe"
git init -q "$TMP/code/probe"
git -C "$TMP/code/probe" remote add origin https://github.com/acme/widget.git

# work-gh has WRITE, outer-gh only READ. READ must NOT count: on any public
# repo every logged-in account gets READ, so counting it would make every
# public repo look like a match for the wrong account.
mk_gh() {  # mk_gh <perm-for-work-gh> <perm-for-outer-gh>
  cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = auth ] && [ "\$2" = token ]; then
  echo "tok-\$4"; exit 0
fi
if [ "\$1" = repo ] && [ "\$2" = view ]; then
  case "\$GH_TOKEN" in
    tok-work-gh)  echo "$1"; exit 0 ;;
    tok-outer-gh) echo "$2"; exit 0 ;;
  esac
  exit 1
fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
}

mk_gh WRITE READ
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/probe" 2>&1)"
check "push access -> account returned" "$out" "work"

mk_gh READ READ
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/probe" 2>&1)"
check "read-only everywhere -> no match (public-repo guard)" "$out" ""

mk_gh ADMIN WRITE
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/probe" 2>&1)"
check "two with push access -> both listed" "$(printf '%s\n' "$out" | grep -c .)" "2"
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/probe" first 2>&1)"
check "'first' short-circuits to one" "$(printf '%s\n' "$out" | grep -c .)" "1"

# Non-GitHub and non-repo directories must not probe at all.
mk_gh ADMIN ADMIN
git init -q "$TMP/code/gitlab"
git -C "$TMP/code/gitlab" remote add origin https://gitlab.com/acme/widget.git
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/gitlab" 2>&1)"
check "non-GitHub remote -> no match" "$out" ""
mkdir -p "$TMP/code/plaindir"
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/plaindir" 2>&1)"
check "not a git repo -> no match" "$out" ""

# gw account's own ssh alias form is still github.com and must be understood.
git init -q "$TMP/code/aliasremote"
git -C "$TMP/code/aliasremote" remote add origin git@github.com-work:acme/widget.git
mk_gh WRITE READ
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/aliasremote" 2>&1)"
check "github.com-<account> ssh alias understood" "$out" "work"

echo "== legacy devrig: sentinels are still read =="
# This command used to be `devrig account`, and it wrote its markers with a
# `devrig:` prefix. Those lines are in people's live ~/.ssh/config and
# ~/.gitconfig right now, so failing to read them would make every existing
# account and binding silently vanish — the one way this move could quietly
# destroy a working setup. Writes use `gitplus:`; both must resolve.
LEGACY="$TMP/legacy"; mkdir -p "$LEGACY/.ssh" "$LEGACY/code/old"
cat > "$LEGACY/.ssh/config" <<EOF
# devrig:account:legacy BEGIN
Host github.com-legacy
  HostName github.com
  User git
  IdentityFile $LEGACY/.ssh/id_ed25519_legacy
# devrig:account:legacy END
# devrig:ghuser:legacy legacy-gh
EOF
cat > "$LEGACY/.gitconfig" <<EOF
# devrig:bind:legacy BEGIN $LEGACY/code/old
[includeIf "gitdir:$LEGACY/code/old/"]
	path = $LEGACY/.gitconfig-legacy
# devrig:bind:legacy END $LEGACY/code/old
EOF
printf '[user]\n\temail = legacy@old.com\n\tname = legacy\n' > "$LEGACY/.gitconfig-legacy"
lg() { GITPLUS_SSH_CONFIG="$LEGACY/.ssh/config" GITPLUS_GITCONFIG="$LEGACY/.gitconfig" \
       GITPLUS_SSH_KEY_DIR="$LEGACY/.ssh" "$ACCT" "$@"; }
saw "legacy account is listed"        "$(lg list)" "legacy"
saw "legacy binding is listed"        "$(lg list)" "$LEGACY/code/old"
saw "legacy gh-user is read"          "$(lg list)" "legacy-gh"
check "legacy binding resolves for a dir" "$(lg _gh-for-dir "$LEGACY/code/old")" "legacy-gh"
# ...and re-adding must not duplicate a block written under the old prefix.
before="$(cat "$LEGACY/.ssh/config")"
lg add legacy --email legacy@old.com >/dev/null 2>&1
check "re-add doesn't duplicate a legacy block" "$(cat "$LEGACY/.ssh/config")" "$before"

echo "== register: get the key onto GitHub, then route over ssh =="
# GitHub is faked at both ends: ssh answers from a state file, and gh records
# what it was asked to do. An "accepted" file is what the fake ssh reports
# success from; the fake key upload creates it, the way a real one would.
ST="$TMP/ghstate"; mkdir -p "$ST"
# Acceptance is per key (per ssh alias); a bare "accepted" file overrides
# every alias, for the wrong-account case.
cat > "$FAKEBIN/ssh" <<EOF
#!/usr/bin/env bash
host="\${@: -1}"; host="\${host#git@}"
for f in "$ST/accepted-\$host" "$ST/accepted"; do
  if [ -f "\$f" ]; then
    echo "Hi \$(cat "\$f")! You've successfully authenticated, but GitHub does not provide shell access."
    exit 1
  fi
done
echo "git@github.com: Permission denied (publickey)."
exit 255
EOF
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
user=""; prev=""
for a in "\$@"; do [ "\$prev" = --user ] && user="\$a"; prev="\$a"; done
case "\$1 \$2" in
  "auth token")  echo "tok-\$user"; exit 0 ;;
  "auth status")
    if [ "\$3" = --active ]; then echo "  - account \$(cat "$ST/active")"; exit 0; fi
    echo "  ✓ Logged in to github.com account sshy-gh (keyring)"; exit 0 ;;
  "auth switch") echo "switch \$user" >> "$ST/log"; echo "\$user" > "$ST/active"; exit 0 ;;
  "auth refresh")
    echo "refresh as \$(cat "$ST/active")" >> "$ST/log"
    [ -f "$ST/refresh-fail" ] && exit 1
    echo "repo, write:public_key" > "$ST/scopes"; exit 0 ;;
  "api -i")      echo "X-Oauth-Scopes: \$(cat "$ST/scopes" 2>/dev/null)"; echo; echo '{}'; exit 0 ;;
  "api -X")
    if [ -f "$ST/post-fail" ]; then cat "$ST/post-fail" >&2; exit 1; fi
    # The uploaded key becomes accepted for the account whose token sent it
    # (test accounts are named <acct> with gh user <acct>-gh).
    u="\${GH_TOKEN#tok-}"
    echo "post \$GH_TOKEN" >> "$ST/log"; echo "\$u" > "$ST/accepted-github.com-\${u%-gh}"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$FAKEBIN/ssh" "$FAKEBIN/gh"
export GITPLUS_SSH="$FAKEBIN/ssh"
reset_gh() { rm -f "$ST"/*; echo other-gh > "$ST/active"; }
pg() { PATH="$FAKEBIN:$PATH" "$ACCT" "$@"; }

mkdir -p "$TMP/code/sshy"
"$ACCT" add sshy --email s@sshy.com --gh-user sshy-gh --dir "$TMP/code/sshy" >/dev/null 2>&1
git init -q "$TMP/code/sshy/repo"
git -C "$TMP/code/sshy/repo" remote add origin https://github.com/acme/widget.git
check "add with no terminal doesn't route yet" \
  "$(git -C "$TMP/code/sshy/repo" remote get-url origin)" "https://github.com/acme/widget.git"

# Refused, token can't add keys, no terminal: say what to run, change nothing.
reset_gh; echo "repo" > "$ST/scopes"
out="$(pg register sshy 2>&1)"; rc=$?
check "refused + no scope + no tty fails" "$rc" "1"
saw "says to run it in a terminal" "$out" "Run in a terminal: gw account register sshy"
check "no switch, refresh or upload without a terminal" "$(cat "$ST/log" 2>/dev/null)" ""
check "remote not rewritten while the key is refused" \
  "$(git -C "$TMP/code/sshy/repo" remote get-url origin)" "https://github.com/acme/widget.git"

# check reports the refused key and fails.
out="$(pg check 2>&1)"; rc=$?
saw "check reports a refused key" "$out" "ssh key  : NOT ACCEPTED by GitHub (fix: gw account check --fix)"
check "check fails on a refused key" "$rc" "1"

# Refused, token already has the scope: upload with THAT account's token, verify, route.
reset_gh; echo "repo, write:public_key" > "$ST/scopes"
out="$(pg register sshy 2>&1)"; rc=$?
check "register with scope succeeds" "$rc" "0"
saw "uploads with the account's own token" "$(cat "$ST/log")" "post tok-sshy-gh"
saw "verifies after upload" "$out" "verified — GitHub accepts it as sshy-gh"
check "https remote now goes over the alias" \
  "$(git -C "$TMP/code/sshy/repo" remote get-url origin)" "git@github.com-sshy:acme/widget.git"
git -C "$TMP/code/sshy/repo" remote set-url origin git@github.com:acme/widget.git
check "scp-style github.com remote goes over the alias too" \
  "$(git -C "$TMP/code/sshy/repo" remote get-url origin)" "git@github.com-sshy:acme/widget.git"
check "rewrite only applies inside bound dirs" \
  "$(git -C "$TMP/code/probe" remote get-url origin)" "https://github.com/acme/widget.git"
check "never switched gh's global account" "$(grep -c switch "$ST/log")" "0"

# Re-running on a working key only verifies — no second upload, no duplicate rewrite.
before="$(cat "$TMP/.gitconfig-sshy")"
out="$(pg register sshy 2>&1)"
saw "re-register just verifies" "$out" "ssh key  : ok"
check "no second upload" "$(grep -c post "$ST/log")" "1"
check "rewrite not duplicated" "$(cat "$TMP/.gitconfig-sshy")" "$before"
out="$(pg check 2>&1)"
saw "check shows routing on" "$out" "routing  : https -> ssh"

# Key accepted as somebody else: refuse to route.
reset_gh; echo someone-else > "$ST/accepted"
out="$(pg register sshy 2>&1)"; rc=$?
check "wrong account fails" "$rc" "1"
saw "wrong account named" "$out" "accepts it as 'someone-else', not 'sshy-gh'"

# GitHub refuses the upload (key already on another account).
reset_gh; echo "repo, write:public_key" > "$ST/scopes"
echo '{"message":"key is already in use"}' > "$ST/post-fail"
out="$(pg register sshy 2>&1)"; rc=$?
check "upload refusal fails" "$rc" "1"
saw "explains key already in use" "$out" "GitHub has this key on a different account already"

echo "== register: the one-time browser approval =="
# Needs a terminal; script(1) provides one. gh can only refresh the ACTIVE
# account, so register switches to it and must always switch back.
if script -q /dev/null true </dev/null >/dev/null 2>&1; then
  inpty() { script -q /dev/null env PATH="$FAKEBIN:$PATH" "$@" </dev/null; }
  reset_gh; echo "repo" > "$ST/scopes"
  out="$(inpty "$ACCT" register sshy 2>&1)"
  check "switch -> refresh as the account -> switch back -> upload" \
    "$(tr '\n' '|' < "$ST/log")" "switch sshy-gh|refresh as sshy-gh|switch other-gh|post tok-sshy-gh|"
  check "active account restored" "$(cat "$ST/active")" "other-gh"
  saw "tells the user what the browser is for" "$out" "A browser window will open"

  reset_gh; echo "repo" > "$ST/scopes"; touch "$ST/refresh-fail"
  out="$(inpty "$ACCT" register sshy 2>&1)"
  check "failed approval still switches back, uploads nothing" \
    "$(tr '\n' '|' < "$ST/log")" "switch sshy-gh|refresh as sshy-gh|switch other-gh|"
  check "active account restored after failure" "$(cat "$ST/active")" "other-gh"

  # Through check --fix too: its loops read from stdin, which must not hide
  # the terminal from register.
  reset_gh; echo "repo" > "$ST/scopes"
  inpty "$ACCT" check --fix >/dev/null 2>&1
  # The fake's scopes are shared, so only the first account (work) needs the
  # approval; what matters is that it got one, and switched back.
  saw "check --fix gets the browser approval to the terminal" \
    "$(tr '\n' '|' < "$ST/log" 2>/dev/null)" "switch work-gh|refresh as work-gh|switch other-gh|post tok-work-gh|"

  reset_gh; echo "repo" > "$ST/scopes"; echo sshy-gh > "$ST/active"
  inpty "$ACCT" register sshy >/dev/null 2>&1
  check "already-active account: no switching at all" \
    "$(tr '\n' '|' < "$ST/log")" "refresh as sshy-gh|post tok-sshy-gh|"
else
  echo "  skip (no script(1) pty available)"
fi
unset GITPLUS_SSH

echo "== worktrees resolve through their main repository =="
# A linked worktree can live outside every bound directory; gh must follow the
# repo it belongs to, the way git's includeIf already does.
git -C "$TMP/code/sshy/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$TMP/elsewhere"
git -C "$TMP/code/sshy/repo" worktree add -q "$TMP/elsewhere/wt" 2>/dev/null
check "worktree outside the bound dir gets the repo's gh user" \
  "$("$ACCT" _gh-for-dir "$TMP/elsewhere/wt")" "sshy-gh"
check "git agrees (identity via includeIf)" \
  "$(git -C "$TMP/elsewhere/wt" config user.email)" "s@sshy.com"
check "a plain dir outside every binding still resolves to nothing" \
  "$("$ACCT" _gh-for-dir "$TMP/elsewhere")" ""

echo "== unbind =="
"$ACCT" bind sshy "$TMP/code/keep" >/dev/null 2>&1
"$ACCT" bind sshy "$TMP/code/drop" >/dev/null 2>&1
"$ACCT" bind sshy "$TMP/code/ghost1" >/dev/null 2>&1
"$ACCT" bind work "$TMP/code/ghost2" >/dev/null 2>&1
mkdir -p "$TMP/code/keep" "$TMP/code/drop"
blanks_before="$(grep -c '^$' "$GITPLUS_GITCONFIG")"

out="$("$ACCT" unbind sshy "$TMP/code/drop" 2>&1)"
saw "unbind reports it" "$out" "unbound:"
binds="$("$ACCT" list)"
case "$binds" in *"$TMP/code/drop"*) bad "binding removed" ;; *) ok "binding removed" ;; esac
saw "neighbouring binding kept" "$binds" "$TMP/code/keep"
check "git config still parses" "$(git config --file "$GITPLUS_GITCONFIG" --list >/dev/null 2>&1 && echo yes)" "yes"
check "its blank separator went with it" "$(grep -c '^$' "$GITPLUS_GITCONFIG")" "$((blanks_before - 1))"
[ -f "$GITPLUS_GITCONFIG.gitplus-bak" ] && ok "backup kept" || bad "backup kept"

out="$("$ACCT" unbind sshy "$TMP/code/never-bound" 2>&1)"; rc=$?
check "unbinding something not bound fails" "$rc" "1"

out="$("$ACCT" unbind --missing 2>&1)"
saw "--missing drops a missing dir" "$out" "/code/ghost1 (was sshy)"
saw "--missing covers every account" "$out" "/code/ghost2 (was work)"
binds="$("$ACCT" list)"
case "$binds" in *ghost*) bad "no missing bindings left" ;; *) ok "no missing bindings left" ;; esac
saw "existing dirs survive --missing" "$binds" "$TMP/code/keep"
saw "second --missing is a no-op" "$("$ACCT" unbind --missing 2>&1)" "no bindings point at missing directories"
check_bound() { "$ACCT" list | grep -qF "    $(echo "$1" | sed "s|^$HOME|~|")"; }

echo "== sweep: trace dead bindings before touching them =="
export GITPLUS_SEARCH_ROOTS="$TMP/code"
"$ACCT" unbind --missing >/dev/null 2>&1   # start from no dead bindings

# a) moved, new place unbound -> rebind (traced by the origin bind recorded)
mkdir -p "$TMP/code/old/proj"; git init -q "$TMP/code/old/proj"
git -C "$TMP/code/old/proj" remote add origin https://github.com/acme/moved.git
"$ACCT" bind sshy "$TMP/code/old/proj" >/dev/null 2>&1
has "bind records the origin" "# gitplus:origin acme/moved" "$GITPLUS_GITCONFIG"
mkdir -p "$TMP/code/new"; mv "$TMP/code/old/proj" "$TMP/code/new/renamed"
# b) gone, but a repo by that name is bound to the same account -> drop
"$ACCT" bind sshy "$TMP/code/wt-gone/repo" >/dev/null 2>&1
# c) gone, its repo is bound to a different account -> keep, ask
mkdir -p "$TMP/code/workside/thing"; git init -q "$TMP/code/workside/thing"
"$ACCT" bind work "$TMP/code/workside/thing" >/dev/null 2>&1
"$ACCT" bind sshy "$TMP/gone/thing" >/dev/null 2>&1
# d) no trace at all -> drop
"$ACCT" bind sshy "$TMP/code/nothing-like-this" >/dev/null 2>&1

before="$(cat "$GITPLUS_GITCONFIG")"
out="$("$ACCT" sweep 2>&1)"
saw "moved repo found by origin"       "$out" "a repo matching by origin acme/moved is at"
saw "moved repo planned for rebind"    "$out" "plan: rebind it there"
saw "worktree-style repo already bound" "$out" "already bound to sshy"
saw "other account's repo is a question" "$out" "bound to work, not sshy"
saw "no trace -> drop"                 "$out" "no repo matching by name 'nothing-like-this' was found"
saw "no terminal: says how to apply"   "$out" "gw account sweep --yes"
check "no terminal: nothing changed"   "$(cat "$GITPLUS_GITCONFIG")" "$before"

if command -v expect >/dev/null 2>&1; then
  # Interactive, answering each prompt as it appears (piping answers in
  # ahead of the prompts through script(1) misaligns them).
  sweep_answer() {  # sweep_answer <moved-answer> <conflict-answer> <apply-answer>
    expect -c "
      set timeout 10
      spawn $ACCT sweep
      expect {(r) } { send \"$1\r\" }
      expect {? (k) } { send \"$2\r\" }
      expect {\[Y/n\] } { send \"$3\r\" }
      expect eof
    " >/dev/null 2>&1
  }
  sweep_answer d k n
  check "declining at the end changes nothing" "$(cat "$GITPLUS_GITCONFIG")" "$before"
  sweep_answer d k y
  binds="$("$ACCT" list)"
  case "$binds" in *"/code/new/renamed"*) bad "answering d drops instead of rebinding" ;; *) ok "answering d drops instead of rebinding" ;; esac
  case "$binds" in *"/code/old/proj"*) bad "old moved binding removed" ;; *) ok "old moved binding removed" ;; esac
  saw "answering k keeps the other account's question" "$binds" "/gone/thing"
  cp "$GITPLUS_GITCONFIG.gitplus-bak" "$GITPLUS_GITCONFIG"   # back to the scenario for --yes
else
  echo "  skip interactive sweep (no expect)"
fi

out="$("$ACCT" sweep --yes 2>&1)"
binds="$("$ACCT" list)"
saw "--yes rebinds the moved repo"      "$binds" "/code/new/renamed"
case "$binds" in *"/code/old/proj"*)   bad "--yes drops the old moved path" ;; *) ok "--yes drops the old moved path" ;; esac
case "$binds" in *"/wt-gone/repo"*)     bad "--yes drops the covered one" ;; *) ok "--yes drops the covered one" ;; esac
case "$binds" in *"nothing-like-this"*) bad "--yes drops the untraceable one" ;; *) ok "--yes drops the untraceable one" ;; esac
saw "--yes keeps the conflict for you"  "$binds" "/gone/thing"
check "git config still parses" "$(git config --file "$GITPLUS_GITCONFIG" --list >/dev/null 2>&1 && echo yes)" "yes"
saw "check points broken bindings at sweep" "$("$ACCT" check 2>&1)" "sweep dead ones with: gw account sweep"
unset GITPLUS_SEARCH_ROOTS
check "identity still applies after unbinding" \
  "$(git -C "$TMP/code/sshy/repo" config user.email)" "s@sshy.com"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
