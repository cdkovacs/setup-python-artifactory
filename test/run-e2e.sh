#!/usr/bin/env bash
# End-to-end test: spins up Artifactory in docker-compose, uploads a synthetic
# Python fixture, and runs the bundled action against it. Verifies that the
# action installs the fixture into the runner tool cache and that the
# resulting python executable is invokable.
#
# Usage:
#   ./test/run-e2e.sh                # full run, tears down at the end
#   KEEP_RUNNING=1 ./test/run-e2e.sh # leave Artifactory up for inspection

set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

VERSION="${VERSION:-3.11.99}"
ART_REPO="${ART_REPO:-example-repo-local}"
ART_URL="${ART_URL:-http://127.0.0.1:8082/artifactory}"
TOOL_CACHE="${TOOL_CACHE:-$(mktemp -d)/runner-tool-cache}"
RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)/runner-temp}"
KEEP_RUNNING="${KEEP_RUNNING:-0}"

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

# @actions/core writes to GITHUB_OUTPUT in a heredoc form:
#   <key><<ghadelimiter_<uuid>
#   <value>
#   ghadelimiter_<uuid>
# Extract the value for a given key.
read_output() {
  local key="$1" file="$2"
  awk -v k="$key" '
    $0 ~ "^" k "<<ghadelimiter_" {
      delim = $0
      sub(/^[^<]+<</, "", delim)
      getline val
      print val
      exit
    }
  ' "$file"
}

cleanup() {
  rm -f .vars .secrets
  if [[ "$KEEP_RUNNING" != "1" ]]; then
    log "Tearing down Artifactory"
    docker compose --env-file test/.env -f test/docker-compose.yml down -v >/dev/null 2>&1 || true
  else
    echo "(KEEP_RUNNING=1: leaving Artifactory up at $ART_URL)"
  fi
}
trap cleanup EXIT

# 0. Sanity check: dist must exist.
[[ -f dist/index.js ]] || fail "dist/index.js missing. Run 'npm run build' first."

# 1. Generate test/.env if missing. Holds the 32-byte hex master/join keys
#    that Artifactory 7.x requires. Gitignored so the random hex doesn't
#    trip secret scanners on commit. Reused across runs so the volume
#    (when KEEP_RUNNING=1) stays decryptable.
ENV_FILE="test/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log "Generating $ENV_FILE with fresh master + join keys"
  {
    printf 'JF_SHARED_SECURITY_MASTERKEY=%s\n' "$(openssl rand -hex 32)"
    printf 'JF_SHARED_SECURITY_JOINKEY=%s\n'   "$(openssl rand -hex 32)"
  } > "$ENV_FILE"
fi

# 2. Bring up Artifactory.
log "Starting Artifactory (this can take ~60s on first boot)"
docker compose --env-file test/.env -f test/docker-compose.yml up -d
# Compose's healthcheck waits, but we also poll the REST API directly because
# OSS images sometimes pass the router healthcheck before the API user store
# is fully ready.

# 2. Build fixture.
log "Building synthetic fixture for $VERSION"
VERSION="$VERSION" ARTIFACTORY_URL="$ART_URL" ART_REPO="$ART_REPO" \
  OUT_DIR="./test/.fixture" \
  ./test/build-fixture.sh

# 3. Bootstrap Artifactory and capture the token.
log "Bootstrapping Artifactory (repo + token + fixture upload)"
BOOTSTRAP_OUT=$(VERSION="$VERSION" ART_URL="$ART_URL" ART_REPO="$ART_REPO" \
  FIXTURE_DIR="./test/.fixture" \
  ./test/bootstrap-artifactory.sh)
eval "$BOOTSTRAP_OUT"
[[ -n "${ARTIFACTORY_TOKEN:-}" ]] || fail "bootstrap did not produce a token"

# 4. Verify manifest is reachable with the bearer token.
log "Verifying manifest via bearer token"
HTTP_CODE=$(curl -s -o /tmp/manifest-check.json -w '%{http_code}' \
  -H "Authorization: Bearer $ARTIFACTORY_TOKEN" \
  "$ART_URL/$ART_REPO/versions-manifest.json")
[[ "$HTTP_CODE" == "200" ]] \
  || fail "manifest fetch returned HTTP $HTTP_CODE: $(cat /tmp/manifest-check.json)"
echo "Manifest first entry version: $(grep -o '"version":[^,]*' /tmp/manifest-check.json | head -1)"

# 5. Run the action.
log "Running the bundled action against local Artifactory"
mkdir -p "$TOOL_CACHE" "$RUNNER_TEMP"

# action-emitted ::set-output:: lines go to GITHUB_OUTPUT, so capture them.
# GITHUB_ENV / GITHUB_PATH are appended to by core.exportVariable / core.addPath
# and the action errors if the files don't exist, so create them upfront.
GITHUB_OUTPUT_FILE="$(mktemp)"
GITHUB_ENV_FILE="$(mktemp)"
GITHUB_PATH_FILE="$(mktemp)"

set +e
env -i PATH="$PATH" HOME="$HOME" \
  "INPUT_PYTHON-VERSION=$VERSION" \
  "INPUT_ARTIFACTORY-URL=$ART_URL" \
  "INPUT_ARTIFACTORY-REPO=$ART_REPO" \
  "INPUT_ARTIFACTORY-TOKEN=$ARTIFACTORY_TOKEN" \
  "INPUT_UPDATE-ENVIRONMENT=true" \
  "INPUT_CHECK-LATEST=false" \
  "INPUT_ALLOW-PRERELEASES=false" \
  "RUNNER_TOOL_CACHE=$TOOL_CACHE" \
  "RUNNER_TEMP=$RUNNER_TEMP" \
  "GITHUB_OUTPUT=$GITHUB_OUTPUT_FILE" \
  "GITHUB_ENV=$GITHUB_ENV_FILE" \
  "GITHUB_PATH=$GITHUB_PATH_FILE" \
  node ./dist/index.js
ACTION_EXIT=$?
set -e
[[ $ACTION_EXIT -eq 0 ]] || fail "action exited with code $ACTION_EXIT"

# 6. Verify outputs.
log "Verifying action outputs"
PYTHON_VERSION_OUT=$(read_output python-version "$GITHUB_OUTPUT_FILE")
PYTHON_PATH_OUT=$(read_output python-path "$GITHUB_OUTPUT_FILE")
CACHE_HIT_OUT=$(read_output cache-hit "$GITHUB_OUTPUT_FILE")
echo "python-version output: $PYTHON_VERSION_OUT"
echo "python-path    output: $PYTHON_PATH_OUT"
echo "cache-hit      output: $CACHE_HIT_OUT"

[[ "$PYTHON_VERSION_OUT" == "$VERSION" ]] \
  || fail "expected python-version=$VERSION, got '$PYTHON_VERSION_OUT'"
[[ -x "$PYTHON_PATH_OUT" ]] \
  || fail "python-path '$PYTHON_PATH_OUT' is not executable"
[[ "$CACHE_HIT_OUT" == "false" ]] \
  || fail "expected cache-hit=false on first run, got '$CACHE_HIT_OUT'"

# 7. Run the python stub to confirm it works.
log "Invoking installed python"
"$PYTHON_PATH_OUT" --version

# 8. Re-run the action and confirm it hits the cache.
log "Re-running action to verify cache-hit"
: > "$GITHUB_OUTPUT_FILE"
env -i PATH="$PATH" HOME="$HOME" \
  "INPUT_PYTHON-VERSION=$VERSION" \
  "INPUT_ARTIFACTORY-URL=$ART_URL" \
  "INPUT_ARTIFACTORY-REPO=$ART_REPO" \
  "INPUT_ARTIFACTORY-TOKEN=$ARTIFACTORY_TOKEN" \
  "INPUT_UPDATE-ENVIRONMENT=true" \
  "INPUT_CHECK-LATEST=false" \
  "INPUT_ALLOW-PRERELEASES=false" \
  "RUNNER_TOOL_CACHE=$TOOL_CACHE" \
  "RUNNER_TEMP=$RUNNER_TEMP" \
  "GITHUB_OUTPUT=$GITHUB_OUTPUT_FILE" \
  "GITHUB_ENV=$GITHUB_ENV_FILE" \
  "GITHUB_PATH=$GITHUB_PATH_FILE" \
  node ./dist/index.js

CACHE_HIT_2=$(read_output cache-hit "$GITHUB_OUTPUT_FILE")
[[ "$CACHE_HIT_2" == "true" ]] \
  || fail "expected cache-hit=true on second run, got '$CACHE_HIT_2'"

# 9. Optional: exercise the workflow via nektos/act if it's installed.
#    Runs the same action under a real workflow runner, inside a container
#    that reaches the host Artifactory via host.docker.internal. Skipped
#    silently when `act` isn't on PATH so CI/devs without it aren't blocked.
if command -v act >/dev/null 2>&1; then
  log "Running act against test/workflows/act-e2e.yml"
  cat > .vars <<EOF
PYTHON_VERSION=$VERSION
ARTIFACTORY_URL=http://host.docker.internal:8082/artifactory
ARTIFACTORY_REPO=$ART_REPO
EOF
  cat > .secrets <<EOF
ARTIFACTORY_TOKEN=$ARTIFACTORY_TOKEN
EOF
  act workflow_dispatch \
    -W test/workflows/act-e2e.yml \
    -P ubuntu-latest=catthehacker/ubuntu:act-latest \
    --secret-file .secrets \
    --var-file .vars \
    --container-options "--add-host=host.docker.internal:host-gateway" \
    || fail "act run failed"
else
  log "act not found on PATH; skipping nektos/act workflow run"
fi

log "ALL CHECKS PASSED"
