#!/usr/bin/env bash
#
# Mirror actionlint and shellcheck release binaries into the JFrog Artifactory
# generic repo used by this project (the same repo that holds Python tarballs).
#
# For each (tool, version, os, arch) tuple, downloads the official release
# archive from GitHub and uploads it under "<repo>/lint-tools/<filename>"
# using the exact upstream filename. The run-actionlint.sh / run-shellcheck.sh
# helpers fetch from that path.
#
# Run on a host that has both internet egress (for github.com) and access to
# Artifactory.
#
# Required tools on the sync host: bash 4+, curl, jfrog CLI v2 (`jf c add`-configured).
#
# Required env vars:
#   ART_SERVER_ID   JFrog CLI server profile name
#   ART_REPO        Generic repo name (same one used for Python binaries)
#
# Optional env vars:
#   ACTIONLINT_VERSIONS   Comma-separated. Default: "1.7.7" (no leading "v").
#   SHELLCHECK_VERSIONS   Comma-separated. Default: "v0.10.0".
#   PLATFORMS             Comma-separated os names. Default: "linux,darwin".
#   ACTIONLINT_ARCHES     Comma-separated. Default: "amd64,arm64".
#   SHELLCHECK_ARCHES     Comma-separated. Default: "x86_64,aarch64".
#   WORK_DIR              Where to stage downloads. Default: ./.sync-cache/lint-tools
#
# Idempotency: an artifact is skipped if it already exists in Artifactory.

set -euo pipefail

: "${ART_SERVER_ID:?ART_SERVER_ID is required}"
: "${ART_REPO:?ART_REPO is required}"

ACTIONLINT_VERSIONS="${ACTIONLINT_VERSIONS:-1.7.7}"
SHELLCHECK_VERSIONS="${SHELLCHECK_VERSIONS:-v0.10.0}"
PLATFORMS="${PLATFORMS:-linux,darwin}"
ACTIONLINT_ARCHES="${ACTIONLINT_ARCHES:-amd64,arm64}"
SHELLCHECK_ARCHES="${SHELLCHECK_ARCHES:-x86_64,aarch64}"
WORK_DIR="${WORK_DIR:-./.sync-cache/lint-tools}"

mkdir -p "$WORK_DIR/downloads"
cd "$WORK_DIR"

log() { printf '[lint-sync] %s\n' "$*" >&2; }

split_csv() {
  local IFS=','
  read -ra _arr <<<"$1"
  printf '%s\n' "${_arr[@]}"
}

mirror_one() {
  local asset="$1" url="$2"
  local local_path="downloads/$asset"
  local target="$ART_REPO/lint-tools/$asset"

  if jf rt s --server-id="$ART_SERVER_ID" "$target" --count 2>/dev/null | grep -q '^1$'; then
    log "skip (already in Artifactory): $target"
    return
  fi

  if [[ ! -f "$local_path" ]]; then
    log "download: $url"
    curl -fsSL --retry 3 -o "$local_path" "$url"
  fi

  log "upload: $asset -> $target"
  jf rt u --server-id="$ART_SERVER_ID" --flat=true "$local_path" "$target"
}

while IFS= read -r v; do
  [[ -z "$v" ]] && continue
  while IFS= read -r os; do
    [[ -z "$os" ]] && continue
    while IFS= read -r arch; do
      [[ -z "$arch" ]] && continue
      asset="shellcheck-${v}.${os}.${arch}.tar.xz"
      url="https://github.com/koalaman/shellcheck/releases/download/${v}/${asset}"
      mirror_one "$asset" "$url"
    done < <(split_csv "$SHELLCHECK_ARCHES")
  done < <(split_csv "$PLATFORMS")
done < <(split_csv "$SHELLCHECK_VERSIONS")

while IFS= read -r v; do
  [[ -z "$v" ]] && continue
  while IFS= read -r os; do
    [[ -z "$os" ]] && continue
    while IFS= read -r arch; do
      [[ -z "$arch" ]] && continue
      asset="actionlint_${v}_${os}_${arch}.tar.gz"
      url="https://github.com/rhysd/actionlint/releases/download/v${v}/${asset}"
      mirror_one "$asset" "$url"
    done < <(split_csv "$ACTIONLINT_ARCHES")
  done < <(split_csv "$PLATFORMS")
done < <(split_csv "$ACTIONLINT_VERSIONS")

log "Done."
