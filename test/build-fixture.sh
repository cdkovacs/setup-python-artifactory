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
# CPython build here on purpose — that would require either internet egress
# at test time or a multi-GB fixture.
#
# Output:
#   $OUT_DIR/python-<VERSION>-linux-22.04-x64.tar.gz
#   $OUT_DIR/versions-manifest.json
#
# Env vars:
#   VERSION         Default 3.11.99
#   ARTIFACTORY_URL Default http://localhost:8082/artifactory  (used in manifest)
#   ART_REPO        Default example-repo-local
#   OUT_DIR         Default ./test/.fixture

set -euo pipefail

VERSION="${VERSION:-3.11.99}"
ART_URL="${ARTIFACTORY_URL:-http://127.0.0.1:8082/artifactory}"
ART_REPO="${ART_REPO:-example-repo-local}"
OUT_DIR="${OUT_DIR:-./test/.fixture}"

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

# setup.sh — emulates upstream's tool-cache registration.
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
