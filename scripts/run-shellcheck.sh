#!/usr/bin/env bash
# Run shellcheck, downloading the binary from the Artifactory mirror into
# ./bin/ on first use. Designed for air-gapped environments: there is no
# fallback to github.com.
#
# Required env vars:
#   ARTIFACTORY_URL    Base URL, e.g. https://artifactory.example.com/artifactory
#   ARTIFACTORY_REPO   Generic repo holding mirrored binaries (same repo as Python)
#   ARTIFACTORY_TOKEN  Bearer token with read scope on the repo
#
# Optional:
#   SHELLCHECK_VERSION  Version tag to fetch (default: v0.10.0). Must already be
#                       mirrored into <repo>/lint-tools/ by sync-lint-tools-to-artifactory.sh.
#
# Args are forwarded to shellcheck. Supports linux + darwin on x86_64 / aarch64.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"
SHELLCHECK="$BIN_DIR/shellcheck"
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-v0.10.0}"

if [[ ! -x "$SHELLCHECK" ]]; then
  : "${ARTIFACTORY_URL:?ARTIFACTORY_URL is required to fetch shellcheck from the mirror}"
  : "${ARTIFACTORY_REPO:?ARTIFACTORY_REPO is required to fetch shellcheck from the mirror}"
  : "${ARTIFACTORY_TOKEN:?ARTIFACTORY_TOKEN is required to fetch shellcheck from the mirror}"

  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *)
      echo "shellcheck mirror does not include $(uname -s); install shellcheck manually." >&2
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    *)
      echo "shellcheck mirror does not include arch $(uname -m); install shellcheck manually." >&2
      exit 1
      ;;
  esac

  asset="shellcheck-${SHELLCHECK_VERSION}.${os}.${arch}.tar.xz"
  url="${ARTIFACTORY_URL%/}/${ARTIFACTORY_REPO}/lint-tools/${asset}"

  echo "shellcheck not present in $BIN_DIR; downloading $SHELLCHECK_VERSION ($os/$arch) from Artifactory ..." >&2
  mkdir -p "$BIN_DIR"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -H "Authorization: Bearer $ARTIFACTORY_TOKEN" "$url" -o "$tmp/shellcheck.tar.xz"
  tar -xJf "$tmp/shellcheck.tar.xz" -C "$tmp"
  mv "$tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$SHELLCHECK"
  chmod +x "$SHELLCHECK"
fi

cd "$REPO_ROOT"
exec "$SHELLCHECK" "$@"
