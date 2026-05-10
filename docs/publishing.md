# Publishing the action to GitHub Enterprise Server

Because runners are air-gapped, they cannot pull this action from `github.com`. The action source must live on your internal GHES instance.

## Recommended layout

Create one internal repo, e.g. `your-org/setup-python-artifactory`, and tag releases on it.

```yaml
# Workflows reference it like this:
- uses: your-org/setup-python-artifactory@v1
```

## One-time setup

1. **Create the repo on GHES** (`your-org/setup-python-artifactory`).
2. **Push this codebase**:
   ```bash
   git remote add origin https://ghes.example.com/your-org/setup-python-artifactory.git
   git push -u origin main
   ```
3. **Build and commit `dist/`**:
   ```bash
   npm ci
   npm run build
   git add dist/
   git commit -m "Build dist/"
   git push
   ```
4. **Tag a release**:
   ```bash
   git tag -a v1.0.0 -m "Initial release"
   git tag -fa v1 -m "Move v1 to v1.0.0"   # floating major tag
   git push --tags --force
   ```

   Floating major tags (`v1`) are the standard pattern. Workflows pin to `@v1` and pick up patch updates automatically; pin to `@v1.0.0` for full reproducibility.

## Allow the action in workflows

GHES restricts which actions can be used. In **Enterprise/Org settings → Actions → General**, ensure one of:

- "Allow all actions and reusable workflows" (most permissive), or
- "Allow enterprise, and select non-enterprise, actions" with `your-org/setup-python-artifactory@*` added to the allowlist.

If you also want to ban the upstream `actions/setup-python` to prevent accidental egress attempts, add it to the disallowed list. The air-gap will fail it anyway, but failing in policy is friendlier than failing on a network timeout.

## Release workflow (optional)

Add a workflow to your fork to automate `dist/` rebuilds on every PR/merge:

```yaml
# .github/workflows/build.yml
name: Build dist
on:
  pull_request:
  push:
    branches: [main]
jobs:
  build:
    runs-on: [self-hosted, linux]
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-node@v6
        with:
          node-version: '24'
      - run: npm ci
      - run: npm run build
      - name: Verify dist is up to date
        run: |
          if ! git diff --quiet dist/; then
            echo "::error::dist/ is out of date. Run 'npm run build' and commit."
            git --no-pager diff dist/
            exit 1
          fi
```

## Required action mirrors

Air-gapped GHES runners can't resolve `uses: <owner>/<repo>@<tag>` against `github.com`. Every third-party action referenced by this project's workflows (and by the example workflows in the rest of [docs/](.)) must be mirrored into your internal GHES under the same owner/repo path and tag, with the action's compiled `dist/` intact, so the existing `uses:` lines keep resolving locally.

| Action                     | Pinned at | Purpose                                                                                                     | Upstream                                   |
|----------------------------|-----------|-------------------------------------------------------------------------------------------------------------|--------------------------------------------|
| `actions/checkout@v6`      | `v6`      | Checkout source in CI lint, sync, and publish workflows                                                     | <https://github.com/actions/checkout>      |
| `actions/setup-node@v6`    | `v6`      | Install Node.js for `npm ci` / `npm run build` and lint                                                     | <https://github.com/actions/setup-node>    |
| `jfrog/setup-jfrog-cli@v5` | `v5`      | Provision `jf` CLI on the sync runner (only if you run `scripts/sync-to-artifactory.sh` as a GHES workflow) | <https://github.com/jfrog/setup-jfrog-cli> |

These tags are all on the Node.js 24 line, matching the `node24` runtime declared in this repo's `action.yml`. Older `@v4` tags use Node.js 20, which GitHub forces to Node.js 24 starting June 2nd, 2026 and removes from the runner on September 16th, 2026 ([deprecation notice](https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/)). GHES self-hosted runners need to be on `actions/runner` v2.327.1 or later for Node.js 24 compatibility.

Where this list comes from:

- `.github/workflows/lint.yml` references `actions/checkout` and `actions/setup-node`.
- [artifactory-setup.md](artifactory-setup.md) (sync-from-Actions example) references `actions/checkout` and `jfrog/setup-jfrog-cli`.
- This doc's [Release workflow](#release-workflow-optional) example references `actions/checkout` and `actions/setup-node`.

The `setup-python-artifactory` action itself bundles its Node deps via `ncc` into `dist/index.js`, so consumers calling `uses: your-org/setup-python-artifactory@v1` pick up no transitive action dependencies beyond the three above.

### Mirroring approach

The simplest path is a one-shot script per action: clone from `github.com/<owner>/<repo>` at the pinned tag, push to `https://<ghes>/<owner>/<repo>` preserving the tag, and rerun whenever you bump a major. Keep `dist/` from upstream, since these are JavaScript actions and the runner executes `dist/index.js` directly.

If your GHES org name doesn't match upstream (e.g. you mirror under `internal-tools/` rather than `actions/`), update the `uses:` lines in this repo's workflows and the docs examples to match. Don't rewrite them upstream, because public github.com CI for this repo relies on the original paths.
