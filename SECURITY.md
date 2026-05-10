# Security policy

## Supported versions

Only the latest `v1.x` release receives security fixes. Older majors are
unsupported once a new major ships.

| Version | Supported          |
|---------|--------------------|
| 1.x     | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems. Instead,
report privately via GitHub's "Report a vulnerability" flow on this repository
(Security tab, then "Advisories", then "Report a vulnerability"). That opens a
private advisory visible only to maintainers.

If for some reason you cannot use the GitHub flow, email the repository owner
directly through the address on their GitHub profile.

Expect an initial acknowledgement within 5 business days. Fixes are released as
patch versions and the moving `v1` tag is updated to point at them.

## Scope

In scope:

- The action itself (`dist/index.js`, `src/`, `action.yml`).
- The bundled sync and lint scripts under `scripts/`.
- The test harness under `test/`.

Out of scope:

- Vulnerabilities in JFrog Artifactory, the JFrog CLI, or `actions/python-versions`.
  Report those to their upstream projects.
- Vulnerabilities in the Python interpreters this action installs. The tarballs
  are produced by the upstream `actions/python-versions` build pipeline and not
  modified by this action. Report Python vulnerabilities to
  <https://www.python.org/dev/security/>.

## Token handling guidance for consumers

The `artifactory-token` input is a bearer token sent in the `Authorization`
header on every request to your Artifactory instance. To minimize blast radius:

1. **Use a scoped access token, not your personal API key.** In Artifactory,
   mint a token whose permissions are limited to read on the repo holding the
   Python tarballs and manifest. The action only performs `GET` against
   `<artifactory-url>/<artifactory-repo>/...`.
2. **Store it as a GitHub Actions secret**, not as a `vars.*` value. Pass it
   via `secrets.ARTIFACTORY_TOKEN` so it never appears in workflow logs.
3. **Rotate on a schedule.** Artifactory access tokens accept an `expires_in`
   parameter. Mint with a finite TTL (e.g. 90 days) and rotate via your secret
   manager.
4. **Restrict the source IP range** in Artifactory if your runners have stable
   egress IPs. This is independent of the action and the strongest defense if
   the token leaks.

The action does not log the token, does not write it to disk, and does not
forward it to any host other than the configured `artifactory-url`. If you
observe behavior that contradicts that, please report it as a vulnerability.
