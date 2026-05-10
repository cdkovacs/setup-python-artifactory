#!/usr/bin/env bash
# Run actionlint, downloading the binary from the Artifactory mirror into
# ./bin/ on first use. Designed for air-gapped environments: there is no
# fallback to github.com.
#
# Required env vars:
#   ARTIFACTORY_URL    Base URL, e.g. https://artifactory.example.com/artifactory
#   ARTIFACTORY_REPO   Generic repo holding mirrored binaries (same repo as Python)
#   ARTIFACTORY_TOKEN  Bearer token with read scope on the repo
#
# Optional:
#   ACTIONLINT_VERSION  Version to fetch (default: 1.7.7). No leading "v" — matches
#                       upstream release filenames. Must already be mirrored into
#                       <repo>/lint-tools/ by sync-lint-tools-to-artifactory.sh.
#
# Args are forwarded to actionlint (e.g. -color, -verbose).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"
ACTIONLINT="$BIN_DIR/actionlint"
ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-1.7.7}"

if [[ ! -x "$ACTIONLINT" ]]; then
  : "${ARTIFACTORY_URL:?ARTIFACTORY_URL is required to fetch actionlint from the mirror}"
  : "${ARTIFACTORY_REPO:?ARTIFACTORY_REPO is required to fetch actionlint from the mirror}"
  : "${ARTIFACTORY_TOKEN:?ARTIFACTORY_TOKEN is required to fetch actionlint from the mirror}"

  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *)
      echo "actionlint mirror does not include $(uname -s); install actionlint manually." >&2
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *)
      echo "actionlint mirror does not include arch $(uname -m); install actionlint manually." >&2
      exit 1
      ;;
  esac

  asset="actionlint_${ACTIONLINT_VERSION}_${os}_${arch}.tar.gz"
  url="${ARTIFACTORY_URL%/}/${ARTIFACTORY_REPO}/lint-tools/${asset}"

  echo "actionlint not present in $BIN_DIR; downloading $ACTIONLINT_VERSION ($os/$arch) from Artifactory ..." >&2
  mkdir -p "$BIN_DIR"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -H "Authorization: Bearer $ARTIFACTORY_TOKEN" "$url" -o "$tmp/actionlint.tar.gz"
  tar -xzf "$tmp/actionlint.tar.gz" -C "$tmp" actionlint
  mv "$tmp/actionlint" "$ACTIONLINT"
  chmod +x "$ACTIONLINT"
fi

cd "$REPO_ROOT"
exec "$ACTIONLINT" "$@"
