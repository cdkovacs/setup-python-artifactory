import * as core from '@actions/core';
import * as httpm from '@actions/http-client';
import {BearerCredentialHandler} from '@actions/http-client/lib/auth';

const USER_AGENT = 'setup-python-artifactory';

export interface ArtifactoryConfig {
  baseUrl: string;
  repo: string;
  token: string;
  manifestPath: string;
}

export function buildConfig(): ArtifactoryConfig {
  const baseUrl = core.getInput('artifactory-url', {required: true}).replace(/\/+$/, '');
  const repo = core.getInput('artifactory-repo', {required: true});
  const token = core.getInput('artifactory-token', {required: true});
  const manifestPath = core.getInput('manifest-path') || 'versions-manifest.json';
  // The token must be masked so it doesn't leak through error messages or
  // ::debug:: lines if a downstream library logs request URLs.
  core.setSecret(token);
  return {baseUrl, repo, token, manifestPath};
}

export function buildClient(token: string): httpm.HttpClient {
  return new httpm.HttpClient(USER_AGENT, [new BearerCredentialHandler(token)], {
    allowRetries: true,
    maxRetries: 3
  });
}

export function manifestUrl(cfg: ArtifactoryConfig): string {
  return `${cfg.baseUrl}/${cfg.repo}/${cfg.manifestPath}`;
}

export function rewriteDownloadUrl(cfg: ArtifactoryConfig, filename: string): string {
  return `${cfg.baseUrl}/${cfg.repo}/${filename}`;
}
