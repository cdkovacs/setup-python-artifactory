#!/usr/bin/env bash
# Run actionlint, downloading the binary into ./bin/ on first use.
#
# Source selection (auto):
#   - On public github.com Actions runs (GITHUB_SERVER_URL=https://github.com)
#     fetch via the official rhysd/actionlint download script. No auth required.
#   - Otherwise (GHES Actions runs, local dev with ARTIFACTORY_URL configured,
#     air-gapped runners) fetch from the Artifactory mirror under
#     <ARTIFACTORY_REPO>/lint-tools/. Requires ARTIFACTORY_URL,
#     ARTIFACTORY_REPO, ARTIFACTORY_TOKEN.
#   - If neither condition matches (local dev with no Artifactory configured)
#     fall back to the official upstream download script.
#
# Optional:
#   ACTIONLINT_VERSION  Version (default: 1.7.7, no leading "v"). When using
#                       the mirror, must already be present under
#                       <repo>/lint-tools/. The upstream download script also
#                       accepts "latest".
#
# Args are forwarded to actionlint (e.g. -color, -verbose).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"
ACTIONLINT="$BIN_DIR/actionlint"
ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-1.7.7}"

if [[ ! -x "$ACTIONLINT" ]]; then
  mkdir -p "$BIN_DIR"

  if [[ "${GITHUB_SERVER_URL:-}" != "https://github.com" && -n "${ARTIFACTORY_URL:-}" ]]; then
    : "${ARTIFACTORY_REPO:?ARTIFACTORY_REPO is required when ARTIFACTORY_URL is set}"
    : "${ARTIFACTORY_TOKEN:?ARTIFACTORY_TOKEN is required when ARTIFACTORY_URL is set}"

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
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -H "Authorization: Bearer $ARTIFACTORY_TOKEN" "$url" -o "$tmp/actionlint.tar.gz"
    tar -xzf "$tmp/actionlint.tar.gz" -C "$tmp" actionlint
    mv "$tmp/actionlint" "$ACTIONLINT"
    chmod +x "$ACTIONLINT"
  else
    echo "actionlint not present in $BIN_DIR; downloading $ACTIONLINT_VERSION from github.com upstream ..." >&2
    (
      cd "$BIN_DIR"
      bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) \
        "$ACTIONLINT_VERSION" >/dev/null
    )
  fi
fi

cd "$REPO_ROOT"
exec "$ACTIONLINT" "$@"
