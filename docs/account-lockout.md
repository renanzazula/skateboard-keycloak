# Temporary account lockout (brute-force detection)

## What the fixture configures

`realm-export.json` sets, for realm `skateboard-podcast`:

| Field | Value | Why |
|---|---|---|
| `bruteForceProtected` | `true` | already on |
| `permanentLockout` | `false` | temporary lock only |
| `failureFactor` | `5` | lock on the 5th consecutive failure |
| `waitIncrementSeconds` | `900` | 15-minute lock |
| `maxFailureWaitSeconds` | `900` | cap = increment, so the lock is a flat 15 minutes |
| `maxDeltaTimeSeconds` | `900` | failure counter resets when the last failure is >15 min old |
| `quickLoginCheckMilliSeconds` | `0` | disables the separate "quick login" lock so rapid-fire failures can't cause a lock of a different length |
| `minimumQuickLoginWaitSeconds` | `900` | irrelevant while the quick-login check is off; kept at 15 min so it can't differ if re-enabled |

Stock Keycloak behaviour relied on (verified by `tests/lockout-integration-test.sh`,
not just assumed): locks are per user, a successful login resets the counter,
the correct password is rejected during a lock, and login works again after it
expires.

## PRODUCTION IS NOT CHANGED BY THIS FILE

The `Dockerfile` imports with `--import-realm`, whose strategy is
`IGNORE_EXISTING`. An existing realm is left untouched, so editing
`realm-export.json` only affects a **brand-new database**. The live
`skateboard-podcast` realm keeps whatever brute-force settings it has (Keycloak
defaults: ~30 failures, 60s increment, 12h window) until they're applied by
hand. **The ticket is not done in production until this manual step is done and
checked.**

Admin console: Realm settings > Security defenses > Brute force detection ->
Mode "Lockout temporarily", Max login failures 5, Wait increment 15 minutes,
Max wait 15 minutes, Failure reset time 15 minutes, Quick login check
milliseconds 0. Save.

kcadm (against the live Keycloak):

```
kcadm.sh config credentials --server "$KC_HOSTNAME" --realm master --user "$ADMIN" --password "$PW"
kcadm.sh update realms/skateboard-podcast \
  -s bruteForceProtected=true -s permanentLockout=false \
  -s failureFactor=5 -s waitIncrementSeconds=900 \
  -s maxFailureWaitSeconds=900 -s maxDeltaTimeSeconds=900 \
  -s quickLoginCheckMilliSeconds=0 -s minimumQuickLoginWaitSeconds=900
kcadm.sh get realms/skateboard-podcast --fields bruteForceProtected,permanentLockout,failureFactor,waitIncrementSeconds,maxFailureWaitSeconds,maxDeltaTimeSeconds,quickLoginCheckMilliSeconds
```

Record the date/operator here once done: _not yet applied_.

The login theme's `messages_en.properties` is baked into the image, so it takes
effect on deploy (themes are not part of the realm import).

## Keep the two realm exports in sync

This file is duplicated in `skateboard-infrastructure/.docker/keycloak/realm-export.json`.
That copy is outside this repo and **was not changed here**: apply the same
eight fields (the six above plus `bruteForceProtected`) there, otherwise the
local docker-compose realm and this image diverge.

## Lockout message (decision)

- **Hosted login page** (theme `skateboard`): `themes/skateboard/login/messages/messages_en.properties`
  overrides `accountTemporarilyDisabledMessage` with explicit "temporarily locked
  ... try again in 15 minutes" copy. Trade-off: this reveals that the account
  exists and is locked (Keycloak's stock text hides it for user-enumeration
  protection). Accepted by the ticket's requirement for a clear message.
- **In-app login** uses direct grant (ROPC) on `skateboard-mobile` and
  `skateboard-podcast-fe`, so the user sees the FE's own form, not the theme.
  Keycloak's ROPC error for a locked account is an `invalid_grant` error whose
  `error_description` is not a stable, user-facing string and carries no retry
  time. **A follow-up change in skateboard-fe is required** to map that
  response to fixed copy ("Your account is temporarily locked because of too
  many failed login attempts. Try again in 15 minutes.") - this repo can't do
  that. Until then acceptance criterion 4 is met only on the hosted page.
  Run the integration test and read the printed `AC4` response body to see the
  exact error the FE must handle (it may be indistinguishable from a wrong
  password in this Keycloak version; if so the FE cannot tell them apart and an
  Admin API lookup via a backend or a Keycloak extension is needed).
- An exact unlock clock-time is not available without a server-side extension;
  the copy gives a duration (15 minutes) instead.

## Known limits / risks

- **Not a strict sliding window.** `maxDeltaTimeSeconds` resets the counter
  when the *last* failure is older than 15 minutes. Five failures each less
  than 15 minutes apart still lock, even if spread over more than 15 minutes
  in total. The integration test demonstrates this. Needs product sign-off.
- **Lockout denial of service.** Emails are usernames; anyone can lock a known
  account with 5 bad passwords. Accepted side effect of the ticket.
- Admin actions through `skateboard-user-be`/`skateboard-app-config-be`
  (`manage-users`), such as password reset or deactivate/reactivate, may clear
  or interact with the lock state; not covered by the test.
- Dev/prod drift as described above.

## Running the integration test

See the header of `tests/lockout-integration-test.sh` (needs curl and jq, a
local Keycloak on a fresh DB). It is not run by `run_tests` (which only
validates that `realm-export.json` parses).
