import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { approval, scopeHash, reply, claim, checkpoint, checkJob, loadState, saveState, parseArgs, GitHub, sync, LABELS,
  normalizePaths, pathsOverlap, reconcile, stack, activity, observe, findBaseline, storeSnapshot, summarize,
  watchUntilChange, PREVIEW_MARKER, ghComment, ghReview } from './queue.mjs';

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

// Activity deltas. Snapshots mirror snapshot(): REST issue/inline comments and gh PR JSON.
const restComment = (id, body, userId, login, at = '2026-09-23T12:00:00Z', extra = {}) => ({ id, body,
  user: { id: userId, login }, created_at: at, updated_at: at, url: `https://github.com/x/y/issues/1#c${id}`, ...extra });
function baseSnapshot() {
  return {
    issues: [{ number: 12, title: 'Fix loading', body: 'Scope', url: 'u12', author: 'owner', updated_at: '2026-09-23T12:00:00Z',
      labels: ['needs-approval'], approval: { approved: false, reason: 'needs human /approve' },
      comments: [restComment(1, 'First thought', 7, 'owner')] }],
    pull_requests: [{ number: 57, url: 'p57', title: 'PR', body: 'Closes #3', author: { login: 'bot' }, baseRefName: 'main',
      headRefName: 'ai/issue-3', headRefOid: 'aaaaaaaa', updatedAt: '2026-09-23T12:00:00Z', isDraft: false, reviewDecision: '',
      statusCheckRollup: [{ __typename: 'CheckRun', workflowName: 'CI', name: 'test', status: 'IN_PROGRESS', conclusion: '' }],
      comments: [{ id: 'IC_1', author: { login: 'owner' }, body: 'Looks close', createdAt: '2026-09-23T12:00:00Z', url: 'pc1', viewerDidAuthor: false }],
      reviews: [], inline_comments: [] }],
    stacks: [], jobs: { 3: { phase: 'in-review', pr: 57 } }, fingerprint: 'a'.repeat(64),
  };
}
const context = (extra = {}) => ({ policy, viewer: { id: 99, login: 'bot' },
  lookupPull: () => assert.fail('unexpected PR lookup'), lookupIssue: () => assert.fail('unexpected issue lookup'), ...extra });

test('activity reports new, edited and deleted issue comments with author roles', () => {
  const before = baseSnapshot();
  const after = structuredClone(before);
  after.issues[0].comments[0] = { ...after.issues[0].comments[0], body: 'Prefer option B', updated_at: '2026-09-23T12:05:00Z' };
  after.issues[0].comments.push(restComment(2, 'Design: use a ring buffer\nmore', 7, 'owner', '2026-09-23T12:06:00Z'),
    restComment(3, 'Answer', 99, 'bot', '2026-09-23T12:07:00Z'));
  const items = activity(before, after, context());
  assert.deepEqual(items.map(i => [i.type, i.id, i.change, i.approver, i.self]),
    [['comment', 1, 'edited', true, false], ['comment', 2, 'new', true, false], ['comment', 3, 'new', false, true]]);
  assert.equal(items[1].body, 'Design: use a ring buffer\nmore');
  assert.equal(summarize(items[1]), 'comment #12 owner (approver) new: Design: use a ring buffer');
  const removed = activity(after, before, context()).filter(i => i.change === 'deleted');
  assert.deepEqual(removed.map(i => i.id), [2, 3]);
});

test('activity reports PR conversation, inline comments, reviews and preview updates', () => {
  const before = baseSnapshot();
  const after = structuredClone(before);
  const pr = after.pull_requests[0];
  pr.comments[0].body = 'Looks close; one nit';
  pr.comments.push({ id: 'IC_2', author: { login: 'github-actions' }, createdAt: '2026-09-23T12:09:00Z', url: 'pc2',
    body: `${PREVIEW_MARKER}\n[Open live preview](x)\n\nDeployed commit: \`bbbbbbbb\`.`, viewerDidAuthor: false });
  pr.inline_comments.push(restComment(40, 'Off by one here', 7, 'owner', '2026-09-23T12:08:00Z', { path: 'web/a.js', line: 9 }));
  pr.reviews.push({ id: 'PRR_1', author: { login: 'owner' }, state: 'CHANGES_REQUESTED', body: 'Please fix',
    submittedAt: '2026-09-23T12:08:30Z', commit: { oid: 'aaaaaaaa' } });
  const items = activity(before, after, context());
  assert.deepEqual(items.map(i => [i.type, i.change]), [
    ['comment', 'edited'], ['inline_comment', 'new'], ['review', 'new'], ['preview', 'new']]);
  assert.equal(items[0].approver, true);
  assert.equal(items[1].path, 'web/a.js');
  assert.equal(items[2].state, 'CHANGES_REQUESTED');
  assert.equal(items[3].sha, 'bbbbbbbb');
  assert.equal(summarize(items[1]), 'inline_comment #57 owner (approver) new web/a.js:9: Off by one here');
  assert.equal(summarize(items[3]), 'preview #57 github-actions new: bbbbbbbb');
  const dismissed = structuredClone(after);
  dismissed.pull_requests[0].reviews[0].state = 'DISMISSED';
  assert.deepEqual(activity(after, dismissed, context()).map(i => [i.type, i.change, i.previous_state]),
    [['review', 'edited', 'CHANGES_REQUESTED']]);
});

test('activity reports approval, label, edit and job changes', () => {
  const before = baseSnapshot();
  const after = structuredClone(before);
  const issue = after.issues[0];
  issue.comments.push(restComment(5, '/approve', 7, 'owner', '2026-09-23T12:10:00Z'));
  issue.approval = { approved: true, reason: 'approved by maintainer', comment_id: 5, url: 'a5', scope: 's' };
  issue.labels = ['ready'];
  after.jobs[3] = { phase: 'done', pr: 57 };
  let items = activity(before, after, context());
  assert.deepEqual(items.map(i => [i.type, i.change]), [
    ['issue', 'labels'], ['approval', 'approved'], ['comment', 'new'], ['job', 'updated']]);
  assert.equal(items.find(i => i.type === 'approval').at, '2026-09-23T12:10:00Z');
  const held = structuredClone(after);
  held.issues[0].approval = { approved: false, reason: 'held by maintainer' };
  held.issues[0].title = 'Fix loading faster';
  items = activity(after, held, context());
  assert.deepEqual(items.map(i => [i.type, i.change]), [['issue', 'edited'], ['approval', 'held']]);
  assert.equal(summarize(items[1]), 'approval #12 held: held by maintainer');
});

test('activity reports check transitions, head changes and new stacks', () => {
  const before = baseSnapshot();
  const after = structuredClone(before);
  const pr = after.pull_requests[0];
  pr.headRefOid = 'cccccccc';
  pr.statusCheckRollup = [
    { __typename: 'CheckRun', workflowName: 'CI', name: 'test', status: 'COMPLETED', conclusion: 'FAILURE',
      completedAt: '2026-09-23T12:20:00Z', detailsUrl: 'run' },
    { __typename: 'StatusContext', context: 'pages', state: 'PENDING' }];
  after.stacks = [{ number: 50, open: true, base: { ref: 'main' }, pull_requests: [{ number: 57 }, { number: 58 }] }];
  const items = activity(before, after, context());
  const check = items.find(i => i.type === 'check' && i.name === 'CI/test');
  assert.deepEqual([check.from, check.to, check.head_sha], ['pending', 'fail', 'cccccccc']);
  assert.equal(summarize(check), 'check #57 CI/test pending -> fail');
  assert.deepEqual(items.find(i => i.name === 'pages').to, 'pending');
  assert.equal(items.find(i => i.type === 'pull_request').change, 'head');
  assert.deepEqual(items.find(i => i.type === 'stack').pull_requests, [57, 58]);
  assert.equal(activity(after, structuredClone(after), context()).length, 0);
});

test('PRs and issues leaving the open lists are resolved to merged or closed with one lookup each', () => {
  const before = baseSnapshot();
  const after = { ...structuredClone(before), issues: [], pull_requests: [] };
  const lookups = [];
  const items = activity(before, after, context({
    lookupPull: n => { lookups.push(['pull', n]); return { state: 'closed', merged_at: '2026-09-23T13:00:00Z', merged_by: { login: 'owner' }, merge_commit_sha: 'm' }; },
    lookupIssue: n => { lookups.push(['issue', n]); return { state: 'closed', state_reason: 'completed', closed_at: '2026-09-23T13:00:01Z' }; },
  }));
  assert.deepEqual(lookups, [['issue', 12], ['pull', 57]]);
  assert.deepEqual(items.map(i => [i.type, i.change]), [['pull_request', 'merged'], ['issue', 'closed']]);
  assert.equal(summarize(items[0]), 'pull_request #57 merged: by owner');
  const failed = activity(before, after, context({ lookupPull: () => { throw new Error('boom'); }, lookupIssue: () => ({ state: 'closed' }) }));
  assert.deepEqual(failed.find(i => i.type === 'pull_request').error, 'boom');
});

class ObserveGitHub {
  constructor() { this.policy = policy; this.calls = []; }
  api(endpoint) { this.calls.push(endpoint); if (endpoint === 'user') return { id: 99, login: 'bot' }; throw new Error(`unexpected ${endpoint}`); }
  endpoint(suffix) { return suffix; }
  pull() { throw new Error('unexpected pull'); }
}

test('observe flags missing and stale baselines, then itemizes changes since a stored fingerprint', () => temp(root => {
  const github = new ObserveGitHub();
  const first = baseSnapshot();
  let result = observe(github, first, first.fingerprint, root);
  assert.equal(result.baseline, 'none');
  assert.deepEqual(result.activity, []);
  assert.equal(result.issues.length, 1);
  const second = structuredClone(first);
  second.fingerprint = 'b'.repeat(64);
  second.issues[0].comments.push(restComment(2, 'Question?', 7, 'owner', '2026-09-23T12:30:00Z'));
  result = observe(github, second, first.fingerprint, root);
  assert.equal(result.baseline, 'since');
  assert.equal(result.baseline_fingerprint, first.fingerprint);
  assert.deepEqual(result.activity.map(i => i.id), [2]);
  assert.equal(result.viewer, 'bot');
  result = observe(github, second, 'f'.repeat(64), root);
  assert.equal(result.baseline, 'stale');
  assert.equal(result.baseline_fingerprint, second.fingerprint);
  assert.equal(findBaseline(undefined, root).baseline, 'last');
  assert.equal(findBaseline('../../etc/passwd', root).baseline, 'stale');
}));

test('stored snapshots are pruned from the directory listing without a shared index', () => temp(root => {
  const fp = i => i.toString(16).padStart(64, '0');
  for (let i = 0; i < 35; i++) storeSnapshot({ fingerprint: fp(i) }, root);
  const files = readdirSync(join(root, '.automation/snapshots'));
  assert.equal(files.length, 30);
  assert.equal(files.includes('index.json'), false);
  assert.equal(existsSync(join(root, `.automation/snapshots/${fp(0)}.json`)), false);
  assert.equal(findBaseline(fp(5), root).baseline, 'since');
  const latest = findBaseline(undefined, root);
  assert.deepEqual([latest.baseline, latest.previous.fingerprint], ['last', fp(34)]);
  assert.ok(latest.previous.observed_at);
}));

test('watch-until-change loops until the fingerprint changes and writes the full JSON', () => temp(root => {
  const out = join(root, 'watch-last.json');
  const outputs = [{ fingerprint: 'old', activity: [], baseline: 'since' },
    { fingerprint: 'new', baseline: 'since', activity: [{ type: 'comment', number: 12, author: 'owner', approver: true, change: 'new', body: 'Hi' }] }];
  const calls = [];
  const lines = [];
  const code = watchUntilChange({ since: 'old', out }, { execute: args => { calls.push(args); return JSON.stringify(outputs.shift()); },
    sleep: () => assert.fail('slept'), log: line => lines.push(line), warn: () => {} });
  assert.equal(code, 0);
  assert.deepEqual(calls, [['watch', '--since', 'old', '--seconds', '60'], ['watch', '--since', 'old', '--seconds', '60']]);
  assert.equal(JSON.parse(readFileSync(out, 'utf8')).fingerprint, 'new');
  assert.deepEqual(lines, [`CHANGED baseline=since items=1 json=${out}`, 'comment #12 owner (approver) new: Hi', 'fingerprint new']);
}));

test('watch-until-change backs off on errors, resets after success and stops after five failures', () => temp(root => {
  const out = join(root, 'watch-last.json');
  const sleeps = [];
  const lines = [];
  let n = 0;
  const execute = () => {
    n++;
    if (n === 3) return JSON.stringify({ fingerprint: 'same', activity: [] });
    throw new Error('HTTP 502');
  };
  const code = watchUntilChange({ since: 'same', out }, { execute, sleep: ms => sleeps.push(ms), log: l => lines.push(l), warn: () => {} });
  assert.equal(code, 1);
  assert.deepEqual(sleeps, [60000, 120000, 60000, 120000, 180000, 240000]);
  assert.match(lines.at(-1), /^PERSISTENT_ERROR after 5 consecutive failures: HTTP 502/);
  assert.equal(existsSync(out), false);
  const initial = [];
  assert.equal(watchUntilChange({ out }, { execute: args => { initial.push(args); return JSON.stringify({ fingerprint: 'x', activity: [], baseline: 'none' }); },
    sleep: () => {}, log: l => lines.push(l) }), 0);
  assert.deepEqual(initial, [['status']]);
  assert(lines.includes('BASELINE none: itemized activity may be incomplete; review the full snapshot'));
}));

test('CLI accepts status/watch-until-change fingerprints', () => {
  assert.equal(parseArgs(['status', '--since', 'abc']).since, 'abc');
  assert.equal(parseArgs(['watch-until-change']).since, undefined);
  assert.equal(parseArgs(['watch-until-change', '--out', 'x.json']).out, 'x.json');
  assert.throws(() => parseArgs(['watch-until-change', '--seconds', '5']), /Unknown option/);
});

test('watch-until-change wrapper refuses to run from a worker worktree', t => {
  const { root, git, execute } = repository(t);
  copyFileSync(new URL('./watch-until-change', import.meta.url), join(root, 'tools/automation/watch-until-change'));
  git(['add', '.']); git(['commit', '-m', 'wrapper']); git(['push', 'origin', 'main']);
  const job = claim(new ParallelGitHub(), 1, root, execute, { paths: 'scripts' });
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  assert.throws(() => execFileSync('bash', [join(job.worktree, 'tools/automation/watch-until-change')], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 10000, env,
  }), error => {
    assert.match(error.stderr, /canonical controller checkout/);
    return true;
  });
  assert.equal(existsSync(join(job.worktree, '.automation/watch-last.json')), false);
});

test('closing and merging still itemize the final comments, inline comments and reviews', () => {
  const before = baseSnapshot();
  const after = { ...structuredClone(before), issues: [], pull_requests: [] };
  const closing = restComment(9, 'Closing: superseded by #13', 7, 'owner', '2026-09-23T13:00:00Z');
  const rest = (id, nodeId, body, userId, login, at) => ({ id, node_id: nodeId, body, user: { id: userId, login },
    created_at: at, updated_at: at, html_url: `h${id}` });
  const items = activity(before, after, context({
    lookupIssue: () => ({ state: 'closed', state_reason: 'not_planned', closed_at: '2026-09-23T13:00:01Z',
      comments: [...before.issues[0].comments, closing] }),
    lookupPull: () => ({ state: 'closed', merged_at: '2026-09-23T13:05:00Z',
      comments: [rest(1, 'IC_1', 'Looks close', 7, 'owner', '2026-09-23T12:00:00Z'),
        rest(2, 'IC_2', 'Merging now', 7, 'owner', '2026-09-23T13:04:00Z')].map(ghComment),
      inline_comments: [restComment(41, 'Last nit', 7, 'owner', '2026-09-23T13:03:00Z', { path: 'a.js', line: 1 })],
      reviews: [{ id: 5, node_id: 'PRR_5', user: { id: 7, login: 'owner' }, state: 'APPROVED', body: 'Ship it',
        submitted_at: '2026-09-23T13:03:30Z', commit_id: 'aaaaaaaa' }].map(ghReview) }),
  }));
  assert.deepEqual(items.map(i => [i.type, i.change, i.id ?? null]), [
    ['comment', 'new', 9], ['issue', 'closed', null], ['inline_comment', 'new', 41], ['review', 'new', 'PRR_5'],
    ['comment', 'new', 'IC_2'], ['pull_request', 'merged', null]]);
  assert.equal(items.find(i => i.id === 'IC_2').approver, true);
  const partial = activity(before, after, context({ lookupIssue: () => ({ state: 'closed', comments_error: 'HTTP 502' }),
    lookupPull: () => ({ state: 'closed' }) }));
  assert.equal(partial.find(i => i.type === 'issue').error, 'HTTP 502');
});

test('approver comments are never marked self when the viewer is the maintainer', () => {
  const before = baseSnapshot();
  const after = structuredClone(before);
  after.issues[0].comments.push(restComment(2, 'My own note', 7, 'owner', '2026-09-23T12:01:00Z'));
  after.pull_requests[0].comments.push({ id: 'IC_9', author: { login: 'owner' }, body: 'mine', createdAt: '2026-09-23T12:02:00Z', viewerDidAuthor: true });
  const items = activity(before, after, context({ viewer: { id: 7, login: 'owner' } }));
  assert.deepEqual(items.map(i => [i.approver, i.self]), [[true, false], [true, false]]);
});

test('duplicate and removed checks, head branch changes and reopened issues are itemized', () => {
  const before = baseSnapshot();
  before.observed_at = '2026-09-23T12:30:00Z';
  const run = (conclusion, url) => ({ __typename: 'CheckRun', workflowName: 'CI', name: 'test', status: 'COMPLETED', conclusion, detailsUrl: url });
  before.pull_requests[0].statusCheckRollup.push({ __typename: 'StatusContext', context: 'old', state: 'SUCCESS' });
  const after = structuredClone(before);
  after.pull_requests[0].statusCheckRollup = [run('SUCCESS', 'r1'), run('FAILURE', 'r2')];
  after.pull_requests[0].headRefName = 'ai/issue-3b';
  after.issues.push({ ...structuredClone(before.issues[0]), number: 13, created_at: '2026-09-01T00:00:00Z', comments: [] });
  const items = activity(before, after, context());
  const checks = items.filter(i => i.type === 'check').map(i => [i.name, i.from, i.to]);
  assert.deepEqual(checks.sort(), [['CI/test#2', null, 'fail'], ['CI/test', 'pending', 'pass'], ['old', 'pass', null]]);
  assert.equal(items.find(i => i.change === 'head_ref').previous_head, 'ai/issue-3');
  assert.equal(items.find(i => i.type === 'issue' && i.number === 13).change, 'reopened');
  assert.equal(summarize(items.find(i => i.name === 'old')), 'check #57 old pass -> removed');
  const removedReview = structuredClone(after);
  after.pull_requests[0].reviews = [{ id: 'PRR_1', author: { login: 'owner' }, state: 'COMMENTED', body: 'x' }];
  assert.deepEqual(activity(after, removedReview, context()).map(i => [i.type, i.change]), [['review', 'deleted']]);
});

test('rate limits wait for the reset without consuming retries', () => temp(root => {
  const out = join(root, 'watch-last.json');
  const sleeps = [];
  const warnings = [];
  let n = 0;
  const execute = () => {
    n++;
    if (n <= 6) throw new Error('gh: API rate limit exceeded for user ID 1. (HTTP 403)');
    if (n === 7) throw new Error('HTTP 502');
    return JSON.stringify({ fingerprint: 'new', baseline: 'since', activity: [] });
  };
  const code = watchUntilChange({ since: 'old', out }, { execute, sleep: ms => sleeps.push(ms), log: () => {},
    warn: w => warnings.push(w), now: () => 1_000_000, rateLimitReset: () => (n === 1 ? 1_600_000 : null) });
  assert.equal(code, 0);
  assert.deepEqual(sleeps, [605000, 300000, 300000, 300000, 300000, 300000, 60000]);
  assert.match(warnings[0], /^RATE_LIMITED: waiting 605s/);
}));

test('summarize shows how a review changed', () => {
  const base = { type: 'review', number: 9, author: 'owner', approver: true, body: 'x' };
  assert.equal(summarize({ ...base, change: 'deleted', state: null, previous_state: 'COMMENTED' }), 'review #9 owner (approver) deleted COMMENTED: x');
  assert.equal(summarize({ ...base, change: 'new', state: 'APPROVED' }), 'review #9 owner (approver) new APPROVED: x');
});
