#!/usr/bin/env bash
# Run actionlint, downloading the official binary into ./bin/ on first use.
#
# Args are forwarded to actionlint (e.g. -color, -verbose).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"
ACTIONLINT="$BIN_DIR/actionlint"
ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-latest}"

if [[ ! -x "$ACTIONLINT" ]]; then
  echo "actionlint not present in $BIN_DIR; downloading $ACTIONLINT_VERSION ..." >&2
  mkdir -p "$BIN_DIR"
  (
    cd "$BIN_DIR"
    # Official download script from rhysd/actionlint. Picks the right binary
    # for the current OS/arch and verifies the SHA256 against the release.
    bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) \
      "$ACTIONLINT_VERSION" >/dev/null
  )
fi

cd "$REPO_ROOT"
exec "$ACTIONLINT" "$@"
