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

To test against an actual `actions/python-versions` release using [nektos/act](https://github.com/nektos/act):

```bash
# 1. Bring up Artifactory.
docker compose -f test/docker-compose.yml up -d
# The compose healthcheck only pings the router. Wait for the artifactory
# service itself to be ready, since /api/security/token (used below) lives
# behind it and 404s during early boot:
until [ "$(curl -s -o /dev/null -w '%{http_code}' \
  http://localhost:8082/artifactory/api/system/ping)" = "200" ]; do sleep 2; done

# 2. Bootstrap the repo and mint an access token. The script prints
#    "ARTIFACTORY_TOKEN=..." on stdout, so eval it to pick the token up:
eval "$(VERSION=3.11.99 \
  ART_URL=http://127.0.0.1:8082/artifactory \
  ART_REPO=example-repo-local \
  FIXTURE_DIR=./test/.fixture \
  ./test/bootstrap-artifactory.sh)"
# $ARTIFACTORY_TOKEN is now set in your shell.

# 3. Configure the JFrog CLI against localhost using that token.
#    Two gotchas worth knowing:
#      a. --url is the platform URL, so do NOT append /artifactory. If you do,
#         uploads hit /artifactory/artifactory/<repo>/... and Tomcat returns
#         405 Method Not Allowed. Use --artifactory-url=.../artifactory if you
#         prefer the explicit form.
#      b. Using --access-token avoids the /api/security/encryptedPassword
#         endpoint that jf c add otherwise hits with --user/--password (it
#         404s on early-boot OSS; --enc-password=false is the alternative).
jf c add local-art \
  --url=http://localhost:8082 \
  --access-token="$ARTIFACTORY_TOKEN" \
  --interactive=false
jf rt ping --server-id=local-art   # expect: OK

# 4. Run the real sync script.
ART_SERVER_ID=local-art ART_REPO=example-repo-local \
  VERSION_LINES=3.11 PLATFORMS=linux ARCHES=x64 \
  ART_BASE_URL=http://localhost:8082/artifactory \
  ./scripts/sync-to-artifactory.sh

# 5. Run the action with python-version=3.11. It'll download the real
#    tarball from your local Artifactory and run the real upstream setup.sh.
#    The act workflow lives under test/workflows/ so actionlint (which only
#    scans .github/workflows/**) leaves it alone, and GitHub never runs it.
#    host.docker.internal + --add-host=...:host-gateway is how the job
#    container reaches Artifactory on the host's 127.0.0.1:8082.
cat > .vars <<EOF
ARTIFACTORY_URL=http://host.docker.internal:8082/artifactory
ARTIFACTORY_REPO=example-repo-local
EOF
cat > .secrets <<EOF
ARTIFACTORY_TOKEN=$ARTIFACTORY_TOKEN
EOF

act workflow_dispatch \
  -W test/workflows/act-e2e.yml \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest \
  --secret-file .secrets \
  --var-file .vars \
  --container-options "--add-host=host.docker.internal:host-gateway"
```

Note on token scope: `bootstrap-artifactory.sh` prefers
`scope=member-of-groups:readers` and only falls back to
`applied-permissions/admin` if the readers group is missing. On a fresh
OSS 7.x instance the readers path succeeds, so `$ARTIFACTORY_TOKEN` is
read-only and step 4 will 403 with `User token:admin is not permitted to
deploy ...`. If that happens, mint a deploy-scoped token and reconfigure
the CLI before re-running:

```bash
DEPLOY_TOKEN=$(curl -s -u admin:password \
  -X POST http://localhost:8082/artifactory/api/security/token \
  -d 'username=admin&scope=applied-permissions/admin&expires_in=3600' \
  | jq -r .access_token)
jf c remove local-art --quiet
jf c add local-art --url=http://localhost:8082 \
  --access-token="$DEPLOY_TOKEN" --interactive=false
```

This requires internet egress on the host running the sync script (to pull
from `actions/python-versions` releases) but the action itself only talks to
localhost.
