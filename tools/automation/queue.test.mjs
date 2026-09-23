import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { approval, scopeHash, reply, claim, checkpoint, checkJob, loadState, saveState, parseArgs, GitHub, sync, LABELS,
  normalizePaths, pathsOverlap, reconcile, stack } from './queue.mjs';

const policy = { approvers: [{ login: 'owner', id: 7 }], max_repair_attempts: 3,
  max_active_issues: 1, max_open_prs: 3, default_branch: 'main' };
const issue = { number: 12, state: 'open', title: 'Fix loading', body: 'Reproduce with fixture', labels: [] };
const comment = (id = 1, body = '/approve', extra = {}) => ({ id, body, user: { id: 7 },
  created_at: '2026-09-23T12:00:00Z', updated_at: '2026-09-23T12:00:00Z',
  html_url: `https://github.com/x/y/issues/12#issuecomment-${id}`, ...extra });
const decide = (comments, extra = {}) => approval(extra.issue || issue, comments, extra.events || [], extra.edited, policy);
function temp(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'droplet-queue-test-'));
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}

test('only the human account can approve, regardless of ready labels', () => {
  const labeled = { ...issue, labels: [{ name: 'ready' }] };
  assert.equal(decide([], { issue: labeled }).approved, false);
  assert.equal(decide([comment(1, '/approve', { user: { id: 99 } })], { issue: labeled }).approved, false);
  assert.equal(decide([comment()]).approved, true);
});

test('commands must be entire comments, not quoted or embedded instructions', () => {
  for (const body of ['Please /approve', '> /approve', '```\n/approve\n```', '/approve\nAlso change everything']) {
    assert.equal(decide([comment(1, body)]).approved, false);
  }
});

test('latest hold wins until a new unedited approval; edited approval fails closed', () => {
  const comments = [comment(), comment(2, '/hold')];
  assert.equal(decide(comments).approved, false);
  comments.push(comment(3));
  assert.equal(decide(comments.toReversed()).approved, true);
  comments.push(comment(4, '/approve', { updated_at: '2026-09-23T12:01:00Z' }));
  assert.equal(decide(comments).approved, false);
});

test('questions neither approve nor revoke implementation', () => {
  const question = comment(2, 'Can you explain this report?');
  assert.equal(decide([question]).approved, false);
  assert.equal(decide([comment(), question]).approved, true);
});

test('question issues cannot be approved even with a human /approve and ready label', () => {
  const questionIssue = { ...issue, labels: [{ name: 'question' }, { name: 'ready' }] };
  assert.match(decide([comment()], { issue: questionIssue }).reason, /discussion-only/);
  assert.equal(decide([comment()], { issue: questionIssue }).approved, false);
  assert.ok(LABELS.question);
});

test('scope edits, renames and reopen events require new approval, labels do not', () => {
  assert.equal(decide([comment()], { edited: '2026-09-23T12:00:00Z' }).approved, false);
  for (const event of ['renamed', 'closed', 'reopened']) {
    assert.equal(decide([comment()], { events: [{ event, created_at: '2026-09-23T12:01:00Z' }] }).approved, false);
  }
  assert.equal(decide([comment()], { edited: '2026-09-23T11:00:00Z' }).approved, true);
  assert.equal(decide([comment()], { events: [{ event: 'labeled', created_at: '2026-09-23T13:00:00Z' }] }).approved, true);
  assert.equal(decide([comment()], { issue: { ...issue, state: 'closed' } }).approved, false);
  assert.notEqual(scopeHash(issue), scopeHash({ ...issue, body: 'New scope' }));
});

class FakeGitHub {
  constructor(comments = [], allowed = true) {
    this.comments = comments; this.allowed = allowed; this.mutations = []; this.policy = policy;
    this.issueValue = structuredClone(issue);
  }
  worker() { return { id: 99 }; }
  endpoint(suffix) { return suffix; }
  api(endpoint, { method = 'GET', data } = {}) {
    if (method === 'GET') return this.comments;
    this.mutations.push({ endpoint, data });
    const posted = comment(100, data.body, { user: { id: 99 } });
    this.comments.push(posted);
    return posted;
  }
  issue() { return { issue: structuredClone(this.issueValue), decision: { approved: this.allowed, reason: 'held', comment_id: 1, scope: 'abc' } }; }
  issues() { return [issue]; }
  pulls() { return []; }
  labels(value, desired) { this.mutations.push({ number: value.number, desired }); }
}

test('questions on unapproved issues receive retry-safe answers', () => {
  const github = new FakeGitHub([comment(5, 'Why does this happen?')], false);
  assert.equal(reply(github, 12, 5, 'Here is the evidence.').already_replied, false);
  assert.equal(reply(github, 12, 5, 'Here is the evidence.').already_replied, true);
  assert.equal(github.mutations.length, 1);
});

test('edited question can receive a new answer without replying to bot comments', () => {
  const source = comment(5, 'Why?');
  const github = new FakeGitHub([source]);
  reply(github, 12, 5, 'Because...');
  source.updated_at = '2026-09-23T13:00:00Z';
  reply(github, 12, 5, 'Updated explanation');
  assert.equal(github.mutations.length, 2);
  assert.throws(() => reply(github, 12, 100, 'Keep going'), /maintainer comment/);
});

test('issue-body question receives one answer per title/body version', () => {
  const github = new FakeGitHub();
  github.issueValue = { ...issue, user: { id: 7 }, labels: [{ name: 'question' }] };
  assert.equal(reply(github, 12, undefined, 'Initial answer', { issueBody: true }).already_replied, false);
  assert.equal(reply(github, 12, undefined, 'Initial answer', { issueBody: true }).already_replied, true);
  github.issueValue.body = 'A substantively updated question';
  assert.equal(reply(github, 12, undefined, 'Updated answer', { issueBody: true }).already_replied, false);
  assert.equal(github.mutations.length, 2);
  assert.match(github.mutations[0].data.body, new RegExp(`droplet-reply:issue-body:${scopeHash(issue)}`));
});

test('issue-body replies reject closed, non-question, and non-maintainer issues and empty text', () => {
  const github = new FakeGitHub();
  github.issueValue = { ...issue, user: { id: 7 }, labels: [{ name: 'question' }] };
  assert.throws(() => reply(github, 12, undefined, ' ', { issueBody: true }), /empty/);
  for (const change of [{ state: 'closed' }, { labels: [] }, { user: { id: 99 } }]) {
    github.issueValue = { ...issue, user: { id: 7 }, labels: [{ name: 'question' }], ...change };
    assert.throws(() => reply(github, 12, undefined, 'Answer', { issueBody: true }), /open question issue authored/);
  }
  assert.equal(github.mutations.length, 0);
  github.issue = () => { throw new Error('Approval commands belong on an issue, not a PR'); };
  assert.throws(() => reply(github, 12, undefined, 'Answer', { issueBody: true }), /not a PR/);
});

test('question issue cannot be claimed even after human approval', () => temp(root => {
  const github = new FakeGitHub([comment()]);
  github.issueValue = { ...issue, labels: [{ name: 'question' }] };
  github.issue = () => ({ issue: github.issueValue,
    decision: approval(github.issueValue, github.comments, [], undefined, policy) });
  assert.throws(() => claim(github, 12, root, () => assert.fail('executed git')), /discussion-only/);
  assert.deepEqual(loadState(root), { jobs: {} });
}));

test('unapproved claim cannot execute git or create a worktree', () => temp(root => {
  assert.throws(() => claim(new FakeGitHub([], false), 12, root, () => assert.fail('executed git')), /held/);
  assert.deepEqual(loadState(root), { jobs: {} });
}));

test('active issue limit and exhausted attempt prevent dispatch', () => temp(root => {
  const noGit = () => assert.fail('executed git');
  saveState({ jobs: { 3: { phase: 'working' } } }, root);
  assert.throws(() => claim(new FakeGitHub(), 12, root, noGit), /Active issue limit/);
  saveState({ jobs: { 12: { phase: 'blocked', approval: { comment_id: 1 } } } }, root);
  assert.throws(() => claim(new FakeGitHub(), 12, root, noGit), /new human \/approve/);
}));

test('changed scope must be replanned before further work', () => temp(root => {
  saveState({ jobs: { 12: { phase: 'working', approval: { scope: 'old' } } } }, root);
  assert.throws(() => checkJob(new FakeGitHub(), 12, root), /scope changed/);
}));

test('check cannot authorize implementation before a successful claim', () => temp(root => {
  assert.throws(() => checkJob(new FakeGitHub(), 12, root), /Claim the issue/);
}));

test('checkpoint still works after hold, and repair limit blocks the job', () => temp(root => {
  saveState({ jobs: { 12: { phase: 'working', repair_attempts: 2 } } }, root);
  checkpoint(new FakeGitHub([], false), parseArgs(['checkpoint', '12', '--repair', '--session', 'session-1']), root);
  const job = loadState(root).jobs[12];
  assert.equal(job.phase, 'blocked');
  assert.equal(job.session, 'session-1');
}));

test('worker must not use the human approver identity', () => {
  const github = new GitHub({ ...policy, repository: 'x/y' }, () => JSON.stringify({ id: 7 }));
  assert.throws(() => github.worker(), /approver/);
});

test('approval reconciliation removes stale authorization display', () => {
  const github = new FakeGitHub([], false);
  sync(github);
  assert.deepEqual(github.mutations, [{ number: 12, desired: 'needs-approval' }]);
});

test('question label sync clears workflow state labels and preserves question', () => {
  const github = new FakeGitHub();
  github.issueValue.labels = [{ name: 'question' }, { name: 'needs-approval' }, { name: 'ready' }];
  sync(github);
  assert.deepEqual(github.mutations, [{ number: 12, desired: null }]);
  const deleted = [];
  const client = new GitHub({ ...policy, repository: 'x/y' }, args => {
    deleted.push(args);
    return '';
  });
  client.labels(github.issueValue, null);
  assert.deepEqual(deleted.map(args => args.at(-1)).sort(), [
    'repos/x/y/issues/12/labels/needs-approval', 'repos/x/y/issues/12/labels/ready',
  ]);
});

test('CLI rejects invalid identifiers and missing options before mutation', () => {
  for (const args of [['claim', '-1'], ['claim', '1;echo bad'], ['reply', '1'], ['watch'], ['watch', '--since', 'a', '--seconds', '0']]) {
    assert.throws(() => parseArgs(args));
  }
  assert.equal(parseArgs(['reply', '12', '--issue-body', '--body-file', 'answer.txt'])['issue-body'], true);
  assert.equal(parseArgs(['reply', '12', '--comment', '5', '--body-file', 'answer.txt']).comment, 5);
  for (const args of [
    ['reply', '12', '--issue-body', '--comment', '5', '--body-file', 'answer.txt'],
    ['reply', '12', '--issue-body'],
    ['reply', '12', '--body-file', 'answer.txt'],
  ]) assert.throws(() => parseArgs(args), /exactly one|body-file/);
});

test('path scopes compare component boundaries and fail closed for unknown work', () => {
  assert.deepEqual(normalizePaths('scripts/,./tests/unit, scripts'), ['scripts', 'tests/unit']);
  assert(pathsOverlap(['scripts'], ['scripts/main.gd']));
  assert(pathsOverlap(['.'], ['web']));
  assert(!pathsOverlap(['scripts'], ['scripts-old', 'web']));
  for (const value of ['', '/tmp', '../web', 'web/../scripts', 'web//x', 'web/*', 'web\\x']) {
    assert.throws(() => normalizePaths(value));
  }
});

class ParallelGitHub extends FakeGitHub {
  constructor() {
    super();
    this.repo = 'owner/repo';
    this.policy = { ...policy, repository: this.repo, max_active_issues: 3, max_open_prs: 6, max_stack_depth: 3 };
    this.allowed = new Map();
    this.issueStates = new Map();
    this.approvalIds = new Map();
    this.prs = new Map();
    this.nativeStacks = [];
  }
  issue(number) {
    return { issue: { ...structuredClone(issue), number, state: this.issueStates.get(number) || 'open' },
      decision: { approved: this.allowed.get(number) !== false, reason: 'held',
        comment_id: this.approvalIds.get(number) || number, scope: `scope-${number}` } };
  }
  pulls() {
    return [...this.prs.values()].filter(p => p.state === 'open').map(p => ({
      number: p.number, headRefName: p.head.ref, baseRefName: p.base.ref,
    }));
  }
  pull(number) { return structuredClone(this.prs.get(number)); }
  stacks() { return structuredClone(this.nativeStacks); }
  addPr(number, issueNumber, base = 'main', sha = `sha-${number}`) {
    const value = { number, state: 'open', merged_at: null, user: { id: 99 },
      head: { ref: `ai/issue-${issueNumber}`, sha, repo: { full_name: this.repo } },
      base: { ref: base, repo: { full_name: this.repo } } };
    this.prs.set(number, value);
    return value;
  }
  api(endpoint, options = {}) {
    if (options.method !== 'POST' || !endpoint.startsWith('stacks')) return super.api(endpoint, options);
    this.mutations.push({ endpoint, ...options });
    if (endpoint === 'stacks') {
      const value = { number: 50, open: true, base: { ref: 'main' },
        pull_requests: options.data.pull_requests.map(number => ({ number })) };
      this.nativeStacks.push(value);
      return value;
    }
    const value = this.nativeStacks.find(s => s.number === Number(endpoint.split('/')[1]));
    value.pull_requests.push(...options.data.pull_requests.map(number => ({ number })));
    return value;
  }
}

function repository(t) {
  const temporary = mkdtempSync(join(tmpdir(), 'droplet-claim-test-'));
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const root = join(temporary, 'controller');
  mkdirSync(root);
  const execute = (args, { cwd = root } = {}) => execFileSync(args[0], args.slice(1), {
    cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 10000,
  }).trim();
  const git = (args, cwd = root) => execute(['git', ...args], { cwd });
  git(['init', '-b', 'main']);
  git(['config', 'user.email', 'test@example.invalid']);
  git(['config', 'user.name', 'Queue test']);
  git(['config', 'commit.gpgsign', 'false']);
  mkdirSync(join(root, 'tools/automation'), { recursive: true });
  copyFileSync(new URL('./queue.mjs', import.meta.url), join(root, 'tools/automation/queue.mjs'));
  writeFileSync(join(root, 'initial.txt'), 'main\n');
  git(['add', '.']);
  git(['commit', '-m', 'initial']);
  const remote = join(temporary, 'remote.git');
  git(['init', '--bare', remote]);
  git(['remote', 'add', 'origin', remote]);
  git(['push', '-u', 'origin', 'main']);
  return { root, git, execute };
}

test('three independent claims use real worktrees; limit and overlap checks stop more work', t => {
  const { root, git, execute } = repository(t);
  const github = new ParallelGitHub();
  const first = claim(github, 1, root, execute, { paths: 'scripts' });
  assert.equal(git(['branch', '--show-current'], first.worktree), 'ai/issue-1');
  assert.throws(() => claim(github, 2, root, execute, { paths: 'scripts/main.gd' }), /overlap/);
  assert.throws(() => claim(github, 2, root, execute), /overlap/);
  claim(github, 2, root, execute, { paths: 'web' });
  claim(github, 3, root, execute, { paths: '.github' });
  assert.throws(() => claim(github, 4, root, execute, { paths: 'nexrad' }), /Active issue limit/);
  const recovered = claim(github, 1, root, execute);
  assert.deepEqual(recovered.paths, ['scripts']);
  assert.equal(recovered.worktree, first.worktree);
  assert.equal(Object.keys(loadState(root).jobs).length, 3);
});

test('worker checkout CLI cannot create a separate controller state', t => {
  const { root, execute } = repository(t);
  const job = claim(new ParallelGitHub(), 1, root, execute, { paths: 'scripts' });
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  assert.throws(() => execFileSync(process.execPath, [join(job.worktree, 'tools/automation/queue.mjs'), 'status'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 10000, env,
  }), error => {
    assert.match(error.stderr, /canonical controller checkout/);
    return true;
  });
  assert.equal(existsSync(join(job.worktree, '.automation/state.json')), false);
});

test('dependent work starts at the live parent tip and refuses moved or held parents', t => {
  const { root, git, execute } = repository(t);
  const github = new ParallelGitHub();
  const parent = claim(github, 1, root, execute, { paths: 'scripts' });
  writeFileSync(join(parent.worktree, 'parent.txt'), 'one');
  git(['add', '.'], parent.worktree); git(['commit', '-m', 'parent'], parent.worktree);
  git(['push', 'origin', parent.branch], parent.worktree);
  const pr = github.addPr(101, 1, 'main', git(['rev-parse', 'HEAD'], parent.worktree));
  assert.throws(() => claim(github, 2, root, execute, { paths: 'web', 'base-issue': 1 }), /in-review/);
  checkpoint(github, { number: 1, phase: 'in-review', pr: 101 }, root);
  const child = claim(github, 2, root, execute, { paths: 'scripts', 'base-issue': 1 });
  assert.equal(git(['rev-parse', 'HEAD'], child.worktree), pr.head.sha);
  assert.equal(child.base_ref, 'ai/issue-1');
  assert.throws(() => claim(github, 1, root, execute), /overlap/);
  writeFileSync(join(parent.worktree, 'parent.txt'), 'two');
  git(['add', '.'], parent.worktree); git(['commit', '-m', 'parent revision'], parent.worktree);
  git(['push', 'origin', parent.branch], parent.worktree);
  pr.head.sha = git(['rev-parse', 'HEAD'], parent.worktree);
  assert.throws(() => checkJob(github, 2, root), /Parent branch changed/);
  assert.throws(() => claim(github, 2, root, execute), /current base head/);
  const recovering = claim(github, 2, root, execute, { recover: true });
  assert.equal(recovering.phase, 'recovering');
  assert.throws(() => checkJob(github, 2, root), /Only local Git recovery/);
  assert.equal(checkJob(github, 2, root, { recovery: true }).approved, true);
  git(['rebase', 'origin/ai/issue-1'], child.worktree);
  assert.equal(claim(github, 2, root, execute).base_sha, pr.head.sha);
  github.allowed.set(1, false);
  assert.throws(() => checkJob(github, 2, root), /held/);
  assert.throws(() => claim(github, 2, root, execute), /held/);
  const recovery = reconcile(github, root);
  assert.equal(recovery.jobs[1].phase, 'held');
  assert.equal(recovery.jobs[2].phase, 'held');
  assert.equal(readFileSync(join(child.worktree, 'parent.txt'), 'utf8'), 'two');
});

test('resume reads a retargeted PR base and requires deliberate ancestry repair', t => {
  const { root, git, execute } = repository(t);
  const github = new ParallelGitHub();
  const parent = claim(github, 1, root, execute, { paths: 'scripts' });
  writeFileSync(join(parent.worktree, 'parent.txt'), 'one');
  git(['add', '.'], parent.worktree); git(['commit', '-m', 'parent'], parent.worktree);
  git(['push', 'origin', parent.branch], parent.worktree);
  github.addPr(101, 1, 'main', git(['rev-parse', 'HEAD'], parent.worktree));
  checkpoint(github, { number: 1, phase: 'in-review', pr: 101 }, root);
  const child = claim(github, 2, root, execute, { paths: 'web', 'base-issue': 1 });
  git(['push', 'origin', child.branch], child.worktree);
  github.addPr(102, 2, 'main', git(['rev-parse', 'HEAD'], child.worktree));
  assert.throws(() => claim(github, 2, root, execute, { 'base-issue': 1 }), /differs from the live PR base/);
  const resumed = claim(github, 2, root, execute);
  assert.equal(resumed.base_ref, 'main');
  assert.equal(resumed.base_issue, null);
});

test('recovery fast-forwards only clean worktrees and still reserves their paths', t => {
  const { root, git, execute } = repository(t);
  const github = new ParallelGitHub();
  const job = claim(github, 1, root, execute, { paths: 'web' });
  git(['push', 'origin', job.branch], job.worktree);
  const pr = github.addPr(101, 1, 'main', git(['rev-parse', 'HEAD'], job.worktree));
  const elsewhere = join(root, 'remote-edit');
  git(['worktree', 'add', '--detach', elsewhere, pr.head.sha]);
  writeFileSync(join(elsewhere, 'remote.txt'), 'remote');
  git(['add', '.'], elsewhere); git(['commit', '-m', 'remote revision'], elsewhere);
  git(['push', 'origin', `HEAD:${job.branch}`], elsewhere);
  pr.head.sha = git(['rev-parse', 'HEAD'], elsewhere);
  assert.throws(() => claim(github, 1, root, execute), /claim --recover/);
  writeFileSync(join(job.worktree, 'local.txt'), 'keep dirty work');
  const dirtyHead = git(['rev-parse', 'HEAD'], job.worktree);
  const dirty = claim(github, 1, root, execute, { recover: true });
  assert.match(dirty.recovery.action, /Uncommitted changes preserved/);
  assert.equal(git(['rev-parse', 'HEAD'], job.worktree), dirtyHead);
  assert.equal(readFileSync(join(job.worktree, 'local.txt'), 'utf8'), 'keep dirty work');
  assert.throws(() => claim(github, 2, root, execute, { paths: 'web/component.js' }), /overlap/);
  git(['stash', 'push', '--include-untracked', '-m', 'preserve test edit'], job.worktree);
  const clean = claim(github, 1, root, execute, { recover: true });
  assert.match(clean.recovery.action, /fast-forwarded/);
  assert.equal(git(['rev-parse', 'HEAD'], job.worktree), pr.head.sha);
  assert.equal(claim(github, 1, root, execute).phase, 'working');
});

test('deliberate rebase yields a stable exact push lease until the remote changes', t => {
  const { root, git, execute } = repository(t);
  const github = new ParallelGitHub();
  const parent = claim(github, 1, root, execute, { paths: 'scripts' });
  writeFileSync(join(parent.worktree, 'parent.txt'), 'first');
  git(['add', '.'], parent.worktree); git(['commit', '-m', 'parent'], parent.worktree);
  git(['push', 'origin', parent.branch], parent.worktree);
  const parentPr = github.addPr(101, 1, 'main', git(['rev-parse', 'HEAD'], parent.worktree));
  checkpoint(github, { number: 1, phase: 'in-review', pr: 101 }, root);
  const child = claim(github, 2, root, execute, { paths: 'web', 'base-issue': 1 });
  writeFileSync(join(child.worktree, 'child.txt'), 'child');
  git(['add', '.'], child.worktree); git(['commit', '-m', 'child'], child.worktree);
  git(['push', 'origin', child.branch], child.worktree);
  const childPr = github.addPr(102, 2, parent.branch, git(['rev-parse', 'HEAD'], child.worktree));
  const originalRemote = childPr.head.sha;
  writeFileSync(join(parent.worktree, 'parent.txt'), 'second');
  git(['add', '.'], parent.worktree); git(['commit', '-m', 'parent revision'], parent.worktree);
  git(['push', 'origin', parent.branch], parent.worktree);
  parentPr.head.sha = git(['rev-parse', 'HEAD'], parent.worktree);
  claim(github, 2, root, execute, { recover: true });
  git(['rebase', `origin/${parent.branch}`], child.worktree);
  assert.equal(claim(github, 2, root, execute).push_lease, originalRemote);
  assert.equal(claim(github, 2, root, execute).push_lease, originalRemote);
  const elsewhere = join(root, 'remote-edit');
  git(['worktree', 'add', '--detach', elsewhere, originalRemote]);
  writeFileSync(join(elsewhere, 'remote.txt'), 'new remote work');
  git(['add', '.'], elsewhere); git(['commit', '-m', 'remote revision'], elsewhere);
  git(['push', 'origin', `HEAD:${child.branch}`], elsewhere);
  childPr.head.sha = git(['rev-parse', 'HEAD'], elsewhere);
  assert.throws(() => claim(github, 2, root, execute), /claim --recover/);
});

test('closed PR retry needs a new approval and does not retain its ended PR checkpoint', t => {
  const { root, git, execute } = repository(t);
  const github = new ParallelGitHub();
  const job = claim(github, 1, root, execute, { paths: 'web' });
  git(['push', 'origin', job.branch], job.worktree);
  const pr = github.addPr(101, 1, 'main', git(['rev-parse', 'HEAD'], job.worktree));
  checkpoint(github, { number: 1, phase: 'in-review', pr: 101 }, root);
  pr.state = 'closed';
  assert.throws(() => claim(github, 1, root, execute), /new human \/approve/);
  reconcile(github, root);
  github.approvalIds.set(1, 9);
  const retry = claim(github, 1, root, execute);
  assert.equal(retry.pr, undefined);
  assert.equal(checkJob(github, 1, root).approved, true);
});

test('holding an exhausted attempt cannot erase its requirement for fresh approval', () => temp(root => {
  const github = new ParallelGitHub();
  saveState({ jobs: { 1: { phase: 'working', repair_attempts: 2,
    branch: 'ai/issue-1', approval: { scope: 'scope-1', comment_id: 1 } } } }, root);
  checkpoint(github, { number: 1, repair: true }, root);
  github.allowed.set(1, false);
  reconcile(github, root);
  github.allowed.set(1, true);
  assert.throws(() => claim(github, 1, root, () => assert.fail('executed Git')), /new human \/approve/);
}));

test('dependent claims enforce stack depth and reject dependency cycles before Git', () => temp(root => {
  const github = new ParallelGitHub();
  const jobs = {};
  for (let i = 1; i <= 3; i++) {
    jobs[i] = { phase: 'in-review', branch: `ai/issue-${i}`, pr: 100 + i, approval: { scope: `scope-${i}`, comment_id: i } };
    github.addPr(100 + i, i, i === 1 ? 'main' : `ai/issue-${i - 1}`);
  }
  saveState({ jobs }, root);
  assert.throws(() => claim(github, 4, root, () => assert.fail('executed Git'), { 'base-issue': 3 }), /stack depth/);
  assert.throws(() => claim(github, 1, root, () => assert.fail('executed Git'), { 'base-issue': 1 }), /differs from the live PR base/);
  github.prs.get(101).base.ref = 'ai/issue-1';
  assert.throws(() => claim(github, 1, root, () => assert.fail('executed Git'), { 'base-issue': 1 }), /dependency cycle/);
}));

test('reconciliation releases slots for held, closed and merged work without discarding notes', () => temp(root => {
  const github = new ParallelGitHub();
  const jobs = Object.fromEntries([1, 2, 3, 4, 5].map(number => [number, {
    phase: 'working', branch: `ai/issue-${number}`, notes: `keep-${number}`,
    approval: { scope: `scope-${number}`, comment_id: number },
  }]));
  jobs[2].pr = 102; jobs[4].pr = 104;
  github.issueStates.set(1, 'closed');
  Object.assign(github.addPr(102, 2), { state: 'closed', merged_at: '2026-09-23T12:00:00Z' });
  github.allowed.set(3, false);
  github.addPr(104, 4).state = 'closed';
  saveState({ jobs }, root);
  const result = reconcile(github, root);
  assert.deepEqual(Object.values(result.jobs).map(j => j.phase), ['done', 'done', 'held', 'blocked', 'working']);
  assert.equal(result.jobs[4].notes, 'keep-4');
  assert.equal(reconcile(github, root).changes.length, 0);
  assert.throws(() => checkpoint(github, { number: 4, phase: 'working' }, root), /Use claim/);
}));

test('native stacks create, append and retry idempotently with no merge action', () => {
  const github = new ParallelGitHub();
  github.addPr(101, 1); github.addPr(102, 2, 'ai/issue-1'); github.addPr(103, 3, 'ai/issue-2');
  assert.equal(stack(github, [101, 102]).action, 'created');
  assert.equal(stack(github, [101, 102]).action, 'existing');
  assert.equal(stack(github, [101, 102, 103]).action, 'appended');
  assert.equal(stack(github, [101, 102]).action, 'existing');
  assert.equal(stack(github, [101, 102, 103]).action, 'existing');
  assert.deepEqual(github.mutations, [
    { endpoint: 'stacks', method: 'POST', data: { pull_requests: [101, 102] } },
    { endpoint: 'stacks/50/add', method: 'POST', data: { pull_requests: [103] } },
  ]);
});

test('native stacks reject ownership, approval, branch order, depth and stack conflicts', () => {
  const scenario = change => {
    const github = new ParallelGitHub();
    github.addPr(101, 1); github.addPr(102, 2, 'ai/issue-1');
    change(github);
    assert.throws(() => stack(github, [101, 102]));
    assert.equal(github.mutations.length, 0);
  };
  scenario(g => { g.prs.get(102).user.id = 7; });
  scenario(g => { g.prs.get(102).head.repo.full_name = 'other/repo'; });
  scenario(g => { g.prs.get(102).state = 'closed'; });
  scenario(g => { g.prs.get(102).base.ref = 'main'; });
  scenario(g => { g.allowed.set(1, false); });
  scenario(g => { g.nativeStacks = [{ open: true, base: { ref: 'main' }, pull_requests: [{ number: 102 }, { number: 101 }] }]; });
  scenario(g => { g.nativeStacks = [101, 102].map(number => ({ pull_requests: [{ number }] })); });
  assert.throws(() => stack(new ParallelGitHub(), [101, 102, 103, 104]), /distinct PR/);
  assert.throws(() => stack(new ParallelGitHub(), [101, 101]), /distinct PR/);
});

test('stacks use the versioned API and structured JSON input', () => {
  let called;
  const github = new GitHub({ ...policy, repository: 'owner/repo' }, (args, options) => {
    called = { args, options }; return '{}';
  });
  github.api(github.endpoint('stacks'), { method: 'POST', data: { pull_requests: [101, 102] } });
  assert(called.args.includes('X-GitHub-Api-Version: 2026-03-10'));
  assert.deepEqual(JSON.parse(called.options.input), { pull_requests: [101, 102] });
  assert.equal(parseArgs(['claim', '12', '--paths', 'web,scripts', '--base-issue', '5'])['base-issue'], 5);
  assert.deepEqual(parseArgs(['stack', '--prs', '101,102']).prs, [101, 102]);
});

test('bottom-layer changes invalidate top-layer authorization even before middle recovery', () => temp(root => {
  const github = new ParallelGitHub();
  github.addPr(101, 1); github.addPr(102, 2, 'ai/issue-1');
  const dependencies = [2, 1].map(n => ({ issue: n, pr: 100 + n, branch: `ai/issue-${n}`,
    sha: `sha-${100 + n}`, approval_id: n, scope: `scope-${n}` }));
  const jobs = Object.fromEntries([1, 2].map(n => [n, { phase: 'in-review', pr: 100 + n,
    branch: `ai/issue-${n}`, approval: { scope: `scope-${n}`, comment_id: n } }]));
  jobs[3] = { phase: 'working', branch: 'ai/issue-3', base_issue: 2, base_sha: 'sha-102',
    worker_id: 99, dependencies, approval: { scope: 'scope-3', comment_id: 3 } };
  saveState({ jobs }, root);
  assert.equal(checkJob(github, 3, root).approved, true);
  github.prs.get(101).head.sha = 'changed-bottom';
  assert.throws(() => checkJob(github, 3, root), /dependency chain/);
  assert.equal(reconcile(github, root).jobs[3].phase, 'held');
}));

test('claim fails if a bottom dependency changes while the worktree is being prepared', () => temp(root => {
  const github = new ParallelGitHub();
  const jobs = {};
  for (const n of [1, 2]) {
    github.addPr(100 + n, n, n === 1 ? 'main' : 'ai/issue-1');
    jobs[n] = { phase: 'in-review', pr: 100 + n, branch: `ai/issue-${n}`,
      approval: { scope: `scope-${n}`, comment_id: n } };
  }
  saveState({ jobs }, root);
  const execute = args => {
    if (args[1] === 'fetch') github.prs.get(101).head.sha = 'changed-bottom';
    if (args[1] === 'rev-parse') return 'sha-102';
    return '';
  };
  assert.throws(() => claim(github, 3, root, execute, { paths: 'web', 'base-issue': 2 }), /chain changed during setup/);
  assert.equal(loadState(root).jobs[3], undefined);
}));

test('scope or approval changed during setup cannot inherit the old planned paths', t => {
  for (const changeScope of [false, true]) {
    const { root, execute } = repository(t);
    const github = new ParallelGitHub();
    const originalIssue = github.issue.bind(github);
    let changed = false;
    github.issue = number => {
      const result = originalIssue(number);
      if (changed) {
        result.decision.comment_id = 55;
        if (changeScope) result.decision.scope = 'changed-approved-scope';
      }
      return result;
    };
    const setup = (args, options) => {
      const output = execute(args, options);
      if (args[1] === 'fetch') changed = true;
      return output;
    };
    assert.throws(() => claim(github, 1, root, setup, { paths: 'web' }), /Approval or scope changed during setup/);
    assert.equal(loadState(root).jobs[1], undefined);
  }
});
