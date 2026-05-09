import * as path from 'path';
import * as core from '@actions/core';
import * as tc from '@actions/tool-cache';
import {buildConfig} from './http';
import {fetchManifest, findMatchingRelease} from './manifest';
import {installFromArtifactory, pythonExecutable} from './install-python';
import {getOSArch, IS_WINDOWS, readPythonVersionFile} from './utils';

async function run(): Promise<void> {
  try {
    const versionSpec = resolveVersionSpec();
    const arch = getOSArch(core.getInput('architecture'));
    const checkLatest = core.getBooleanInput('check-latest');
    const allowPrereleases = core.getBooleanInput('allow-prereleases');
    const updateEnvironment = core.getBooleanInput('update-environment');

    core.info(`Resolving Python version: ${versionSpec} (arch=${arch})`);

    const cfg = buildConfig();
    const manifest = await fetchManifest(cfg);
    const match = findMatchingRelease(manifest, {versionSpec, arch, allowPrereleases});
    if (!match) {
      throw new Error(
        `No Python release in the Artifactory manifest matches '${versionSpec}' for this runner ` +
          `(platform=${process.platform}, arch=${arch}). ` +
          `Make sure the sync job has uploaded the binaries you need.`
      );
    }
    core.info(
      `Matched manifest entry: version=${match.release.version} file=${match.file.filename}`
    );

    const cached = !checkLatest ? tc.find('Python', match.release.version, arch) : '';
    let installDir: string;
    let pythonPath: string;
    let cacheHit = false;

    if (cached) {
      core.info(`Using cached Python ${match.release.version} at ${cached}`);
      installDir = cached;
      pythonPath = pythonExecutable(installDir);
      cacheHit = true;
    } else {
      const installed = await installFromArtifactory(cfg, match.release, match.file, arch);
      installDir = installed.installDir;
      pythonPath = installed.pythonPath;
    }

    if (updateEnvironment) {
      applyEnvironment(installDir);
    }

    core.setOutput('python-version', match.release.version);
    core.setOutput('python-path', pythonPath);
    core.setOutput('cache-hit', cacheHit);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    core.setFailed(message);
  }
}

function resolveVersionSpec(): string {
  const direct = core.getInput('python-version');
  if (direct) return direct.split(/\r?\n/)[0].trim();
  const file = core.getInput('python-version-file');
  if (file) return readPythonVersionFile(file);
  for (const candidate of ['.python-version', 'pyproject.toml', 'Pipfile']) {
    try {
      const value = readPythonVersionFile(candidate);
      core.info(`Using version from ${candidate}: ${value}`);
      return value;
    } catch {
      // try next
    }
  }
  throw new Error(
    'No python-version specified and no .python-version / pyproject.toml / Pipfile found.'
  );
}

function applyEnvironment(installDir: string): void {
  core.exportVariable('pythonLocation', installDir);
  core.exportVariable('Python_ROOT_DIR', installDir);
  core.exportVariable('Python2_ROOT_DIR', installDir);
  core.exportVariable('Python3_ROOT_DIR', installDir);

  const binDir = IS_WINDOWS ? installDir : path.join(installDir, 'bin');
  core.addPath(installDir);
  core.addPath(binDir);

  if (!IS_WINDOWS) {
    const pkgConfig = path.join(installDir, 'lib', 'pkgconfig');
    const existing = process.env.PKG_CONFIG_PATH;
    core.exportVariable(
      'PKG_CONFIG_PATH',
      existing ? `${pkgConfig}:${existing}` : pkgConfig
    );
  }
}

run();
