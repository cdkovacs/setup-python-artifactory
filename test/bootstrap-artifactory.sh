#!/usr/bin/env bash
# Bootstrap a freshly-started Artifactory OSS instance:
#   1. Wait for the REST API to come up.
#   2. Create the generic local repository.
#   3. Generate an admin scoped access token (printed on stdout).
#   4. Upload the synthetic fixture (tarball + manifest) built by build-fixture.sh.
#
# This script is idempotent — re-running it against an already-bootstrapped
# instance will skip steps that have already happened.
#
# Env vars:
#   ART_URL        Default http://localhost:8082/artifactory
#   ART_USER       Default admin
#   ART_PASSWORD   Default password   (Artifactory OSS default)
#   ART_REPO       Default python-binaries-generic-local
#   FIXTURE_DIR    Default ./test/.fixture
#   VERSION        Default 3.11.99
#
# Stdout: a single line "ARTIFACTORY_TOKEN=<token>" so callers can `eval` it.

set -euo pipefail

ART_URL="${ART_URL:-http://127.0.0.1:8082/artifactory}"
ART_USER="${ART_USER:-admin}"
ART_PASSWORD="${ART_PASSWORD:-password}"
ART_REPO="${ART_REPO:-example-repo-local}"
FIXTURE_DIR="${FIXTURE_DIR:-./test/.fixture}"
VERSION="${VERSION:-3.11.99}"
FILENAME="python-${VERSION}-linux-22.04-x64.tar.gz"

log() { printf '[bootstrap] %s\n' "$*" >&2; }

# 1. Wait for REST API.
log "Waiting for Artifactory at $ART_URL ..."
for i in $(seq 1 120); do
  if curl -fsS -u "$ART_USER:$ART_PASSWORD" \
       "$ART_URL/api/system/ping" >/dev/null 2>&1; then
    log "Artifactory is up (after ${i}s)"
    break
  fi
  if [[ $i -eq 120 ]]; then
    log "Artifactory did not become ready in time"
    exit 1
  fi
  sleep 1
done

# Some Artifactory OSS versions force a password change on first login. Set
# the password to itself to clear that flag if needed (best effort, ignored
# if not applicable).
curl -fsS -u "$ART_USER:$ART_PASSWORD" \
  -H "Content-Type: application/json" \
  -X POST "$ART_URL/api/security/users/authorization/changePassword" \
  -d "{\"userName\":\"$ART_USER\",\"oldPassword\":\"$ART_PASSWORD\",\"newPassword1\":\"$ART_PASSWORD\",\"newPassword2\":\"$ART_PASSWORD\"}" \
  >/dev/null 2>&1 || true

# 2. Verify the generic local repo exists.
#
# We do NOT call PUT /api/repositories/<key> here because that endpoint is
# Pro-only on modern Artifactory OSS. Instead this harness uses the
# stock 'example-repo-local' generic repo that Artifactory OSS provisions
# automatically on first boot — it's already there and ready to accept
# uploads with admin credentials.
log "Verifying repo $ART_REPO is available"
http_code=$(curl -s -o /tmp/probe.out -w '%{http_code}' \
  -u "$ART_USER:$ART_PASSWORD" \
  -X PUT "$ART_URL/$ART_REPO/__bootstrap_probe__.txt" \
  --data-binary 'probe')
case "$http_code" in
  200|201)
    curl -fsS -u "$ART_USER:$ART_PASSWORD" \
      -X DELETE "$ART_URL/$ART_REPO/__bootstrap_probe__.txt" >/dev/null 2>&1 || true
    log "Repo $ART_REPO is available"
    ;;
  *)
    log "Repo $ART_REPO not available (HTTP $http_code: $(cat /tmp/probe.out))"
    log "If you've changed ART_REPO away from a stock Artifactory OSS default repo,"
    log "you'll need to create it manually (the OSS REST API for repo creation is gated to Pro)."
    exit 1
    ;;
esac

# 3. Generate a scoped access token.
log "Generating access token"
TOKEN_JSON=$(curl -fsS -u "$ART_USER:$ART_PASSWORD" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -X POST "$ART_URL/api/security/token" \
  -d "username=$ART_USER&scope=member-of-groups:readers&expires_in=3600")
TOKEN=$(echo "$TOKEN_JSON" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -z "$TOKEN" ]]; then
  # Fall back to admin-scoped token (older OSS versions lack the readers group by default).
  TOKEN_JSON=$(curl -fsS -u "$ART_USER:$ART_PASSWORD" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -X POST "$ART_URL/api/security/token" \
    -d "username=$ART_USER&scope=applied-permissions/admin&expires_in=3600")
  TOKEN=$(echo "$TOKEN_JSON" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi
if [[ -z "$TOKEN" ]]; then
  log "Failed to generate token: $TOKEN_JSON"
  exit 1
fi
log "Token generated"

# 4. Upload fixture.
if [[ ! -f "$FIXTURE_DIR/$FILENAME" || ! -f "$FIXTURE_DIR/versions-manifest.json" ]]; then
  log "Fixture missing in $FIXTURE_DIR — run test/build-fixture.sh first"
  exit 1
fi

log "Uploading $FILENAME"
curl -fsS -u "$ART_USER:$ART_PASSWORD" \
  -X PUT "$ART_URL/$ART_REPO/$FILENAME" \
  --data-binary "@$FIXTURE_DIR/$FILENAME" \
  -o /dev/null

log "Uploading versions-manifest.json"
curl -fsS -u "$ART_USER:$ART_PASSWORD" \
  -H "Content-Type: application/json" \
  -X PUT "$ART_URL/$ART_REPO/versions-manifest.json" \
  --data-binary "@$FIXTURE_DIR/versions-manifest.json" \
  -o /dev/null

# Print token to stdout for eval-style consumption.
printf 'ARTIFACTORY_TOKEN=%s\n' "$TOKEN"
log "Bootstrap complete"
