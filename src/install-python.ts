import * as path from 'path';
import * as fs from 'fs';
import * as core from '@actions/core';
import * as exec from '@actions/exec';
import * as tc from '@actions/tool-cache';
import {ArtifactoryConfig, rewriteDownloadUrl} from './http';
import {ManifestFile, ManifestRelease, IS_WINDOWS} from './utils';

export interface InstalledPython {
  version: string;
  installDir: string;
  pythonPath: string;
}

export async function installFromArtifactory(
  cfg: ArtifactoryConfig,
  release: ManifestRelease,
  file: ManifestFile,
  arch: string
): Promise<InstalledPython> {
  const downloadUrl = rewriteDownloadUrl(cfg, file.filename);
  core.info(`Downloading ${file.filename} from ${downloadUrl}`);

  const authHeader = `Bearer ${cfg.token}`;
  const archivePath = await tc.downloadTool(downloadUrl, undefined, authHeader);
  core.info(`Downloaded archive to ${archivePath}`);

  const extracted = IS_WINDOWS
    ? await tc.extractZip(archivePath)
    : await tc.extractTar(archivePath);
  core.info(`Extracted archive to ${extracted}`);

  await runSetupScript(extracted);

  const installDir = locateToolCacheDir(release.version, arch);
  if (!installDir) {
    throw new Error(
      `Setup script ran but Python ${release.version} was not registered in the tool cache.`
    );
  }

  const pythonPath = pythonExecutable(installDir);
  return {version: release.version, installDir, pythonPath};
}

async function runSetupScript(workingDirectory: string): Promise<void> {
  if (IS_WINDOWS) {
    const script = path.join(workingDirectory, 'setup.ps1');
    if (!fs.existsSync(script)) {
      throw new Error(`setup.ps1 missing in archive at ${script}`);
    }
    await exec.exec('powershell', ['-NoProfile', '-File', script], {
      cwd: workingDirectory
    });
    return;
  }
  const script = path.join(workingDirectory, 'setup.sh');
  if (!fs.existsSync(script)) {
    throw new Error(`setup.sh missing in archive at ${script}`);
  }
  fs.chmodSync(script, 0o755);
  await exec.exec('bash', [script], {cwd: workingDirectory});
}

function locateToolCacheDir(version: string, arch: string): string | undefined {
  const dir = tc.find('Python', version, arch);
  return dir || undefined;
}

export function pythonExecutable(installDir: string): string {
  if (IS_WINDOWS) {
    return path.join(installDir, 'python.exe');
  }
  return path.join(installDir, 'bin', 'python3');
}
