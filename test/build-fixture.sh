#!/usr/bin/env bash
# Build a synthetic Python "release" tarball + manifest for hermetic E2E testing.
#
# The tarball mimics the on-disk layout actions/python-versions ships:
#   .
#   ├── setup.sh          # entry point our action invokes
#   └── tool/             # the "Python install" payload
#       └── bin/python3   # a stub that prints a recognizable version line
#
# Our setup.sh emulates what the upstream setup.sh does: copy the payload into
# $RUNNER_TOOL_CACHE/Python/<version>/<arch> and create the .complete marker
# so @actions/tool-cache's tc.find() picks it up. We do not exercise a real
# CPython build here on purpose. That would require either internet egress
# at test time or a multi-GB fixture.
#
# Output:
#   $OUT_DIR/python-<VERSION>-linux-22.04-x64.tar.gz
#   $OUT_DIR/versions-manifest.json
#   $OUT_DIR/lint-tools/shellcheck-<SHELLCHECK_VERSION>.linux.x86_64.tar.xz   (stub)
#   $OUT_DIR/lint-tools/actionlint_<ACTIONLINT_VERSION>_linux_amd64.tar.gz    (stub)
#
# The lint-tool stubs match the on-disk archive layout the upstream releases use,
# so scripts/run-shellcheck.sh and scripts/run-actionlint.sh can fetch and extract
# them from the local Artifactory just like real binaries.
#
# Env vars:
#   VERSION             Default 3.11.99
#   ARTIFACTORY_URL     Default http://localhost:8082/artifactory  (used in manifest)
#   ART_REPO            Default example-repo-local
#   OUT_DIR             Default ./test/.fixture
#   SHELLCHECK_VERSION  Default v0.10.0   (must match scripts/run-shellcheck.sh default)
#   ACTIONLINT_VERSION  Default 1.7.7     (must match scripts/run-actionlint.sh default)

set -euo pipefail

VERSION="${VERSION:-3.11.99}"
ART_URL="${ARTIFACTORY_URL:-http://127.0.0.1:8082/artifactory}"
ART_REPO="${ART_REPO:-example-repo-local}"
OUT_DIR="${OUT_DIR:-./test/.fixture}"
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-v0.10.0}"
ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-1.7.7}"

FILENAME="python-${VERSION}-linux-22.04-x64.tar.gz"

mkdir -p "$OUT_DIR"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/tool/bin"

# A "python3" stub that prints a recognizable banner. Good enough to prove the
# tool-cache install resolves and is executable.
cat > "$STAGE/tool/bin/python3" <<PYSTUB
#!/usr/bin/env bash
case "\$1" in
  --version|-V) echo "Python ${VERSION}" ;;
  *) echo "Python ${VERSION} (test fixture)"; exit 0 ;;
esac
PYSTUB
chmod 0755 "$STAGE/tool/bin/python3"
ln -sf python3 "$STAGE/tool/bin/python"

# setup.sh: emulates upstream's tool-cache registration.
cat > "$STAGE/setup.sh" <<'SETUP'
#!/usr/bin/env bash
set -euo pipefail
: "${RUNNER_TOOL_CACHE:?RUNNER_TOOL_CACHE must be set by the action runtime}"

# The version + arch are baked in at fixture-build time below.
VERSION="__VERSION__"
ARCH="x64"

DEST="$RUNNER_TOOL_CACHE/Python/$VERSION/$ARCH"
mkdir -p "$DEST"

# Copy payload (tool/*) into the destination.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -R "$SCRIPT_DIR/tool/." "$DEST/"

# tc.find() looks for {DEST}.complete to consider a tool installed.
touch "$RUNNER_TOOL_CACHE/Python/$VERSION/$ARCH.complete"

echo "[fixture setup.sh] Installed Python $VERSION to $DEST"
SETUP
sed -i.bak "s/__VERSION__/${VERSION}/g" "$STAGE/setup.sh" && rm "$STAGE/setup.sh.bak"
chmod 0755 "$STAGE/setup.sh"

# Build the tarball with deterministic ordering so checksums are stable across runs.
tar -C "$STAGE" \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    -czf "$OUT_DIR/$FILENAME" \
    setup.sh tool

# Manifest with a single entry pointing at our local Artifactory.
cat > "$OUT_DIR/versions-manifest.json" <<MANIFEST
[
  {
    "version": "${VERSION}",
    "stable": true,
    "release_url": "https://example.invalid/test-fixture",
    "files": [
      {
        "filename": "${FILENAME}",
        "arch": "x64",
        "platform": "linux",
        "platform_version": "22.04",
        "download_url": "${ART_URL}/${ART_REPO}/${FILENAME}"
      }
    ]
  }
]
MANIFEST

echo "[build-fixture] wrote $OUT_DIR/$FILENAME"
echo "[build-fixture] wrote $OUT_DIR/versions-manifest.json"

# Lint-tool stubs. These exist purely so scripts/run-shellcheck.sh and
# scripts/run-actionlint.sh have something to fetch + extract from the local
# Artifactory; they don't actually lint anything. Layouts mirror upstream
# release archives: the ShellCheck tarball nests its binary under a
# versioned directory, while the actionlint tarball has its binary at the root.
LINT_OUT="$OUT_DIR/lint-tools"
mkdir -p "$LINT_OUT"
LINT_STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE" "$LINT_STAGE"' EXIT

mkdir -p "$LINT_STAGE/shellcheck-${SHELLCHECK_VERSION}"
cat > "$LINT_STAGE/shellcheck-${SHELLCHECK_VERSION}/shellcheck" <<SHSTUB
#!/usr/bin/env bash
case "\$1" in
  --version|-V) printf 'ShellCheck %s (test fixture)\n' "${SHELLCHECK_VERSION}" ;;
  *) exit 0 ;;
esac
SHSTUB
chmod 0755 "$LINT_STAGE/shellcheck-${SHELLCHECK_VERSION}/shellcheck"

SHELLCHECK_ASSET="shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
tar -C "$LINT_STAGE" \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    -cJf "$LINT_OUT/$SHELLCHECK_ASSET" \
    "shellcheck-${SHELLCHECK_VERSION}"

cat > "$LINT_STAGE/actionlint" <<ALSTUB
#!/usr/bin/env bash
case "\$1" in
  -version|--version) printf 'actionlint %s (test fixture)\n' "${ACTIONLINT_VERSION}" ;;
  *) exit 0 ;;
esac
ALSTUB
chmod 0755 "$LINT_STAGE/actionlint"

ACTIONLINT_ASSET="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
tar -C "$LINT_STAGE" \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    -czf "$LINT_OUT/$ACTIONLINT_ASSET" \
    actionlint

echo "[build-fixture] wrote $LINT_OUT/$SHELLCHECK_ASSET"
echo "[build-fixture] wrote $LINT_OUT/$ACTIONLINT_ASSET"
