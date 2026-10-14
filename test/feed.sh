#!/usr/bin/env bash
# Tests for `gw feed`'s Slack side (libexec/gowork-feed): channels, routes,
# collect, the review TUI driven through a pipe, posting, and the daily job.
# gh, curl and launchctl are fakes; nothing leaves the machine.
# Run: test/feed.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GW="$ROOT/bin/gw"
pass=0 fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
saw()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in '$2')" ;; esac; }
nosaw(){ case "$2" in *"$3"*) bad "$1" ;; *) ok "$1" ;; esac; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
[ -n "$TMP" ] && [ -d "$TMP" ] && [ "$TMP" != / ] || { echo "no temp dir; aborting" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" GIT_CONFIG_GLOBAL="$TMP/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export GOWORK_FEED_PLIST="$TMP/LaunchAgents/feed.plist" TZ=America/Los_Angeles
git config --global user.name "Test User"
CONF="$TMP/.config/rigor/feed"; STATE="$TMP/.local/share/rigor/feed"

# gh: one account, "me"; search answers from $TMP/merged.json and
# $TMP/unmerged.json, through the caller's own --jq.
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$TMP/gh-calls"
case "\$1 \$2" in
  "auth status") echo "  ✓ Logged in to github.com account me (keyring)"; exit 0 ;;
  "auth token") echo tok; exit 0 ;;
  "search prs") ;;
  *) exit 0 ;;
esac
jq_expr=""; kind=""
for a in "\$@"; do case "\$a" in is:merged) kind=merged ;; is:unmerged) kind=unmerged ;; esac; done
while [ \$# -gt 0 ]; do case "\$1" in --jq) jq_expr="\$2"; shift ;; esac; shift; done
cat "$TMP/\$kind.json" 2>/dev/null | jq -r "\$jq_expr"
EOF
# curl: records each call's URL and body; exits with $TMP/curl-rc (0).
cat > "$FAKE/curl" <<EOF
#!/usr/bin/env bash
n=\$(ls "$TMP/posts" 2>/dev/null | wc -l | tr -d ' ')
mkdir -p "$TMP/posts"
for a in "\$@"; do url="\$a"; done
{ echo "\$url"; cat; } > "$TMP/posts/\$((n + 1))"
exit "\$(cat "$TMP/curl-rc" 2>/dev/null || echo 0)"
EOF
cat > "$FAKE/launchctl" <<EOF
#!/usr/bin/env bash
echo "launchctl \$*" >> "$TMP/launchctl-calls"
EOF
chmod +x "$FAKE"/*
gw() { PATH="$FAKE:$PATH" "$GW" "$@"; }
review() { printf '%s' "$1" | GOWORK_FEED_TTY=any PATH="$FAKE:$PATH" "$GW" feed review 2>&1; }
posts() { cat "$TMP"/posts/* 2>/dev/null; }

pr() { printf '{"number":%s,"url":"https://github.com/%s/pull/%s","title":"%s","closedAt":"%s"}' "$2" "$1" "$2" "$3" "$4"; }
printf '[%s,%s,%s]' \
  "$(pr acme/app 1 'Add login' 2026-10-12T17:00:00Z)" \
  "$(pr acme/lib 2 'Fix <tags> & stuff' 2026-10-12T18:00:00Z)" \
  "$(pr me/private 3 'Dotfiles' 2026-10-12T19:00:00Z)" > "$TMP/merged.json"
printf '[%s]' "$(pr acme/app 4 'Abandoned' 2026-10-12T20:00:00Z)" > "$TMP/unmerged.json"

echo "== channels and routes =="
out="$(echo "https://example.com/hook" | gw feed channel add team 2>&1)"; rc=$?
check "a URL that isn't a Slack webhook is refused" "$rc" "1"
echo "https://hooks.slack.com/services/T0/B0/teamsecret" | gw feed channel add team >/dev/null
echo "https://hooks.slack.com/services/T0/B1/acmesecret" | gw feed channel add '#acme' >/dev/null
check "the webhook file is private" "$(stat -f '%Lp' "$CONF/channels" 2>/dev/null || stat -c '%a' "$CONF/channels")" "600"
out="$(gw feed route acme/app nowhere 2>&1)"; rc=$?
check "routing to an unknown channel is refused" "$rc" "1"
out="$(gw feed route acme 2>&1)"; rc=$?
check "a route needs owner/repo or owner/*" "$rc" "1"
gw feed route 'acme/*' acme >/dev/null
gw feed route acme/app team >/dev/null
out="$(gw feed status)"
saw "status lists channels" "$out" "#team"
nosaw "status never shows a whole webhook URL" "$out" "teamsecret"
saw "status lists routes" "$out" "acme/* -> #acme"
saw "status says the daily collect is off" "$out" "daily collect: off"

echo "== collect =="
out="$(gw feed collect)"
saw "collect queues the routed merges" "$out" "queued 2; 2 waiting"
saw "...and names what has no route" "$out" "not routed, so not queued: me/private"
check "the queue holds #1 for #team and #2 for #acme" \
  "$(cut -f1,3 "$STATE/queue" | tr '\t' ' ' | tr '\n' ';')" \
  "https://github.com/acme/app/pull/1 team;https://github.com/acme/lib/pull/2 acme;"
nosaw "a PR closed without merging is never queued" "$(cat "$STATE/queue")" "pull/4"
saw "collect searches every account for merges since a day ago" "$(cat "$TMP/gh-calls")" "is:merged closed:>="
check "collect records when it ran" "$([ -s "$STATE/last-collect" ] && echo yes)" "yes"
out="$(gw feed collect)"
saw "collecting again queues nothing twice" "$out" "queued 0; 2 waiting"
# A notification when something new was queued, through gw notify's sender.
rm -rf "$TMP/posts"
printf 'NTFY_TOPIC=topic\nNTFY_SERVER=https://ntfy.example\n' > "$TMP/.config/rigor/push.env"
printf '[%s]' "$(pr acme/app 5 'Add logout' 2026-10-12T21:00:00Z)" > "$TMP/merged.json"
gw feed collect --quiet >/dev/null
saw "a new merge notifies the phone" "$(posts)" "https://ntfy.example/topic"
saw "...saying how many are waiting" "$(posts)" "3 updates to review"
rm -rf "$TMP/posts"
gw feed collect --quiet >/dev/null
check "no notification when nothing is new" "$(posts)" ""
rm -f "$TMP/.config/rigor/push.env"

echo "== review =="
out="$(PATH="$FAKE:$PATH" "$GW" feed review </dev/null 2>&1)"; rc=$?
check "review without a terminal is refused" "$rc" "1"
out="$(review q)"
saw "q leaves everything queued" "$out" "left 3 queued"
check "...and the queue is intact" "$(grep -c . "$STATE/queue")" "3"
# Sorted by channel: #acme (#2), then #team (#1, #5). Withhold #1, post.
rm -rf "$TMP/posts"
out="$(review "j py")"
saw "review posts" "$out" "posted to #acme"
saw "...to both channels with something kept" "$out" "posted to #team"
check "one post per channel" "$(ls "$TMP/posts" | wc -l | tr -d ' ')" "2"
p="$(posts)"
saw "the digest opens with your name" "$p" '"text":"*Test User merged:*'
saw "it groups by repo" "$p" '\n*lib*\n'
saw "each PR links to itself" "$p" '<https://github.com/acme/lib/pull/2|#2>'
saw "titles are escaped for Slack" "$p" 'Fix &lt;tags&gt; &amp; stuff'
saw "it goes to that channel's webhook" "$p" "https://hooks.slack.com/services/T0/B1/acmesecret"
nosaw "a withheld PR isn't posted" "$p" "Add login"
saw "a kept PR in the same channel is" "$p" "Add logout"
check "the queue is empty afterwards" "$(grep -c . "$STATE/queue")" "0"
saw "the withheld PR is remembered" "$(cat "$STATE/decided")" "acme/app/pull/1	withheld"
printf '[%s,%s]' "$(pr acme/app 1 'Add login' 2026-10-12T17:00:00Z)" "$(pr acme/app 5 'Add logout' 2026-10-12T21:00:00Z)" > "$TMP/merged.json"
out="$(gw feed collect)"
saw "...so it never comes back, nor does a posted one" "$out" "queued 0; 0 waiting"
out="$(review p)"
saw "an empty queue says so" "$out" "nothing to review"

# Rewording, and a channel whose post fails: its updates stay queued.
printf '[%s]' "$(pr acme/app 6 'wip thing' 2026-10-12T22:00:00Z)" > "$TMP/merged.json"
gw feed collect --quiet >/dev/null
printf '#!/usr/bin/env bash\necho "Faster logins" > "$1"\n' > "$FAKE/fake-editor"; chmod +x "$FAKE/fake-editor"
rm -rf "$TMP/posts"; echo 22 > "$TMP/curl-rc"
out="$(printf 'epy' | EDITOR="$FAKE/fake-editor" GOWORK_FEED_TTY=any PATH="$FAKE:$PATH" "$GW" feed review 2>&1)"; rc=$?
check "a failed post exits 1" "$rc" "1"
saw "...and says the updates stay queued" "$out" "couldn't post to #team"
check "...and they do, reworded" "$(cut -f6 "$STATE/queue")" "Faster logins"
rm -f "$TMP/curl-rc"; rm -rf "$TMP/posts"
review py >/dev/null
saw "the reworded title is what's posted" "$(posts)" "Faster logins"

echo "== daily job =="
out="$(gw feed setup --at 25:00 2>&1)"; rc=$?
check "an impossible time is refused" "$rc" "1"
out="$(gw feed setup --at 9:30)"
saw "setup says when it runs" "$out" "every day at 9:30"
pl="$(cat "$GOWORK_FEED_PLIST")"
saw "the job runs collect" "$pl" "<string>$ROOT/libexec/gowork-feed</string><string>collect</string>"
saw "...at 9:30" "$pl" "<key>Hour</key><integer>9</integer><key>Minute</key><integer>30</integer>"
saw "...with a PATH that finds gh" "$pl" "$FAKE:"
saw "setup loads it into launchd" "$(cat "$TMP/launchctl-calls")" "launchctl bootstrap gui/$(id -u) $GOWORK_FEED_PLIST"
saw "status shows the schedule" "$(gw feed status)" "daily collect: at 09:30"
out="$(gw feed off)"
saw "off stops it" "$out" "stopped the daily collect"
check "...and removes the job" "$([ -f "$GOWORK_FEED_PLIST" ] && echo there || echo gone)" "gone"

echo "== the listing =="
saw "gw feed help covers review" "$(gw feed help)" "gw feed review"
nosaw "pll is gone from gw help" "$(gw help)" "pll"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
