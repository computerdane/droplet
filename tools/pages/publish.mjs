#!/usr/bin/env node
// Reconcile tested Pages builds without executing PR code in a privileged job.
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { limits, safeExtract } from './zip.mjs';

export const STATE_BRANCH = 'pages-state';
export const MARKER = '<!-- droplet-pages-preview -->';

export class GitHub {
  constructor(repository, token) { this.repository = repository; this.token = token; }
  async request(path, { data, method, raw = false, apiVersion = '2022-11-28' } = {}) {
    let url = `https://api.github.com/repos/${this.repository}${path}`;
    let headers = { Authorization: `Bearer ${this.token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': apiVersion, 'Content-Type': 'application/json' };
    let response;
    for (let redirects = 0; redirects < 5; redirects++) {
      response = await fetch(url, { method, headers, body: data === undefined ? undefined : JSON.stringify(data), redirect: 'manual', signal: AbortSignal.timeout(120000) });
      if (![301, 302, 303, 307, 308].includes(response.status)) break;
      const next = new URL(response.headers.get('location'), url);
      if (next.protocol !== 'https:') throw new Error('Non-HTTPS artifact redirect');
      if (next.origin !== new URL(url).origin) headers = { Accept: headers.Accept };
      await response.body?.cancel();
      url = next.href;
    }
    if (!response.ok) {
      await response.body?.cancel();
      const error = new Error(`GitHub request failed: ${response.status} ${path}`);
      error.status = response.status;
      throw error;
    }
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > limits.archive) throw new Error('GitHub response exceeds archive size limit');
      chunks.push(chunk);
    }
    const content = Buffer.concat(chunks);
    return raw ? content : JSON.parse(content.toString('utf8'));
  }
  async *pages(path, key, options = {}) {
    for (let page = 1; ; page++) {
      const response = await this.request(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`, options);
      const values = key ? response[key] : response;
      yield* values;
      if (values.length < 100) return;
    }
  }
}

export function nativeStackMembers(prs, stacks, repository, branch) {
  const current = new Map(prs.map(pr => [pr.number, pr]));
  const members = new Map();
  for (const stack of stacks) {
    if (stack.open !== true || stack.base?.ref !== branch || !Array.isArray(stack.pull_requests)) continue;
    // Merged layers may remain in stack history; remaining layers must have
    // been retargeted into a current, continuous chain rooted at main.
    const active = stack.pull_requests.filter(pr => !(pr.state === 'closed' && pr.merged_at));
    const chain = new Map();
    const refs = new Set([branch]);
    let expectedBase = branch;
    let parent = null;
    for (const layer of active) {
      const pr = current.get(layer.number);
      if (!pr || pr.state !== 'open' || layer.state !== 'open' || pr.head.repo?.full_name !== repository
          || pr.base.ref !== expectedBase || pr.head.ref !== layer.head?.ref || pr.head.sha !== layer.head?.sha
          || chain.has(pr.number) || refs.has(pr.head.ref)) break;
      chain.set(pr.number, { base: pr.base.ref, ref: pr.head.ref, sha: pr.head.sha, parent });
      refs.add(pr.head.ref);
      expectedBase = pr.head.ref;
      parent = pr.number;
    }
    if (chain.size === active.length) for (const [number, member] of chain) members.set(number, member);
  }
  return members;
}

export function eligiblePr(pr, repository, branch, stackMembers = new Map()) {
  if (!pr || pr.state !== 'open' || pr.head.repo?.full_name !== repository) return false;
  if (pr.base.ref === branch) return true;
  const layer = stackMembers.get(pr.number);
  return Boolean(layer && layer.base === pr.base.ref && layer.ref === pr.head.ref && layer.sha === pr.head.sha);
}

export async function previewCandidates(api, branch, comparisonCache = new Map()) {
  const prs = [];
  for await (const pr of api.pages('/pulls?state=open')) prs.push(pr);
  const stacks = [];
  if (prs.some(pr => pr.head.repo?.full_name === api.repository && pr.base.ref !== branch)) {
    try {
      for await (const stack of api.pages('/stacks', undefined, { apiVersion: '2026-03-10' })) stacks.push(stack);
    } catch (error) {
      // A partial paginated response cannot establish complete membership.
      stacks.length = 0;
      console.warn(`::warning::Native stack lookup unavailable; skipping stacked previews. Production and main-target PR previews continue. ${error.message}`);
    }
  }
  const members = nativeStackMembers(prs, stacks, api.repository, branch);
  const verified = new Map();
  const decisions = new Map();
  async function verify(number, seen = new Set()) {
    if (decisions.has(number)) return decisions.get(number);
    const member = members.get(number);
    if (!member || seen.has(number)) return false;
    seen.add(number);
    let valid = member.parent === null;
    if (member.parent !== null && await verify(member.parent, seen)) {
      const parentSha = members.get(member.parent).sha;
      const pair = `${parentSha}...${member.sha}`;
      if (!comparisonCache.has(pair)) {
        try {
          const result = await api.request(`/compare/${encodeURIComponent(parentSha)}...${encodeURIComponent(member.sha)}`);
          comparisonCache.set(pair, ['ahead', 'identical'].includes(result.status) || result.merge_base_commit?.sha === parentSha);
        } catch (error) {
          comparisonCache.set(pair, false);
          console.warn(`::warning::Cannot verify ancestry for stacked PR #${number}; its preview and dependent previews are skipped. ${error.message}`);
        }
      }
      valid = comparisonCache.get(pair);
    }
    decisions.set(number, valid);
    if (valid) verified.set(number, member);
    return valid;
  }
  for (const number of members.keys()) await verify(number);
  return new Map(prs.filter(pr => eligiblePr(pr, api.repository, branch, verified)).map(pr => [pr.number, pr]));
}

export async function successfulBuild(api, sha, event, number) {
  const query = new URLSearchParams({ head_sha: sha, event, status: 'success' });
  for await (const run of api.pages(`/actions/workflows/ci.yml/runs?${query}`, 'workflow_runs')) {
    if (run.head_sha !== sha || run.conclusion !== 'success' || run.event !== event || run.head_repository?.full_name !== api.repository) continue;
    if (number !== undefined && !run.pull_requests.some(pr => pr.number === number)) continue;
    const matching = [];
    for await (const artifact of api.pages(`/actions/runs/${run.id}/artifacts`, 'artifacts')) {
      if (artifact.name === 'web-site' && !artifact.expired) matching.push(artifact);
    }
    if (matching.length === 1) return { sha, run_id: run.id, artifact_id: matching[0].id };
  }
  return null;
}

function remove(path) { rmSync(path, { recursive: true, force: true }); }
function siteSize(path) {
  return readdirSync(path, { withFileTypes: true }).reduce((sum, entry) => sum + (entry.isDirectory() ? siteSize(join(path, entry.name)) : statSync(join(path, entry.name)).size), 0);
}

export async function reconcile(site, previous, targets, download) {
  const previews = join(site, 'previews');
  mkdirSync(previews, { recursive: true });
  for (const name of readdirSync(previews)) if (!(name in targets)) remove(join(previews, name));
  const manifest = Object.fromEntries(Object.entries(previous).filter(([key]) => key in targets));
  for (const [key, build] of Object.entries(targets)) {
    if (!build || JSON.stringify(manifest[key]) === JSON.stringify(build)) continue;
    const stage = mkdtempSync(join(tmpdir(), 'pages-build-'));
    try {
      safeExtract(await download(build.artifact_id), stage);
      if (key === 'production') {
        for (const name of readdirSync(site)) if (name !== 'previews') remove(join(site, name));
        cpSync(stage, site, { recursive: true });
      } else {
        remove(join(previews, key));
        cpSync(stage, join(previews, key), { recursive: true });
      }
    } finally { remove(stage); }
    manifest[key] = build;
  }
  writeFileSync(join(site, '.nojekyll'), '');
  if (siteSize(site) > limits.site) throw new Error(`Combined site exceeds ${limits.site} byte budget`);
  if (!existsSync(join(site, 'index.html'))) writeFileSync(join(site, 'index.html'), '<!doctype html><title>Droplet</title><p>Production build pending.</p>\n');
  return manifest;
}

function git(args, cwd = process.cwd()) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

export async function stateCheckout(api, state, source = process.cwd()) {
  try { await api.request(`/git/ref/heads/${STATE_BRANCH}`); }
  catch (error) {
    if (error.status !== 404) throw error;
    git(['worktree', 'add', '--detach', '--no-checkout', state, 'HEAD'], source);
    git(['symbolic-ref', 'HEAD', `refs/heads/${STATE_BRANCH}`], state);
    git(['read-tree', '--empty'], state);
    return;
  }
  git(['fetch', '--depth=1', 'origin', `refs/heads/${STATE_BRANCH}`], source);
  git(['worktree', 'add', '--detach', state, 'FETCH_HEAD'], source);
}

export async function prepare(api, state, output) {
  const repository = await api.request('');
  const branch = repository.default_branch;
  await stateCheckout(api, state);
  const manifestPath = join(state, 'manifest.json');
  let manifest = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')) : {};
  const mainSha = (await api.request(`/branches/${encodeURIComponent(branch)}`)).commit.sha;
  const targets = { production: await successfulBuild(api, mainSha, 'push') };
  // Commit ancestry is immutable: cache only exact SHA pairs within this run.
  const comparisonCache = new Map();
  for (const pr of (await previewCandidates(api, branch, comparisonCache)).values()) {
    targets[`pr-${pr.number}`] = await successfulBuild(api, pr.head.sha, 'pull_request', pr.number);
  }
  manifest = await reconcile(join(state, 'site'), manifest, targets, id => api.request(`/actions/artifacts/${id}/zip`, { raw: true }));
  // Recheck the entire current stack chain after downloads, not just each PR:
  // a lower layer changing or disappearing invalidates its dependent preview.
  const currentCandidates = await previewCandidates(api, branch, comparisonCache);
  for (const key of Object.keys(manifest)) {
    if (key === 'production') continue;
    const pr = currentCandidates.get(Number(key.slice(3)));
    if (!pr || (targets[key] && pr.head.sha !== targets[key].sha)) {
      remove(join(state, 'site', 'previews', key));
      delete manifest[key];
    }
  }
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  git(['config', 'user.name', 'github-actions[bot]'], state);
  git(['config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com'], state);
  git(['add', '--all'], state);
  if (git(['status', '--porcelain'], state).trim()) {
    git(['commit', '-m', 'Reconcile production and PR previews'], state);
    git(['push', 'origin', `HEAD:refs/heads/${STATE_BRANCH}`], state);
  }
  cpSync(join(state, 'site'), output, { recursive: true });
}

export async function comment(api, state, url) {
  const manifest = JSON.parse(readFileSync(join(state, 'manifest.json'), 'utf8'));
  for (const [key, build] of Object.entries(manifest)) {
    if (key === 'production') continue;
    const number = Number(key.slice(3));
    const pr = await api.request(`/pulls/${number}`);
    if (pr.state !== 'open') continue;
    const stale = pr.head.sha !== build.sha ? '\n\nA newer commit is awaiting a successful build.' : '';
    const body = `${MARKER}\n[Open live preview](${url.replace(/\/$/, '')}/previews/${key}/)\n\nDeployed commit: \`${build.sha}\`. [Tested CI build](https://github.com/${api.repository}/actions/runs/${build.run_id}).${stale}\n\nRun this tested commit in the desktop app:\n\n\`\`\`sh\nnix run github:${api.repository}/${build.sha}#droplet\n\`\`\`\n\nPublic preview; removed after this PR closes.`;
    let existing;
    for await (const item of api.pages(`/issues/${number}/comments`)) {
      if (item.user.login === 'github-actions[bot]' && item.body.includes(MARKER)) { existing = item; break; }
    }
    if (!existing) await api.request(`/issues/${number}/comments`, { data: { body }, method: 'POST' });
    else if (existing.body !== body) await api.request(`/issues/comments/${existing.id}`, { data: { body }, method: 'PATCH' });
  }
}

async function main() {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: { state: { type: 'string' }, output: { type: 'string' } } });
  if (!values.state || !['prepare', 'comment'].includes(positionals[0]) || (positionals[0] === 'prepare' && !values.output)) throw new Error('Usage: publish.mjs prepare|comment --state PATH [--output PATH]');
  if (!process.env.GH_REPOSITORY || !process.env.GH_TOKEN) throw new Error('GH_REPOSITORY and GH_TOKEN required');
  const api = new GitHub(process.env.GH_REPOSITORY, process.env.GH_TOKEN);
  if (positionals[0] === 'prepare') await prepare(api, resolve(values.state), resolve(values.output));
  else {
    if (!process.env.PAGES_URL) throw new Error('PAGES_URL required');
    await comment(api, resolve(values.state), process.env.PAGES_URL);
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main().catch(error => { console.error(error.message); process.exitCode = 1; });
