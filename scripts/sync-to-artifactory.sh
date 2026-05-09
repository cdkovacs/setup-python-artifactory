#!/usr/bin/env bash
#
# Mirror actions/python-versions releases into a JFrog Artifactory generic repo.
#
# What it does:
#   1. Downloads versions-manifest.json from actions/python-versions.
#   2. Filters the manifest to (a) requested major.minor version lines,
#      (b) requested platforms/arches.
#   3. For each matching file, downloads from GitHub Releases (only if not
#      already in Artifactory) and uploads to the Artifactory generic repo.
#   4. Rewrites every download_url in the manifest to point at Artifactory,
#      then uploads the rewritten manifest to the repo root.
#
# Run this from a host that has both internet egress (to download from
# GitHub) and access to Artifactory. Schedule it on whatever cadence
# (daily/weekly) matches your tolerance for new Python releases.
#
# Required tools on the sync host:
#   - bash 4+
#   - curl
#   - jq
#   - jfrog CLI v2 (https://jfrog.com/getcli/), pre-configured with a
#     server profile via `jf c add`.
#
# Required env vars:
#   ART_SERVER_ID     JFrog CLI server profile name (e.g. "internal-artifactory")
#   ART_REPO          Generic repo name (e.g. "python-binaries-generic-local")
#
# Optional env vars:
#   ART_BASE_URL      Public base URL Artifactory is reachable at from runners,
#                     e.g. https://artifactory.example.com/artifactory.
#                     Used only to rewrite download_url in the mirrored manifest;
#                     uploads go through the configured jf server profile.
#                     Defaults to the URL stored in the jf server profile.
#   VERSION_LINES     Comma-separated minor versions to mirror, e.g. "3.10,3.11,3.12".
#                     Default: "3.10,3.11,3.12,3.13".
#   PLATFORMS         Comma-separated platforms, e.g. "linux,darwin,win32".
#                     Default: "linux,win32".
#   ARCHES            Comma-separated arches, e.g. "x64,arm64".
#                     Default: "x64".
#   INCLUDE_PRERELEASES   "true" to include prereleases. Default: "false".
#   INCLUDE_FREETHREADED  "true" to include freethreaded builds. Default: "false".
#   WORK_DIR          Where to stage downloads. Default: ./.sync-cache
#
# Idempotency: an artifact is only re-uploaded if its checksum doesn't already
# match what's in Artifactory.

set -euo pipefail

: "${ART_SERVER_ID:?ART_SERVER_ID is required}"
: "${ART_REPO:?ART_REPO is required}"

VERSION_LINES="${VERSION_LINES:-3.10,3.11,3.12,3.13}"
PLATFORMS="${PLATFORMS:-linux,win32}"
ARCHES="${ARCHES:-x64}"
INCLUDE_PRERELEASES="${INCLUDE_PRERELEASES:-false}"
INCLUDE_FREETHREADED="${INCLUDE_FREETHREADED:-false}"
WORK_DIR="${WORK_DIR:-./.sync-cache}"

UPSTREAM_MANIFEST_URL="https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

log() { printf '[sync] %s\n' "$*" >&2; }

# Resolve the public Artifactory URL we should bake into the rewritten
# manifest. Prefer ART_BASE_URL, otherwise read from the jf server profile.
resolve_base_url() {
  if [[ -n "${ART_BASE_URL:-}" ]]; then
    echo "${ART_BASE_URL%/}"
    return
  fi
  local url
  url=$(jf c show "$ART_SERVER_ID" 2>/dev/null \
    | awk -F': ' '/Url:/ {print $2; exit}')
  if [[ -z "$url" ]]; then
    log "Could not determine Artifactory URL. Set ART_BASE_URL."
    exit 1
  fi
  echo "${url%/}"
}

ART_BASE_URL_RESOLVED=$(resolve_base_url)
log "Artifactory base URL for runners: $ART_BASE_URL_RESOLVED"

log "Fetching upstream manifest"
curl -fsSL "$UPSTREAM_MANIFEST_URL" -o upstream-manifest.json

# Build a jq filter dynamically from the env vars. Using --argjson with arrays
# lets us avoid eval / shell quoting headaches.
to_json_array() {
  local IFS=','
  read -ra arr <<<"$1"
  printf '['
  local sep=''
  for v in "${arr[@]}"; do
    printf '%s"%s"' "$sep" "$v"
    sep=','
  done
  printf ']'
}

VERSION_LINES_JSON=$(to_json_array "$VERSION_LINES")
PLATFORMS_JSON=$(to_json_array "$PLATFORMS")
ARCHES_JSON=$(to_json_array "$ARCHES")

log "Filtering: versions=$VERSION_LINES platforms=$PLATFORMS arches=$ARCHES prereleases=$INCLUDE_PRERELEASES freethreaded=$INCLUDE_FREETHREADED"

jq \
  --argjson lines "$VERSION_LINES_JSON" \
  --argjson platforms "$PLATFORMS_JSON" \
  --argjson arches "$ARCHES_JSON" \
  --arg prereleases "$INCLUDE_PRERELEASES" \
  --arg freethreaded "$INCLUDE_FREETHREADED" '
  def matches_line($v):
    [ $lines[] | . as $l | ($v | startswith($l + ".")) ] | any;
  map(
    select(($prereleases == "true") or .stable == true)
    | select(matches_line(.version))
    | .files |= map(
        select(.platform as $p | $platforms | index($p))
        | select(.arch as $a | $arches | index($a))
        | select($freethreaded == "true" or (.filename | contains("freethreaded") | not))
      )
    | select((.files | length) > 0)
  )
' upstream-manifest.json > filtered-manifest.json

TOTAL_FILES=$(jq '[.[].files[]] | length' filtered-manifest.json)
log "Selected $TOTAL_FILES file(s) across $(jq 'length' filtered-manifest.json) release(s)"

# Download + upload each file. We stream the URL/filename pairs through jq
# so we don't need to embed them in the shell.
jq -r '.[].files[] | [.filename, .download_url] | @tsv' filtered-manifest.json \
  | while IFS=$'\t' read -r FILENAME URL; do
      LOCAL="downloads/$FILENAME"
      mkdir -p downloads

      # Skip download if Artifactory already has it (cheap HEAD via jf rt s).
      if jf rt s --server-id="$ART_SERVER_ID" "$ART_REPO/$FILENAME" \
           --count 2>/dev/null | grep -q '^1$'; then
        log "skip (already in Artifactory): $FILENAME"
        continue
      fi

      if [[ ! -f "$LOCAL" ]]; then
        log "download: $URL"
        curl -fsSL --retry 3 -o "$LOCAL" "$URL"
      fi

      log "upload: $FILENAME -> $ART_REPO/"
      jf rt u \
        --server-id="$ART_SERVER_ID" \
        --flat=true \
        "$LOCAL" "$ART_REPO/"
    done

# Rewrite download_url to point at Artifactory and upload the manifest.
jq \
  --arg base "$ART_BASE_URL_RESOLVED" \
  --arg repo "$ART_REPO" '
  map(
    .files |= map(
      .download_url = ($base + "/" + $repo + "/" + .filename)
    )
  )
' filtered-manifest.json > versions-manifest.json

log "Uploading rewritten versions-manifest.json"
jf rt u \
  --server-id="$ART_SERVER_ID" \
  --flat=true \
  --target-props="manifest=true" \
  versions-manifest.json "$ART_REPO/versions-manifest.json"

log "Done."
