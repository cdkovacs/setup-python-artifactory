import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as core from '@actions/core';

export const IS_WINDOWS = process.platform === 'win32';
export const IS_LINUX = process.platform === 'linux';
export const IS_MAC = process.platform === 'darwin';

export interface ManifestFile {
  filename: string;
  arch: string;
  platform: string;
  platform_version?: string;
  download_url: string;
}

export interface ManifestRelease {
  version: string;
  stable: boolean;
  release_url: string;
  files: ManifestFile[];
}

export function getOSPlatform(): string {
  if (IS_WINDOWS) return 'win32';
  if (IS_MAC) return 'darwin';
  return 'linux';
}

export function getOSArch(input?: string): string {
  if (input) return input;
  const arch = os.arch();
  if (arch === 'x64') return 'x64';
  if (arch === 'ia32') return 'x86';
  if (arch === 'arm64') return 'arm64';
  return arch;
}

export function getLinuxOSReleaseInfo(): {id: string; versionId: string} {
  try {
    const content = fs.readFileSync('/etc/os-release', 'utf8');
    const lines = content.split('\n');
    const fields: Record<string, string> = {};
    for (const line of lines) {
      const idx = line.indexOf('=');
      if (idx <= 0) continue;
      const key = line.slice(0, idx).trim();
      let value = line.slice(idx + 1).trim();
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.slice(1, -1);
      }
      fields[key] = value;
    }
    return {
      id: fields['ID'] ?? 'linux',
      versionId: fields['VERSION_ID'] ?? ''
    };
  } catch (err) {
    core.debug(`Could not read /etc/os-release: ${(err as Error).message}`);
    return {id: 'linux', versionId: ''};
  }
}

export function readPythonVersionFile(filePath: string): string {
  const absolute = path.isAbsolute(filePath)
    ? filePath
    : path.join(process.env.GITHUB_WORKSPACE ?? process.cwd(), filePath);
  if (!fs.existsSync(absolute)) {
    throw new Error(`python-version-file not found: ${absolute}`);
  }
  const raw = fs.readFileSync(absolute, 'utf8');
  const versions = parseVersionFile(raw, path.basename(absolute));
  if (versions.length === 0) {
    throw new Error(`No Python version found in ${absolute}`);
  }
  if (versions.length > 1) {
    core.warning(`Multiple versions found in ${absolute}; using the first: ${versions[0]}`);
  }
  return versions[0];
}

function parseVersionFile(content: string, filename: string): string[] {
  if (filename === 'pyproject.toml') {
    const match = content.match(/^\s*requires-python\s*=\s*["']([^"']+)["']/m);
    return match ? [match[1].trim()] : [];
  }
  if (filename === 'Pipfile') {
    const match = content.match(/^\s*python_(?:full_)?version\s*=\s*["']([^"']+)["']/m);
    return match ? [match[1].trim()] : [];
  }
  return content
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line && !line.startsWith('#'));
}
