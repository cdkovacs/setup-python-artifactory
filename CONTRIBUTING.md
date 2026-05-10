# Contributing

## Prerequisites

- Node.js 24+ (matches the `node24` runtime declared in `action.yml`).
- Docker + Docker Compose v2 (for the end-to-end test harness).

## Build

```bash
npm ci
npm run build      # produces dist/index.js (committed)
```

`dist/index.js` is the runtime entry point. GitHub Actions doesn't run `npm install` on the runner, so every source change must commit a rebuilt `dist/` alongside it. CI verifies `dist/` is up to date.

## Linting

```bash
npm run lint           # everything: typecheck, eslint, prettier --check, actionlint, shellcheck
npm run format         # auto-fix prettier formatting
npm run lint:ts        # eslint only
npm run lint:actions   # actionlint only (workflow YAML)
npm run lint:shell     # shellcheck only
```

`lint:actions` and `lint:shell` auto-download the `actionlint` and `shellcheck` binaries into `./bin/` (gitignored) on first run. The source is selected automatically:

| Where you're running                                               | Source                                        |
|--------------------------------------------------------------------|-----------------------------------------------|
| Public github.com Actions (`GITHUB_SERVER_URL=https://github.com`) | upstream GitHub releases without auth         |
| GHES Actions or local dev with `ARTIFACTORY_URL` set               | Artifactory mirror under `<repo>/lint-tools/` |
| Local dev with no Artifactory configured                           | upstream GitHub releases                      |

For the Artifactory path:

```bash
export ARTIFACTORY_URL=https://artifactory.example.com/artifactory
export ARTIFACTORY_REPO=python-binaries-generic-local
export ARTIFACTORY_TOKEN=<read-token>
```

Pin specific releases with `ACTIONLINT_VERSION=1.7.7` (no leading `v`) or `SHELLCHECK_VERSION=v0.10.0`. When using the mirror, both must already be present under `<repo>/lint-tools/`. See [docs/artifactory-setup.md](docs/artifactory-setup.md#7-lint-tool-mirror) for how to populate them with `scripts/sync-lint-tools-to-artifactory.sh`.

CI for this repo on github.com uses the upstream path (no Artifactory secrets needed). The same workflow (`.github/workflows/lint.yml`) also passes `ARTIFACTORY_URL` / `ARTIFACTORY_REPO` / `ARTIFACTORY_TOKEN` from Variables and Secrets through to the lint steps, so a fork that runs lint on a GHES self-hosted runner will use the mirror once those values are configured. Project-specific actionlint config (allowed self-hosted runner labels, known config vars) lives in `.github/actionlint.yaml`.

## Testing

End-to-end tests live in `test/`. They bring up Artifactory in Docker, upload a synthetic Python fixture, and exercise the action against it. See [test/README.md](test/README.md) for usage.

## Reporting issues

- Bugs and feature requests: open a GitHub issue.
- Security vulnerabilities: follow [SECURITY.md](SECURITY.md). Do not file public issues for security problems.
