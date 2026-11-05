#!/usr/bin/env bash
# Smoke test: two fake running sessions in a throwaway HOME. Touches nothing outside it.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; BIN="$HERE/bin/hallway.py"
T=$(mktemp -d); PASS=0; FAIL=0
trap 'kill $PA $PB 2>/dev/null; wait $PA $PB 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/.claude/sessions" "$T/work/checkout/.git" "$T/work/payments/.git"
echo "ref: refs/heads/claude/checkout-redesign" > "$T/work/checkout/.git/HEAD"
echo "ref: refs/heads/claude/flaky-payment-test" > "$T/work/payments/.git/HEAD"
sleep 300 & PA=$!; sleep 300 & PB=$!
SA=aaaaaaaa-1111-2222-3333-444444444444; SB=bbbbbbbb-1111-2222-3333-444444444444
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","name":"a"}' $PA $SA "$T/work/checkout" > "$T/.claude/sessions/$PA.json"
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","name":"b"}' $PB $SB "$T/work/payments" > "$T/.claude/sessions/$PB.json"
run(){ env -u CLAUDE_CODE_HOST_SESSION_ID HOME="$T" "$@"; }
C(){ local sid=$1; shift; run CLAUDE_CODE_SESSION_ID=$sid python3 "$BIN" "$@"; }
note(){ python3 -c "import json,sys;print(json.dumps({'session_id':sys.argv[1],'cwd':sys.argv[2],'prompt':sys.argv[3]}))" "$1" "$2" "$3" | run $4 python3 "$BIN" note; }
ok(){ if eval "$2"; then PASS=$((PASS+1)); echo "PASS  $1"; else FAIL=$((FAIL+1)); echo "FAIL  $1"; fi; }

note $SA "$T/work/checkout" "Move the promo code field above the order totals on the checkout page" "env X=1"
START=$(printf '{"session_id":"%s","cwd":"%s"}' $SB "$T/work/payments" | run python3 "$BIN" hook-start)
ok "SessionStart hook lists the other session and what it is doing" 'echo "$START" | grep -q "promo code field"'
ok "shim installed and runs"                  '[ -x "$T/.local/bin/hallway" ] && HOME="$T" "$T/.local/bin/hallway" --help >/dev/null 2>&1'
ok "find locates the session by topic"        'C $SB find promo | grep -q "s-aaaaaaaa"'
ok "send resolves a session by its branch"    'C $SB send checkout -s "Totals API" -m "Does your change touch totals?" | grep -q "^sent "'
ok "the recipient receives the message"       'C $SA inbox --brief | grep -q "Totals API"'
note $SB "$T/work/payments" "Rewrite the retry loop so it backs off exponentially" "env HALLWAY_NO_PROMPTS=1"
ok "HALLWAY_NO_PROMPTS=1 records nothing"     '! C $SA peers | grep "s-bbbbbbbb" | grep -q "asked:"'
ok "status line is shown to others"           'C $SB status "fixing retry backoff" >/dev/null; C $SA peers | grep -q "fixing retry backoff"'
# Built at runtime so no secret-looking literal sits in the repo (GitHub push protection flags those).
FAKE=$(python3 -c "print('Zx' + 'AbCd1234' * 5)")
ok "token-looking strings are redacted"       'note $SA "$T/work/checkout" "use key $FAKE for billing" "env X=1"; C $SB peers | grep s-aaaaaaaa | grep -q "\[redacted\]"'
stop(){ python3 -c "import json,sys;print(json.dumps({'session_id':sys.argv[1],'cwd':sys.argv[2],'last_assistant_message':sys.argv[3]}))" "$1" "$2" "$3" | run $4 python3 "$BIN" stop; }
stop $SA "$T/work/checkout" "Moved the promo field and the tests pass.

Should I open the pull request?" "env X=1"
ok "a reply ending in a question is recorded as waiting" 'C $SB day | grep -A1 "s-aaaaaaaa" | grep -q "waiting.*Should I open the pull request"'
C $SB status "blocked: waiting on the QA deploy" >/dev/null
stop $SB "$T/work/payments" "Still waiting for QA." "env X=1"
ok "a status the session set itself is kept"  'C $SA peers | grep "s-bbbbbbbb" | grep -q "blocked: waiting on the QA deploy"'
stop $SA "$T/work/checkout" "Opened the pull request." "env HALLWAY_NO_TURN_STATUS=1"
ok "HALLWAY_NO_TURN_STATUS=1 records nothing" '! C $SB day --full | grep -q "Opened the pull request"'
PORT=$((20000 + RANDOM % 20000))
run python3 "$BIN" deck --port $PORT >/dev/null 2>&1 & PD=$!
for i in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/deck" && break; sleep .2; done
ok "deck serves the live state"               'curl -s "http://127.0.0.1:$PORT/api/deck" | grep -q "Should I open the pull request"'
ok "deck refuses another Tailscale user"      '[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Tailscale-User-Login: someone@else.com" "http://127.0.0.1:$PORT/api/deck")" = 403 ]'
ok "a reply from the deck is stored"          'curl -s -X POST -H "Content-Type: application/json" -d "{\"handle\":\"s-aaaaaaaa\",\"text\":\"Yes, open it.\"}" "http://127.0.0.1:$PORT/api/reply" | grep -q "\"id\""'
BAD='{"handle":"s-aaaaaaaa","text":"injected"}'
code(){ curl -s -o /dev/null -w "%{http_code}" "$@"; }
ok "a cross-site form post is refused"        '[ "$(code -X POST -H "Content-Type: text/plain" -H "Origin: https://evil.example" -d "$BAD" "http://127.0.0.1:$PORT/api/reply")" = 403 ]'
ok "a rebound host name is refused"           '[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Host: evil.example" "http://127.0.0.1:$PORT/api/deck")" = 403 ]'
kill $PD 2>/dev/null; wait $PD 2>/dev/null
ok "the relay hands the reply to the running session" 'C $SB relay --timeout 5 | grep -q "\[Hallway\] From your user: Yes, open it."'
ok "inbox names a peer sender as a session, not the user" 'C $SA inbox --all | grep -q "from another Claude session"'
# waiting for mail costs nothing and wakes the session only for its user or an urgent peer
waitfor(){ printf '{"session_id":"%s","cwd":"%s"}' $SA "$T/work/checkout" | run python3 "$BIN" wait --timeout $1 > "$T/wait.out" 2>/dev/null; echo $? > "$T/wait.rc"; }
waitfor 6 & W=$!; sleep 1.5
C $SB send s-aaaaaaaa -s "fyi" -m "just so you know" >/dev/null
wait $W
ok "a normal peer message does not wake the session" '[ "$(cat "$T/wait.rc")" = 0 ]'
waitfor 20 & W=$!; sleep 1.5
ok "only one waiter runs per session"        'printf "{\"session_id\":\"%s\",\"cwd\":\"%s\"}" $SA "$T/work/checkout" | run python3 "$BIN" wait --timeout 20 >/dev/null 2>&1'
C $SB --as you send s-aaaaaaaa -s "from the deck" -m "Ship it after lunch." >/dev/null
wait $W
ok "your message wakes it (exit 2) with a clear sender" '[ "$(cat "$T/wait.rc")" = 2 ] && grep -q "\[Hallway\] From your user: Ship it after lunch." "$T/wait.out"'
ok "a usage error exits 1, never the wake-up code 2" 'run python3 "$BIN" nosuchcommand >/dev/null 2>&1; [ $? = 1 ]'
mkdir -p "$T/.local/bin"; printf '#!/bin/sh\nexec python3 "/x/hallway/hallway/9.9.9/bin/hallway.py" "$@"\n' > "$T/.local/bin/hallway"
printf '{"session_id":"%s","cwd":"%s"}' $SB "$T/work/payments" | run python3 "$BIN" hook-start >/dev/null 2>&1
ok "an older copy never repoints a newer shim" 'grep -q "9.9.9" "$T/.local/bin/hallway"'
ok "all data stays inside the test HOME"      '[ -f "$T/.claude/hallway/hallway.db" ]'
echo; echo "$PASS passed, $FAIL failed"; [ $FAIL -eq 0 ]
