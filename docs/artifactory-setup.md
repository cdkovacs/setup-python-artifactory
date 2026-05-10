# Artifactory setup

This action expects a JFrog Artifactory **generic local** repository containing:

- `versions-manifest.json` at the repo root. This is a copy of the upstream `actions/python-versions` manifest, with every `download_url` rewritten to point at this repo.
- One file per Python build, named exactly as upstream (e.g. `python-3.11.9-linux-22.04-x64.tar.gz`), at the repo root.

The sync script in [`scripts/sync-to-artifactory.sh`](../scripts/sync-to-artifactory.sh) creates and maintains both.

---

## 1. Create the repository

In Artifactory: **Administration → Repositories → Repositories → Add Repository → Local → Generic**.

| Setting | Value |
| --- | --- |
| Repository Key | `python-binaries-generic-local` |
| Includes Pattern | `**/*` |
| Excludes Pattern | *(empty)* |
| Handle Releases | ✓ |
| Handle Snapshots | ✗ |
| Property Sets | *(none)* |

Do **not** enable checksum policies that block uploads on missing SHA-256. The upstream tarballs don't ship sidecar checksums, and we rely on Artifactory's own integrity checks.

If you maintain a virtual repo for downstream consumption, layer `python-binaries-generic` over the local + any remotes; the action only needs read access to the resolving repo name you pass in `artifactory-repo`.

## 2. Create access tokens

You need two distinct tokens.

### 2a. Sync token (used by the sync host)

Scope: **deploy/upload** + **read** on the generic repo.

```bash
# As an Artifactory admin or a user with Manage Tokens permission:
jf rt curl -X POST /api/v1/tokens \
  -d "scope=applied-permissions/groups:python-mirror-syncers" \
  -d "expires_in=2592000"            # 30 days; rotate via cron
```

Or via UI: **User Management → Access Tokens → Generate Token**, scoped to a group that has `Deploy/Cache` + `Read` on `python-binaries-generic-local`.

Configure the JFrog CLI on the sync host:

```bash
jf c add internal-artifactory \
  --url=https://artifactory.example.com/artifactory \
  --access-token=<token> \
  --interactive=false
```

### 2b. Runner token (used by the action)

Scope: **read-only** on the generic repo.

Generate a long-lived (or rotated) access token with read scope. Treat it as a CI secret:

- **GHES org-level secret** named `ARTIFACTORY_TOKEN` (recommended), so every workflow can reference `${{ secrets.ARTIFACTORY_TOKEN }}` without per-repo provisioning.
- Or per-repo secret if you need finer-grained access control.

Read-only is sufficient because the action only does `GET /<repo>/versions-manifest.json` and `GET /<repo>/<filename>`.

## 3. Run the sync job

The sync script needs to run on a host that can reach **both** github.com and Artifactory. Typical placements:

- A bastion / jump host with outbound internet.
- A separate, internet-connected CI runner (not in the air-gapped pool).
- A scheduled GHES Actions workflow on an internet-connected runner that pushes to Artifactory over the corporate network.

### One-shot run

```bash
export ART_SERVER_ID=internal-artifactory
export ART_REPO=python-binaries-generic-local
export VERSION_LINES="3.10,3.11,3.12,3.13"
export PLATFORMS="linux,win32"
export ARCHES="x64"
./scripts/sync-to-artifactory.sh
```

### Scheduled run (cron)

```cron
# Every Sunday at 02:00. Picks up any new patch releases.
0 2 * * 0  cd /opt/setup-python-artifactory && ART_SERVER_ID=internal-artifactory ART_REPO=python-binaries-generic-local ./scripts/sync-to-artifactory.sh >> /var/log/python-mirror.log 2>&1
```

### Scheduled run (GitHub Actions, internet-connected runner)

```yaml
# .github/workflows/sync-python.yml
name: Mirror Python binaries to Artifactory
on:
  schedule:
    - cron: '0 2 * * 0'
  workflow_dispatch:
jobs:
  sync:
    runs-on: [self-hosted, internet-egress]
    steps:
      - uses: actions/checkout@v4
      - uses: jfrog/setup-jfrog-cli@v4
        env:
          JF_URL: ${{ vars.ARTIFACTORY_URL }}
          JF_ACCESS_TOKEN: ${{ secrets.ARTIFACTORY_SYNC_TOKEN }}
      - run: ./scripts/sync-to-artifactory.sh
        env:
          ART_SERVER_ID: ${{ vars.ARTIFACTORY_SERVER_ID }}
          ART_REPO: python-binaries-generic-local
          VERSION_LINES: '3.10,3.11,3.12,3.13'
          PLATFORMS: 'linux,win32'
          ARCHES: 'x64'
```

## 4. Verify the mirror

```bash
# Manifest fetches and is well-formed:
curl -fsSL -H "Authorization: Bearer $TOKEN" \
  https://artifactory.example.com/artifactory/python-binaries-generic-local/versions-manifest.json \
  | jq '.[0:2] | .[].version'

# A specific tarball is present and download_url points back at Artifactory:
curl -fsSL -H "Authorization: Bearer $TOKEN" \
  https://artifactory.example.com/artifactory/python-binaries-generic-local/versions-manifest.json \
  | jq '.[] | select(.version == "3.11.9") | .files[] | select(.platform == "linux") | .download_url'
```

## 5. Runner network requirements

Self-hosted runners need outbound HTTPS to:

- `artifactory.example.com` (or wherever you host) on 443.

If your runners go through a corporate proxy, set `https_proxy` / `HTTPS_PROXY` in the runner environment; `@actions/http-client` and `@actions/tool-cache` honor it.

## 6. Storage sizing

A rough estimate per minor Python version on Linux+Windows x64, including the 5 most recent patch releases per minor:

| Asset | Approximate size |
| --- | --- |
| One linux tarball | ~30 MB |
| One windows zip | ~25 MB |
| 4 minors × 5 patches × 2 platforms | ~1.1 GB |

Plan ~2–3 GB of headroom and rely on Artifactory's storage policies for cleanup. Old patch releases stay valid (workflows pin to them), so don't aggressively prune.

## 7. Rotation and incident response

- **Token rotation**: rotate the runner-side token at least quarterly. Update the `ARTIFACTORY_TOKEN` org secret. No action change needed.
- **Bad mirror**: if a sync run uploads a corrupted file, re-run the sync. The script idempotently re-checks Artifactory and re-uploads anything missing or with a checksum mismatch. To force re-upload, delete the affected file from Artifactory first.
- **Hot patch a Python release**: if you need a version urgently before the next sync, run the sync script ad-hoc with `VERSION_LINES` narrowed to just that minor.
