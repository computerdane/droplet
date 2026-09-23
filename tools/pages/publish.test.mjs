import assert from 'node:assert/strict';
import { test } from 'node:test';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { deflateRawSync } from 'node:zlib';
import { crc32, limits, safeExtract } from './zip.mjs';
import { eligiblePr, GitHub, nativeStackMembers, previewCandidates, reconcile, stateCheckout, successfulBuild } from './publish.mjs';

function archive(entries, { deflate = false, mode = 0o100644 } = {}) {
  const local = [];
  const central = [];
  let offset = 0;
  for (const [name, raw] of Object.entries(entries)) {
    const content = Buffer.from(raw);
    const compressed = deflate ? deflateRawSync(content) : content;
    const filename = Buffer.from(name);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50);
    header.writeUInt16LE(deflate ? 8 : 0, 8);
    header.writeUInt32LE(crc32(content), 14);
    header.writeUInt32LE(compressed.length, 18);
    header.writeUInt32LE(content.length, 22);
    header.writeUInt16LE(filename.length, 26);
    const directory = Buffer.alloc(46);
    directory.writeUInt32LE(0x02014b50);
    directory.writeUInt16LE(deflate ? 8 : 0, 10);
    directory.writeUInt32LE(crc32(content), 16);
    directory.writeUInt32LE(compressed.length, 20);
    directory.writeUInt32LE(content.length, 24);
    directory.writeUInt16LE(filename.length, 28);
    directory.writeUInt32LE((mode << 16) >>> 0, 38);
    directory.writeUInt32LE(offset, 42);
    local.push(header, filename, compressed);
    central.push(directory, filename);
    offset += header.length + filename.length + compressed.length;
  }
  const directory = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(Object.keys(entries).length, 8);
  end.writeUInt16LE(Object.keys(entries).length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, end]);
}
function temporary(t) {
  const path = mkdtempSync(join(tmpdir(), 'pages-test-'));
  t.after(() => rmSync(path, { recursive: true, force: true }));
  return path;
}
const build = (sha, id = 1) => ({ sha, run_id: id, artifact_id: id });

test('extracts stored and deflated exports', t => {
  for (const deflate of [false, true]) {
    const path = temporary(t);
    safeExtract(archive({ 'index.html': 'hello', 'assets/test.wasm': 'wasm' }, { deflate }), path);
    assert.equal(readFileSync(join(path, 'assets/test.wasm'), 'utf8'), 'wasm');
  }
});

test('accepts bounded ZIP64 archives', t => {
  const original = archive({ 'index.html': 'zip64' });
  const end = original.subarray(original.length - 22);
  const zip64 = Buffer.alloc(56);
  zip64.writeUInt32LE(0x06064b50);
  zip64.writeBigUInt64LE(44n, 4);
  zip64.writeBigUInt64LE(1n, 24);
  zip64.writeBigUInt64LE(1n, 32);
  zip64.writeBigUInt64LE(BigInt(end.readUInt32LE(12)), 40);
  zip64.writeBigUInt64LE(BigInt(end.readUInt32LE(16)), 48);
  const locator = Buffer.alloc(20);
  locator.writeUInt32LE(0x07064b50);
  locator.writeBigUInt64LE(BigInt(original.length - 22), 8);
  locator.writeUInt32LE(1, 16);
  end.writeUInt16LE(0xffff, 10);
  end.writeUInt32LE(0xffffffff, 16);
  const path = temporary(t);
  safeExtract(Buffer.concat([original.subarray(0, -22), zip64, locator, end]), path);
  assert.equal(readFileSync(join(path, 'index.html'), 'utf8'), 'zip64');
});

test('rejects traversal, hidden/reserved paths, and symlinks before writing', t => {
  for (const name of ['../escape', '/absolute', 'a/../../escape', 'a\\..\\escape', '.git/config', 'previews/pr-2/index.html', 'a//b']) {
    const path = temporary(t);
    assert.throws(() => safeExtract(archive({ 'index.html': 'ok', [name]: 'bad' }), path));
    assert.deepEqual(readdirSync(path), []);
  }
  assert.throws(() => safeExtract(archive({ 'index.html': '../outside' }, { mode: 0o120777 }), temporary(t)));
});

test('rejects missing index, size budget and corrupt checksums', t => {
  assert.throws(() => safeExtract(archive({ 'nested/index.html': 'ok' }), temporary(t)));
  const bytes = archive({ 'index.html': 'four' });
  const previous = limits.build;
  limits.build = 3;
  try { assert.throws(() => safeExtract(bytes, temporary(t))); }
  finally { limits.build = previous; }
  bytes[40] ^= 1;
  assert.throws(() => safeExtract(bytes, temporary(t)), /checksum/);
});

test('strips GitHub token on artifact storage redirects', async t => {
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    calls.push({ url, options });
    if (calls.length === 1) return new Response(null, { status: 302, headers: { location: 'https://storage.example/artifact.zip' } });
    return new Response(Buffer.from('artifact'));
  });
  assert.equal((await new GitHub('owner/repo', 'secret').request('/actions/artifacts/1/zip', { raw: true })).toString(), 'artifact');
  assert.equal(calls[0].options.headers.Authorization, 'Bearer secret');
  assert.equal(calls[1].options.headers.Authorization, undefined);
});

test('reconciles all previews, preserves production, and removes closed PRs', async t => {
  const site = temporary(t);
  const download = async id => archive({ 'index.html': String(id), 'index.wasm': 'wasm' });
  let manifest = await reconcile(site, {}, { production: build('main', 1), 'pr-1': build('first', 2), 'pr-2': build('second', 3) }, download);
  manifest = await reconcile(site, manifest, { production: null, 'pr-1': build('new', 4), 'pr-2': null }, download);
  assert.equal(readFileSync(join(site, 'index.html'), 'utf8'), '1');
  assert.equal(readFileSync(join(site, 'previews/pr-1/index.html'), 'utf8'), '4');
  assert.equal(readFileSync(join(site, 'previews/pr-2/index.html'), 'utf8'), '3');
  manifest = await reconcile(site, manifest, { production: build('main2', 5), 'pr-2': null }, download);
  assert.equal(existsSync(join(site, 'previews/pr-1')), false);
  assert.equal('pr-1' in manifest, false);
  assert.equal(readFileSync(join(site, 'previews/pr-2/index.html'), 'utf8'), '3');
  assert.equal(readFileSync(join(site, 'index.html'), 'utf8'), '5');
});

test('retains published build through artifact expiry and avoids redownload', async t => {
  const site = temporary(t);
  const targets = { production: build('main') };
  const manifest = await reconcile(site, {}, targets, async () => archive({ 'index.html': 'ok' }));
  const noDownload = async () => assert.fail('Unnecessary download');
  await reconcile(site, manifest, targets, noDownload);
  await reconcile(site, manifest, { production: null }, noDownload);
  assert.equal(readFileSync(join(site, 'index.html'), 'utf8'), 'ok');
});

test('invalid replacement cannot delete last good production build', async t => {
  const site = temporary(t);
  const manifest = await reconcile(site, {}, { production: build('old') }, async () => archive({ 'index.html': 'old' }));
  await assert.rejects(reconcile(site, manifest, { production: build('new', 2) }, async () => archive({ '../escape': 'bad' })));
  assert.equal(readFileSync(join(site, 'index.html'), 'utf8'), 'old');
});

test('enforces total site size budget', async t => {
  const previous = limits.site;
  limits.site = 1;
  try { await assert.rejects(reconcile(temporary(t), {}, { production: build('main') }, async () => archive({ 'index.html': 'large' }))); }
  finally { limits.site = previous; }
});

test('only open same-repository PRs targeting main qualify', () => {
  const pr = { state: 'open', base: { ref: 'main' }, head: { repo: { full_name: 'owner/repo' } } };
  assert.equal(eligiblePr(pr, 'owner/repo', 'main'), true);
  assert.equal(eligiblePr(pr, 'other/repo', 'main'), false);
  assert.equal(eligiblePr({ ...pr, state: 'closed' }, 'owner/repo', 'main'), false);
  assert.equal(eligiblePr(pr, 'owner/repo', 'other'), false);
});

function stackFixture() {
  const prs = ['model', 'api', 'ui'].map((ref, index, refs) => ({
    number: index + 10, state: 'open',
    base: { ref: index === 0 ? 'main' : refs[index - 1] },
    head: { ref, sha: `sha-${ref}`, repo: { full_name: 'owner/repo' } },
  }));
  const stack = { open: true, base: { ref: 'main' }, pull_requests: prs.map(pr => ({ number: pr.number, state: pr.state, merged_at: null, head: { ref: pr.head.ref, sha: pr.head.sha } })) };
  return { prs, stack };
}

test('native stack layers qualify only through their registered current chain', () => {
  const { prs, stack } = stackFixture();
  const members = nativeStackMembers(prs, [stack], 'owner/repo', 'main');
  assert.equal(members.size, 3);
  for (const pr of prs) assert.equal(eligiblePr(pr, 'owner/repo', 'main', members), true);
  assert.equal(eligiblePr(prs[1], 'owner/repo', 'main'), false);
  assert.equal(eligiblePr({ ...prs[1], number: 99 }, 'owner/repo', 'main', members), false);
  const changed = structuredClone(prs[1]);
  changed.head.sha = 'new-sha';
  assert.equal(eligiblePr(changed, 'owner/repo', 'main', members), false);
});

test('stale heads, unrelated bases, forks, and broken native chains reject upper layers', () => {
  const mutations = [
    ({ prs }) => { prs[0].head.sha = 'new-lower-sha'; },
    ({ prs }) => { prs[1].base.ref = 'unrelated'; },
    ({ prs }) => { prs[1].head.repo.full_name = 'fork/repo'; },
    ({ prs }) => { prs[0].state = 'closed'; },
    ({ stack }) => { stack.base.ref = 'unrelated'; },
    ({ stack }) => { stack.open = false; },
    ({ stack }) => { stack.pull_requests[1].head.ref = 'stale-ref'; },
    ({ stack }) => { stack.pull_requests.push(stack.pull_requests[0]); },
  ];
  for (const mutate of mutations) {
    const fixture = stackFixture();
    mutate(fixture);
    const members = nativeStackMembers(fixture.prs, [fixture.stack], 'owner/repo', 'main');
    assert.equal(eligiblePr(fixture.prs[2], 'owner/repo', 'main', members), false);
  }
});

test('remaining native stack layers qualify after merged bottom retargets', () => {
  const { prs, stack } = stackFixture();
  stack.pull_requests[0].state = 'closed';
  stack.pull_requests[0].merged_at = '2026-09-23T00:00:00Z';
  prs.shift();
  prs[0].base.ref = 'main';
  const members = nativeStackMembers(prs, [stack], 'owner/repo', 'main');
  assert.equal(members.size, 2);
  assert.equal(eligiblePr(prs[1], 'owner/repo', 'main', members), true);
});

test('native stack lookup uses current API version', async t => {
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    calls.push({ url, options });
    return Response.json([]);
  });
  const api = new GitHub('owner/repo', 'secret');
  for await (const _stack of api.pages('/stacks', undefined, { apiVersion: '2026-03-10' })) assert.fail('Unexpected stack');
  assert.equal(calls[0].options.headers['X-GitHub-Api-Version'], '2026-03-10');
});

test('stack API failure preserves ordinary candidates and rejects partial stack data', async t => {
  const { prs, stack } = stackFixture();
  const warnings = [];
  t.mock.method(console, 'warn', message => warnings.push(message));
  const api = {
    repository: 'owner/repo',
    async *pages(path, _key, options) {
      if (path.startsWith('/pulls')) { yield* prs; return; }
      assert.equal(options.apiVersion, '2026-03-10');
      yield stack;
      throw new Error('stack API unavailable');
    },
  };
  const candidates = await previewCandidates(api, 'main');
  assert.deepEqual([...candidates.keys()], [10]);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /skipping stacked previews/);
});

function stackApi(fixture, compare) {
  return {
    repository: 'owner/repo',
    async *pages(path) {
      if (path.startsWith('/pulls')) yield* fixture.prs;
      else if (path === '/stacks') yield fixture.stack;
      else assert.fail(`Unexpected API path: ${path}`);
    },
    async request(path) {
      assert.match(path, /^\/compare\//);
      return compare(path);
    },
  };
}

test('eligible stacked previews verify every parent ancestry and cache exact SHA pairs', async () => {
  const calls = [];
  const api = stackApi(stackFixture(), path => { calls.push(path); return { status: 'ahead' }; });
  const cache = new Map();
  assert.deepEqual([...(await previewCandidates(api, 'main', cache)).keys()], [10, 11, 12]);
  assert.deepEqual([...(await previewCandidates(api, 'main', cache)).keys()], [10, 11, 12]);
  assert.deepEqual(calls, ['/compare/sha-model...sha-api', '/compare/sha-api...sha-ui']);
});

test('post-download lower push invalidates unchanged upper preview despite fresh stack metadata', async () => {
  const fixture = stackFixture();
  const calls = [];
  const api = stackApi(fixture, path => {
    calls.push(path);
    return path.includes('new-model') ? { status: 'diverged', merge_base_commit: { sha: 'old-ancestor' } } : { status: 'ahead' };
  });
  const cache = new Map();
  assert.deepEqual([...(await previewCandidates(api, 'main', cache)).keys()], [10, 11, 12]);
  fixture.prs[0].head.sha = 'new-model';
  fixture.stack.pull_requests[0].head.sha = 'new-model';
  assert.deepEqual([...(await previewCandidates(api, 'main', cache)).keys()], [10]);
  assert.deepEqual(calls, ['/compare/sha-model...sha-api', '/compare/sha-api...sha-ui', '/compare/new-model...sha-api']);
});

test('upper ancestry failure preserves verified lower layers and fails closed on API errors', async t => {
  const warnings = [];
  t.mock.method(console, 'warn', message => warnings.push(message));
  const api = stackApi(stackFixture(), path => {
    if (path.endsWith('sha-ui')) throw new Error('GitHub compare unavailable');
    return { status: 'ahead' };
  });
  assert.deepEqual([...(await previewCandidates(api, 'main')).keys()], [10, 11]);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /Cannot verify ancestry for stacked PR #12/);
});

test('ancestry allows identical/parent merge-base and rejects behind or divergent commits', async () => {
  for (const status of ['identical', 'ahead', 'behind', 'diverged']) {
    const api = stackApi(stackFixture(), () => ({ status, merge_base_commit: { sha: 'other' } }));
    const expected = ['identical', 'ahead'].includes(status) ? [10, 11, 12] : [10];
    assert.deepEqual([...(await previewCandidates(api, 'main')).keys()], expected);
  }
  const api = stackApi(stackFixture(), path => ({ merge_base_commit: { sha: path.slice('/compare/'.length).split('...')[0] } }));
  assert.deepEqual([...(await previewCandidates(api, 'main')).keys()], [10, 11, 12]);
});

test('rejects stale, wrong PR, failed, foreign runs and expired artifacts', async () => {
  const good = { id: 6, head_sha: 'current', event: 'pull_request', conclusion: 'success', head_repository: { full_name: 'owner/repo' }, pull_requests: [{ number: 42 }] };
  const candidates = [{ ...good, id: 1, head_sha: 'stale' }, { ...good, id: 2, pull_requests: [{ number: 43 }] }, { ...good, id: 3, conclusion: 'failure' }, { ...good, id: 4, head_repository: { full_name: 'fork/repo' } }, { ...good, id: 5 }, good];
  const api = {
    repository: 'owner/repo',
    async *pages(path, key) {
      if (key === 'workflow_runs') yield* candidates;
      else { const id = Number(path.split('/')[3]); yield { name: 'web-site', id, expired: id === 5 }; }
    },
  };
  assert.deepEqual(await successfulBuild(api, 'current', 'pull_request', 42), build('current', 6));
});

test('bootstrap creates orphan state branch without disturbing source', async t => {
  const root = temporary(t);
  const source = join(root, 'source');
  const state = join(root, 'state');
  mkdirSync(source);
  const git = (args, cwd = source) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git(['init']);
  git(['config', 'user.name', 'Test']);
  git(['config', 'user.email', 'test@example.com']);
  git(['config', 'commit.gpgsign', 'false']);
  writeFileSync(join(source, 'source.txt'), 'source');
  git(['add', '.']);
  git(['commit', '-m', 'source']);
  const head = git(['rev-parse', 'HEAD']);
  await stateCheckout({ async request() { throw Object.assign(new Error('Not found'), { status: 404 }); } }, state, source);
  assert.deepEqual(readdirSync(state), ['.git']);
  writeFileSync(join(state, 'manifest.json'), '{}');
  git(['add', '.'], state);
  git(['commit', '-m', 'state'], state);
  assert.equal(git(['rev-list', '--count', 'HEAD'], state), '1');
  assert.equal(git(['rev-parse', 'HEAD']), head);
  assert.equal(readFileSync(join(source, 'source.txt'), 'utf8'), 'source');
  const remote = join(root, 'remote.git');
  git(['init', '--bare', remote]);
  git(['remote', 'add', 'origin', remote]);
  git(['push', 'origin', 'HEAD:refs/heads/pages-state'], state);
  git(['worktree', 'remove', state]);
  const restored = join(root, 'restored');
  await stateCheckout({ async request() { return {}; } }, restored, source);
  assert.equal(readFileSync(join(restored, 'manifest.json'), 'utf8'), '{}');
});
