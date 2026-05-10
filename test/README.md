# Local end-to-end test

Brings up Artifactory OSS in Docker, uploads a synthetic "Python release"
(a tiny tarball with a stub `python3` and a `setup.sh` that registers it in
the runner tool cache), and runs the bundled action against it. Verifies:

1. The action fetches the manifest with bearer auth.
2. Semver matching picks the right release.
3. The tarball is downloaded, extracted, and `setup.sh` runs.
4. `tc.find('Python', ...)` resolves the install.
5. Outputs (`python-version`, `python-path`, `cache-hit`) are correct.
6. A second invocation hits the tool cache (`cache-hit=true`).

The test does **not** exercise a real CPython build, which would require
either internet egress or shipping a multi-GB fixture in this repo. To do a
true end-to-end against a real Python release, see "Real Python release"
below.

## Prereqs

- Docker + Docker Compose v2
- Node 18+ (to load `dist/index.js`)
- `dist/index.js` already built (`npm ci && npm run build`)

## Run it

```bash
./test/run-e2e.sh
```

First run takes ~60 seconds for Artifactory OSS to boot. Subsequent runs are
~30 seconds because the volume is recreated each time. To keep the
Artifactory instance up for poking around:

```bash
KEEP_RUNNING=1 ./test/run-e2e.sh
# Browse to http://localhost:8082/ui/  (admin / password)
```

Tear it down manually:

```bash
docker compose -f test/docker-compose.yml down -v
```

## What's where

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Artifactory OSS + Postgres backend, ports 8081/8082 |
| `build-fixture.sh` | Creates the fake tarball + manifest under `.fixture/` |
| `bootstrap-artifactory.sh` | Waits for the API + repo, mints a token, uploads the fixture |
| `run-e2e.sh` | Orchestrates everything and asserts on action outputs |

The fixture also includes stub `actionlint` and `shellcheck` archives, uploaded to `<repo>/lint-tools/`. These let the project's own dev-tooling scripts (`scripts/run-shellcheck.sh`, `scripts/run-actionlint.sh`) resolve against the local Artifactory exactly the way they do in production. They aren't exercised by `run-e2e.sh`. See "Verifying lint-tool download path" below if you want to test that flow manually.

## Generated `test/.env`

`run-e2e.sh` writes `test/.env` (gitignored) on first run with two
random 32-byte hex values:

```
JF_SHARED_SECURITY_MASTERKEY=<openssl rand -hex 32>
JF_SHARED_SECURITY_JOINKEY=<openssl rand -hex 32>
```

Artifactory 7.x requires both. They're kept out of git so secret
scanners (gitleaks etc.) don't flag the random hex strings. The keys
are reused across runs so a `KEEP_RUNNING=1` volume stays decryptable;
deleting `test/.env` just regenerates them on the next run.

## OSS limitation: repo creation REST endpoint

Modern Artifactory OSS (7.x) gates `PUT /api/repositories/<key>` behind a
Pro license. Calling it returns:

```
"This REST API is available only in Artifactory Pro ..."
```

To stay OSS-only, this harness reuses the stock generic repo
`example-repo-local` that Artifactory provisions automatically on first
boot. It accepts uploads with admin credentials and serves downloads with
bearer-auth tokens, which is everything we need to exercise the action.

If you change `ART_REPO` to a non-default name, you'll need to create
that repo manually via the UI (admin/password) before the bootstrap
script can upload to it.

## Verifying lint-tool download path (manual)

After `KEEP_RUNNING=1 ./test/run-e2e.sh`, the local Artifactory has stub `actionlint` and `shellcheck` archives at `<repo>/lint-tools/`. To confirm `scripts/run-*.sh` can pull them:

```bash
eval "$(VERSION=3.11.99 ART_URL=http://127.0.0.1:8082/artifactory ART_REPO=example-repo-local \
  FIXTURE_DIR=./test/.fixture ./test/bootstrap-artifactory.sh)"  # re-mint a token if needed

rm -f bin/shellcheck bin/actionlint
ARTIFACTORY_URL=http://127.0.0.1:8082/artifactory \
ARTIFACTORY_REPO=example-repo-local \
ARTIFACTORY_TOKEN="$ARTIFACTORY_TOKEN" \
  ./scripts/run-shellcheck.sh --version
# -> "ShellCheck v0.10.0 (test fixture)"

ARTIFACTORY_URL=http://127.0.0.1:8082/artifactory \
ARTIFACTORY_REPO=example-repo-local \
ARTIFACTORY_TOKEN="$ARTIFACTORY_TOKEN" \
  ./scripts/run-actionlint.sh -version
# -> "actionlint 1.7.7 (test fixture)"
```

Both commands should download from the local Artifactory, cache into `./bin/`, and print the stub version banner.

## Real Python release (manual)

To test against an actual `actions/python-versions` release:

```bash
# 1. Bring up Artifactory + bootstrap empty repo (no fixture).
docker compose -f test/docker-compose.yml up -d
# wait for it to be healthy, then mint a token via UI or with the bootstrap script
# (it'll fail at the upload step; that's fine, it still creates the repo + token)

# 2. Run the real sync script with the JFrog CLI configured against localhost:
jf c add local-art --url=http://localhost:8082/artifactory --user=admin --password=password --interactive=false
ART_SERVER_ID=local-art ART_REPO=example-repo-local \
  VERSION_LINES=3.11 PLATFORMS=linux ARCHES=x64 \
  ART_BASE_URL=http://localhost:8082/artifactory \
  ./scripts/sync-to-artifactory.sh

# 3. Run the action with python-version=3.11. It'll download the real
#    tarball from your local Artifactory and run the real upstream setup.sh.
```

This requires internet egress on the host running the sync script (to pull
from `actions/python-versions` releases) but the action itself only talks to
localhost.
