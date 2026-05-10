#!/usr/bin/env bash
# Run shellcheck, downloading the official binary into ./bin/ on first use.
#
# Args are forwarded to shellcheck. Supports linux + darwin on x86_64 / aarch64.
# Pin a version with SHELLCHECK_VERSION=v0.10.0.

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
  url="https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/${asset}"

  echo "shellcheck not present in $BIN_DIR; downloading $SHELLCHECK_VERSION ($os/$arch) ..." >&2
  mkdir -p "$BIN_DIR"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$url" -o "$tmp/shellcheck.tar.xz"
  tar -xJf "$tmp/shellcheck.tar.xz" -C "$tmp"
  mv "$tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$SHELLCHECK"
  chmod +x "$SHELLCHECK"
fi

cd "$REPO_ROOT"
exec "$SHELLCHECK" "$@"
