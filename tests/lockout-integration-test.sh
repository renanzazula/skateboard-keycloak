#!/usr/bin/env bash
# Integration test for the temporary account lockout (brute-force detection).
#
# Runs against a LOCAL Keycloak started from this repo's image/fixture, i.e. a
# fresh database so realm-export.json was imported:
#   docker build -t skateboard-keycloak . && docker run --rm -p 8080:8080 \
#     -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
#     skateboard-keycloak start-dev --import-realm
#   (start-dev is fine locally; the image's default CMD needs Postgres.)
#
# Do NOT point this at production: it creates/deletes users and temporarily
# rewrites the realm's brute-force settings (restored on exit).
#
# Requires: bash, curl, jq.
# Env: KC_URL (default http://localhost:8080), KC_ADMIN (admin),
#      KC_ADMIN_PASSWORD (admin), REALM (skateboard-podcast),
#      CLIENT_ID (skateboard-podcast-fe).
#
# Covers the ticket's acceptance criteria:
#   1  fewer than 5 failures -> processed normally, not locked
#   2  5th failure locks the account immediately
#   3  locked account rejects the CORRECT password
#   4  the rejection is observable (error text is printed; the user-facing
#      copy for the hosted page lives in messages_en.properties)
#   5  after the lock elapses the correct password logs in
#   6  successful login resets the failure counter
#   7  failures separated by more than the window do not lock
#   8  a locked account does not affect other users
# Plus the documented approximation: failures each spaced LESS than
# maxDeltaTimeSeconds apart still accumulate to a lock (not a strict sliding
# window).
#
# Step 0 asserts the fixture values (15-minute lock, 5 failures). Expiry and
# window tests then shorten the timings to a few seconds so the suite runs in
# about a minute; the original values are restored on exit.

set -u

KC_URL="${KC_URL:-http://localhost:8080}"
KC_ADMIN="${KC_ADMIN:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"
REALM="${REALM:-skateboard-podcast}"
CLIENT_ID="${CLIENT_ID:-skateboard-podcast-fe}"
PASSWORD='CorrectHorse-123'
RUN_ID="$(date +%s)"
BODY_FILE="$(mktemp)"
CREATED_USER_IDS=()
FAILURES=0
ORIG_WAIT="" ; ORIG_MAXWAIT="" ; ORIG_DELTA=""

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

admin_token() {
  curl -s -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    -d "username=$KC_ADMIN" -d "password=$KC_ADMIN_PASSWORD" | jq -r .access_token
}

# admin_api METHOD PATH [curl args...]
admin_api() {
  local method="$1" path="$2"; shift 2
  curl -s -X "$method" "$KC_URL/admin/realms/$REALM$path" \
    -H "Authorization: Bearer $(admin_token)" "$@"
}

# login USER PASSWORD -> prints HTTP status, body kept in $BODY_FILE
login() {
  curl -s -o "$BODY_FILE" -w '%{http_code}' -X POST \
    "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
    -d grant_type=password -d "client_id=$CLIENT_ID" -d scope=openid \
    --data-urlencode "username=$1" --data-urlencode "password=$2"
}

bad_login()  { login "$1" 'definitely-wrong-password' >/dev/null; }
good_login() { login "$1" "$PASSWORD"; }

create_user() {
  local email="$1" id
  admin_api POST /users -H 'Content-Type: application/json' -d "$(jq -n --arg e "$email" --arg p "$PASSWORD" \
    '{username:$e,email:$e,firstName:"Lockout",lastName:"Test",enabled:true,emailVerified:true,
      credentials:[{type:"password",value:$p,temporary:false}]}')" >/dev/null
  id="$(admin_api GET "/users?username=$email&exact=true" | jq -r '.[0].id')"
  CREATED_USER_IDS+=("$id")
  echo "$id"
}

is_locked() { # USER_ID -> "true"/"false" from the attack-detection endpoint
  admin_api GET "/attack-detection/brute-force/users/$1" | jq -r '.disabled'
}

failures_of() { admin_api GET "/attack-detection/brute-force/users/$1" | jq -r '.numFailures'; }

set_bf() { # WAIT MAXWAIT DELTA (seconds)
  admin_api GET "" | jq --argjson w "$1" --argjson m "$2" --argjson d "$3" \
    '.waitIncrementSeconds=$w | .maxFailureWaitSeconds=$m | .maxDeltaTimeSeconds=$d' \
    | admin_api PUT "" -H 'Content-Type: application/json' -d @- >/dev/null
}

cleanup() {
  [ -n "$ORIG_WAIT" ] && set_bf "$ORIG_WAIT" "$ORIG_MAXWAIT" "$ORIG_DELTA"
  for id in "${CREATED_USER_IDS[@]:-}"; do
    [ -n "$id" ] && admin_api DELETE "/users/$id" >/dev/null
  done
  rm -f "$BODY_FILE"
}
trap cleanup EXIT

echo "== Step 0: fixture settings"
REALM_JSON="$(admin_api GET "")"
[ "$(echo "$REALM_JSON" | jq -r .bruteForceProtected)" = true ]  && pass bruteForceProtected || fail bruteForceProtected
[ "$(echo "$REALM_JSON" | jq -r .permanentLockout)" = false ]    && pass "permanentLockout=false" || fail permanentLockout
[ "$(echo "$REALM_JSON" | jq -r .failureFactor)" = 5 ]           && pass "failureFactor=5" || fail failureFactor
[ "$(echo "$REALM_JSON" | jq -r .waitIncrementSeconds)" = 900 ]  && pass "waitIncrementSeconds=900" || fail waitIncrementSeconds
[ "$(echo "$REALM_JSON" | jq -r .maxFailureWaitSeconds)" = 900 ] && pass "maxFailureWaitSeconds=900" || fail maxFailureWaitSeconds
[ "$(echo "$REALM_JSON" | jq -r .maxDeltaTimeSeconds)" = 900 ]   && pass "maxDeltaTimeSeconds=900" || fail maxDeltaTimeSeconds
ORIG_WAIT="$(echo "$REALM_JSON" | jq -r .waitIncrementSeconds)"
ORIG_MAXWAIT="$(echo "$REALM_JSON" | jq -r .maxFailureWaitSeconds)"
ORIG_DELTA="$(echo "$REALM_JSON" | jq -r .maxDeltaTimeSeconds)"

echo "== Steps 1-3,6,8: 4 failures, success, reset; then 5 failures lock; other user unaffected"
A="lock-a-$RUN_ID@example.com"; B="lock-b-$RUN_ID@example.com"; C="lock-c-$RUN_ID@example.com"
A_ID="$(create_user "$A")"; B_ID="$(create_user "$B")"; C_ID="$(create_user "$C")"

for _ in 1 2 3 4; do bad_login "$A"; done
[ "$(is_locked "$A_ID")" = false ] && pass "AC1: not locked after 4 failures" || fail "AC1: locked after 4 failures"
[ "$(good_login "$A")" = 200 ] && pass "AC1: correct password accepted after 4 failures" || fail "AC1: correct password rejected after 4 failures"
[ "$(failures_of "$A_ID")" = 0 ] && pass "AC6: counter reset to 0 after success" || fail "AC6: counter not reset ($(failures_of "$A_ID"))"
# 4 more failures would total 8 without a reset; still must not lock.
for _ in 1 2 3 4; do bad_login "$A"; done
[ "$(good_login "$A")" = 200 ] && pass "AC6: 4+4 failures split by a success do not lock" || fail "AC6: counter was not reset by success"

for _ in 1 2 3 4 5; do bad_login "$B"; done
[ "$(is_locked "$B_ID")" = true ] && pass "AC2: locked right after 5th failure" || fail "AC2: not locked after 5 failures"
STATUS="$(good_login "$B")"
[ "$STATUS" != 200 ] && pass "AC3: correct password rejected while locked (HTTP $STATUS)" || fail "AC3: correct password accepted while locked"
echo "  INFO AC4: response while locked: $(cat "$BODY_FILE")"
echo "  INFO AC4: the in-app (ROPC) login shows this raw error; FE must map it to lockout copy. Hosted page copy: messages_en.properties."
[ "$(good_login "$C")" = 200 ] && pass "AC8: other user still logs in while B is locked" || fail "AC8: other user affected by B's lock"

echo "== Step 5: lock expires (timings shortened to 5s)"
set_bf 5 5 900
D="lock-d-$RUN_ID@example.com"; D_ID="$(create_user "$D")"
for _ in 1 2 3 4 5; do bad_login "$D"; done
[ "$(good_login "$D")" != 200 ] && pass "AC3: rejected while locked" || fail "AC3: accepted while locked"
sleep 8
[ "$(good_login "$D")" = 200 ] && pass "AC5: correct password works after the lock elapsed" || fail "AC5: still rejected after lock elapsed"

echo "== Step 7: failure window (maxDeltaTimeSeconds shortened to 5s)"
set_bf 900 900 5
E="lock-e-$RUN_ID@example.com"; E_ID="$(create_user "$E")"
for _ in 1 2 3 4; do bad_login "$E"; done
sleep 7
bad_login "$E"
[ "$(is_locked "$E_ID")" = false ] && pass "AC7: 4 failures + 1 failure after the window -> not locked" || fail "AC7: locked despite window elapsing"
[ "$(good_login "$E")" = 200 ] && pass "AC7: correct password accepted" || fail "AC7: correct password rejected"

echo "== Documented approximation: failures each < window apart still accumulate"
F="lock-f-$RUN_ID@example.com"; F_ID="$(create_user "$F")"
for i in 1 2 3 4 5; do bad_login "$F"; [ "$i" -lt 5 ] && sleep 3; done
[ "$(is_locked "$F_ID")" = true ] && pass "5 failures spaced 3s apart (total 12s > 5s window) DO lock: not a strict sliding window (see docs/account-lockout.md)" \
  || fail "expected lock for evenly spaced failures (behaviour changed? update docs)"

echo
if [ "$FAILURES" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$FAILURES CHECK(S) FAILED"; exit 1; fi
