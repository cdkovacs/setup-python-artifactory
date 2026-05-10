#!/usr/bin/env bash
# Run shellcheck, downloading the binary into ./bin/ on first use.
#
# Source selection (auto):
#   - On public github.com Actions runs (GITHUB_SERVER_URL=https://github.com)
#     fetch from the official GitHub release. No auth required.
#   - Otherwise (GHES Actions runs, local dev with ARTIFACTORY_URL configured,
#     air-gapped runners) fetch from the Artifactory mirror under
#     <ARTIFACTORY_REPO>/lint-tools/. Requires ARTIFACTORY_URL,
#     ARTIFACTORY_REPO, ARTIFACTORY_TOKEN.
#   - If neither condition matches (local dev with no Artifactory configured)
#     fall back to the official GitHub release.
#
# Optional:
#   SHELLCHECK_VERSION  Version tag (default: v0.10.0). When using the mirror,
#                       must already be present under <repo>/lint-tools/.
#
# Args are forwarded to shellcheck. Supports linux + darwin on x86_64 / aarch64.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"
SHELLCHECK="$BIN_DIR/shellcheck"
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-v0.10.0}"

if [[ ! -x "$SHELLCHECK" ]]; then
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *)
      echo "shellcheck auto-install does not support $(uname -s). Install shellcheck manually." >&2
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    *)
      echo "shellcheck auto-install does not support arch $(uname -m). Install shellcheck manually." >&2
      exit 1
      ;;
  esac

  asset="shellcheck-${SHELLCHECK_VERSION}.${os}.${arch}.tar.xz"
  curl_args=()

  if [[ "${GITHUB_SERVER_URL:-}" != "https://github.com" && -n "${ARTIFACTORY_URL:-}" ]]; then
    : "${ARTIFACTORY_REPO:?ARTIFACTORY_REPO is required when ARTIFACTORY_URL is set}"
    : "${ARTIFACTORY_TOKEN:?ARTIFACTORY_TOKEN is required when ARTIFACTORY_URL is set}"
    url="${ARTIFACTORY_URL%/}/${ARTIFACTORY_REPO}/lint-tools/${asset}"
    curl_args+=(-H "Authorization: Bearer $ARTIFACTORY_TOKEN")
    source_label="Artifactory ($ARTIFACTORY_URL)"
  else
    url="https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/${asset}"
    source_label="github.com upstream"
  fi

  echo "shellcheck not present in $BIN_DIR; downloading $SHELLCHECK_VERSION ($os/$arch) from $source_label ..." >&2
  mkdir -p "$BIN_DIR"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "${curl_args[@]}" "$url" -o "$tmp/shellcheck.tar.xz"
  tar -xJf "$tmp/shellcheck.tar.xz" -C "$tmp"
  mv "$tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$SHELLCHECK"
  chmod +x "$SHELLCHECK"
fi

cd "$REPO_ROOT"
exec "$SHELLCHECK" "$@"
