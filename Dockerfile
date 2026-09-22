# Production Keycloak image for Railway, with a pre-built optimized server
# configuration for Postgres and the app-branded login theme baked in.
#
# This repo is dedicated to this image (split out of skateboard-infrastructure
# so Railway builds a real git source with the theme files instead of the
# stock quay.io/keycloak/keycloak image, which was silently dropping the
# skateboard login theme: "Failed to find LOGIN theme skateboard, using
# built-in themes").
#
# Build from the repo root:
#   docker build .
#
# Required runtime env (Railway service settings):
#   KC_DB_URL=jdbc:postgresql://<host>:<port>/<db>   (dedicated DB, not the app DB)
#   KC_DB_USERNAME / KC_DB_PASSWORD
#   KC_HOSTNAME=https://<public keycloak url>
#   KC_PROXY_HEADERS=xforwarded
#   KC_HTTP_ENABLED=true                    (TLS terminates at Railway's proxy)
#   KC_BOOTSTRAP_ADMIN_USERNAME / KC_BOOTSTRAP_ADMIN_PASSWORD  (first boot only)
#
# realm-export.json (kept in sync with
# skateboard-infrastructure/.docker/keycloak/realm-export.json) is baked into
# the image and imported automatically on every start via --import-realm.
# Keycloak's importer uses strategy IGNORE_EXISTING: if a realm with this name
# already exists in the target DB it is left untouched (safe against a DB
# that already has the production skateboard-podcast realm and any manual
# drift on it — see skateboard-infrastructure/docs/magazine/review.md §4.1);
# on a brand-new/empty DB it fully creates the realm, clients and roles from
# this file. Configure SMTP for the hosted "Forgot password?" flow and create
# users manually afterward — either in the console or through the app's admin
# user management, which syncs to Keycloak. Secrets in the export
# (client secrets, SMTP password, etc.) are placeholders — set the real ones
# in the admin console after import, they are not read from env vars here.

FROM quay.io/keycloak/keycloak:26.7 AS builder

ENV KC_DB=postgres

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.7

COPY --from=builder /opt/keycloak/ /opt/keycloak/

# App-branded login theme (realm setting: loginTheme=skateboard)
COPY themes/skateboard /opt/keycloak/themes/skateboard

# Realm/clients/roles fixture, auto-imported on start (see note above)
COPY realm-export.json /opt/keycloak/data/import/realm-export.json

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized", "--import-realm"]
