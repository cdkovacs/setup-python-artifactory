import * as core from '@actions/core';
import * as semver from 'semver';
import {ArtifactoryConfig, buildClient, manifestUrl} from './http';
import {
  ManifestFile,
  ManifestRelease,
  getLinuxOSReleaseInfo,
  getOSArch,
  getOSPlatform,
  IS_LINUX
} from './utils';

export async function fetchManifest(cfg: ArtifactoryConfig): Promise<ManifestRelease[]> {
  const url = manifestUrl(cfg);
  core.info(`Fetching manifest from ${url}`);
  const client = buildClient(cfg.token);
  const response = await client.getJson<ManifestRelease[]>(url);
  if (response.statusCode !== 200 || !response.result) {
    throw new Error(
      `Failed to fetch manifest from ${url}: HTTP ${response.statusCode}`
    );
  }
  return response.result;
}

export function normalizeRange(input: string, allowPrereleases: boolean): string {
  const trimmed = input.trim();
  // For "minor-only" / "major-only" patterns, build an explicit range.
  // When prereleases are allowed, anchor the lower bound at "-0" so that
  // semver picks up prereleases of the lowest patch (e.g. 3.14.0-beta.1
  // satisfies the request "3.14").
  if (/^\d+\.\d+\.x$/.test(trimmed)) {
    const base = trimmed.replace(/\.x$/, '');
    return allowPrereleases ? `>=${base}.0-0 <${nextMinor(base)}` : `~${base}.0`;
  }
  if (/^\d+\.x$/.test(trimmed)) {
    const major = trimmed.split('.')[0];
    return allowPrereleases
      ? `>=${major}.0.0-0 <${Number(major) + 1}.0.0-0`
      : `${major}.x`;
  }
  if (/^\d+\.\d+$/.test(trimmed)) {
    return allowPrereleases
      ? `>=${trimmed}.0-0 <${nextMinor(trimmed)}`
      : `~${trimmed}.0`;
  }
  if (/^\d+$/.test(trimmed)) {
    return allowPrereleases
      ? `>=${trimmed}.0.0-0 <${Number(trimmed) + 1}.0.0-0`
      : `${trimmed}.x`;
  }
  return trimmed;
}

function nextMinor(majorMinor: string): string {
  const [major, minor] = majorMinor.split('.').map(Number);
  return `${major}.${minor + 1}.0-0`;
}

export interface MatchOptions {
  versionSpec: string;
  arch: string;
  allowPrereleases: boolean;
}

export interface MatchResult {
  release: ManifestRelease;
  file: ManifestFile;
}

export function findMatchingRelease(
  manifest: ManifestRelease[],
  opts: MatchOptions
): MatchResult | undefined {
  const range = normalizeRange(opts.versionSpec, opts.allowPrereleases);
  const platform = getOSPlatform();
  const arch = getOSArch(opts.arch);
  const linuxInfo = IS_LINUX ? getLinuxOSReleaseInfo() : undefined;

  const candidates = manifest
    .filter(r => opts.allowPrereleases || r.stable)
    .filter(r =>
      semver.satisfies(r.version, range, {includePrerelease: opts.allowPrereleases})
    )
    .sort((a, b) => semver.rcompare(a.version, b.version));

  for (const release of candidates) {
    const file = pickFile(release.files, platform, arch, linuxInfo?.versionId);
    if (file) {
      return {release, file};
    }
  }
  return undefined;
}

function pickFile(
  files: ManifestFile[],
  platform: string,
  arch: string,
  linuxVersionId?: string
): ManifestFile | undefined {
  const matching = files.filter(
    f => f.platform === platform && f.arch === arch && !f.filename.includes('freethreaded')
  );
  if (matching.length === 0) return undefined;
  if (platform !== 'linux' || !linuxVersionId) {
    return matching[0];
  }
  // For linux, prefer an exact platform_version match, otherwise fall back to the
  // newest available (since glibc is typically forward-compatible from older to newer).
  const exact = matching.find(f => f.platform_version === linuxVersionId);
  if (exact) return exact;
  const sorted = [...matching].sort((a, b) => {
    const av = parseFloat(a.platform_version ?? '0');
    const bv = parseFloat(b.platform_version ?? '0');
    return bv - av;
  });
  const fallback = sorted.find(f => {
    const fv = parseFloat(f.platform_version ?? '0');
    const rv = parseFloat(linuxVersionId);
    return !Number.isNaN(fv) && !Number.isNaN(rv) && fv <= rv;
  });
  return fallback ?? sorted[0];
}
