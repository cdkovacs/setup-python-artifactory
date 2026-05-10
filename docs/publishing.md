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
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
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

(You'll need an internal mirror of `actions/checkout` and `actions/setup-node` to make this run; a small bootstrapping concern that applies to any GHES + air-gap setup.)
