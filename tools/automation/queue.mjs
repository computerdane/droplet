#!/usr/bin/env node
// Approval-gated GitHub queue. Node built-ins only; authentication comes from gh.
// Labels are presentation, never authorization. Issue text is never shell code.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const STATES = new Set(['needs-approval', 'ready', 'in-progress', 'in-review', 'blocked']);
export const LABELS = {
  'needs-approval': ['fbca04', 'Awaiting an unedited /approve comment from the maintainer'],
  ready: ['0e8a16', 'Approved and eligible for the development queue'],
  'in-progress': ['1d76db', 'An agent is implementing this issue'],
  'in-review': ['5319e7', 'A pull request is ready for human review'],
  blocked: ['b60205', 'Work needs input or has exhausted its repair attempts'],
  'agent-discovered': ['c5def5', 'Proposed by an agent; requires human approval'],
  question: ['d4c5f9', 'Discussion question; not eligible for implementation'],
};

export function run(args, { input, cwd = ROOT } = {}) {
  try {
    return execFileSync(args[0], args.slice(1), { input, cwd, encoding: 'utf8', timeout: 90_000,
      maxBuffer: 32 * 1024 * 1024, stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch (error) {
    // Do not print command arguments or environment, which might contain credentials.
    throw new Error(error.stderr?.toString().trim() || `${args[0]} failed: ${error.code || error.status}`);
  }
}

export class GitHub {
  constructor(policy, execute = run) {
    this.policy = policy;
    this.repo = policy.repository;
    this.execute = execute;
  }

  api(endpoint, { method = 'GET', data, paginate = false } = {}) {
    const args = ['gh', 'api', '--header', 'X-GitHub-Api-Version: 2026-03-10', '--method', method, endpoint];
    if (paginate) args.push('--paginate', '--slurp');
    if (data !== undefined) args.push('--input', '-');
    const output = this.execute(args, { input: data === undefined ? undefined : JSON.stringify(data) });
    const value = output ? JSON.parse(output) : null;
    return paginate ? value.flat() : value;
  }

  endpoint(suffix) { return `repos/${this.repo}/${suffix}`; }

  issue(number) {
    const issue = this.api(this.endpoint(`issues/${number}`));
    if (issue.pull_request) throw new Error('Approval commands belong on an issue, not a PR');
    const comments = this.api(this.endpoint(`issues/${number}/comments?per_page=100`), { paginate: true });
    const events = this.api(this.endpoint(`issues/${number}/events?per_page=100`), { paginate: true });
    const [owner, name] = this.repo.split('/');
    const result = this.api('graphql', { method: 'POST', data: {
      query: 'query($owner:String!,$name:String!,$number:Int!) { repository(owner:$owner,name:$name) { issue(number:$number) { lastEditedAt } } }',
      variables: { owner, name, number },
    } });
    if (result.errors || !result.data?.repository?.issue) throw new Error('Cannot verify issue edit history; refusing to authorize');
    issue.comments = comments;
    return { issue, decision: approval(issue, comments, events, result.data.repository.issue.lastEditedAt, this.policy) };
  }

  issues() {
    return this.api(this.endpoint('issues?state=open&per_page=100'), { paginate: true }).filter(i => !i.pull_request);
  }

  pulls() {
    return JSON.parse(this.execute(['gh', 'pr', 'list', '--repo', this.repo, '--state', 'open', '--limit', '100',
      '--json', 'number,url,title,body,author,createdAt,baseRefName,headRefName,headRefOid,updatedAt,isDraft,reviewDecision,statusCheckRollup,comments,reviews']));
  }

  pull(number) { return this.api(this.endpoint(`pulls/${number}`)); }

  stacks() { return this.api(this.endpoint('stacks?per_page=100'), { paginate: true }); }

  worker() {
    const user = this.api('user');
    if (this.policy.approvers.some(a => a.id === user.id)) {
      throw new Error('Worker is authenticated as an approver. Use a separate bot account token in GH_TOKEN; read-only status is allowed with your own account.');
    }
    return user;
  }

  labels(issue, desired) {
    const current = new Set(issue.labels.map(l => l.name));
    for (const label of current) {
      if (STATES.has(label) && label !== desired) this.api(this.endpoint(`issues/${issue.number}/labels/${label}`), { method: 'DELETE' });
    }
    if (desired && !current.has(desired)) this.api(this.endpoint(`issues/${issue.number}/labels`), { method: 'POST', data: { labels: [desired] } });
  }
}

const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export const scopeHash = issue => digest([issue.title, issue.body || '']);

export function approval(issue, comments, events, edited, policy) {
  const denied = reason => ({ approved: false, reason });
  if (issue.state !== 'open') return denied('issue closed');
  if (issue.labels.some(label => label.name === 'question')) return denied('question issue is discussion-only');
  const commands = comments.filter(c => policy.approvers.some(a => a.id === c.user.id)
    && ['/approve', '/hold'].includes((c.body || '').trim()));
  commands.sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id - b.id);
  const command = commands.at(-1);
  if (!command) return denied('needs human /approve');
  if (command.body.trim() === '/hold') return denied('held by maintainer');
  if (command.updated_at !== command.created_at) return denied('edited approval; post a new /approve comment');
  const changes = events.filter(e => ['renamed', 'closed', 'reopened'].includes(e.event)).map(e => e.created_at);
  if (edited) changes.push(edited);
  if (changes.some(t => t >= command.created_at)) return denied('scope or lifecycle changed; post a new /approve comment');
  return { approved: true, comment_id: command.id, url: command.html_url, scope: scopeHash(issue), reason: 'approved by maintainer' };
}

export function loadState(root = ROOT) {
  const path = join(root, '.automation/state.json');
  return existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : { jobs: {} };
}

export function saveState(state, root = ROOT) {
  const folder = join(root, '.automation');
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(folder, '.gdignore'), '');
  const path = join(folder, 'state.json');
  writeFileSync(`${path}.tmp`, `${JSON.stringify(state, null, 2)}\n`);
  renameSync(`${path}.tmp`, path);
}

function compactComment(c) {
  return { id: c.id, body: c.body, user: { id: c.user?.id, login: c.user?.login },
    created_at: c.created_at, updated_at: c.updated_at, url: c.html_url, path: c.path, line: c.line,
    in_reply_to: c.in_reply_to_id };
}

export function snapshot(github, root = ROOT) {
  const issues = github.issues().map(brief => {
    const { issue, decision } = github.issue(brief.number);
    return { number: issue.number, title: issue.title, body: issue.body, url: issue.html_url, author: issue.user?.login, created_at: issue.created_at,
      updated_at: issue.updated_at, approval: decision, comments: issue.comments.map(compactComment),
      labels: issue.labels.map(l => l.name) };
  });
  const pulls = github.pulls();
  for (const pull of pulls) {
    pull.inline_comments = github.api(github.endpoint(`pulls/${pull.number}/comments?per_page=100`), { paginate: true }).map(compactComment);
  }
  const value = { issues, pull_requests: pulls, stacks: github.stacks(), jobs: loadState(root).jobs };
  value.fingerprint = digest(value);
  return value;
}

// Recent snapshots are kept locally so status/watch can itemize what changed since
// the fingerprint a caller last saw. They are a reading aid, never authorization.
const SNAPSHOT_DIR = '.automation/snapshots';
const KEEP_SNAPSHOTS = 30;
const FINGERPRINT = /^[0-9a-f]{64}$/;
export const PREVIEW_MARKER = '<!-- droplet-pages-preview -->';

function writeAtomic(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, text);
  renameSync(temporary, path);
}

function readJson(path, fallback) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return fallback; }
}

// Snapshot files are listed by modification time rather than through a shared
// index, so concurrent status/watch writers cannot lose each other's entries.
function storedSnapshots(folder) {
  let names;
  try { names = readdirSync(folder); } catch { return []; }
  return names.filter(name => FINGERPRINT.test(name.replace(/\.json$/, '')) && name.endsWith('.json')).map(name => {
    try { return { name, time: statSync(join(folder, name)).mtimeMs }; } catch { return null; }
  }).filter(Boolean).sort((a, b) => b.time - a.time || b.name.localeCompare(a.name));
}

export function storeSnapshot(value, root = ROOT) {
  const folder = join(root, SNAPSHOT_DIR);
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(root, '.automation/.gdignore'), '');
  writeAtomic(join(folder, `${value.fingerprint}.json`), JSON.stringify({ ...value, observed_at: new Date().toISOString() }));
  for (const old of storedSnapshots(folder).slice(KEEP_SNAPSHOTS)) rmSync(join(folder, old.name), { force: true });
}

// baseline: "since" (the caller's fingerprint), "last" (status without --since: the
// most recent stored snapshot), "stale" (--since unknown or pruned; compared with the
// most recent stored snapshot instead), or "none" (nothing stored; review everything).
export function findBaseline(since, root = ROOT) {
  const folder = join(root, SNAPSHOT_DIR);
  if (since && FINGERPRINT.test(since)) {
    const previous = readJson(join(folder, `${since}.json`), null);
    if (previous) return { baseline: 'since', previous };
  }
  for (const { name } of storedSnapshots(folder)) {
    const previous = readJson(join(folder, name), null);
    if (previous) return { baseline: since ? 'stale' : 'last', previous };
  }
  return { baseline: 'none', previous: null };
}

// When the viewer is itself an approver (the maintainer's own token), approver
// comments are never marked self: they are human input, not the worker's output.
function person(user, context, viewerDidAuthor) {
  const login = user?.login ?? null;
  const approver = Boolean(user) && context.policy.approvers.some(a => (user.id != null ? a.id === user.id : a.login === login));
  const self = Boolean(viewerDidAuthor) || Boolean(context.viewer && user
    && (user.id != null ? user.id === context.viewer.id : login === context.viewer.login));
  return { author: login, approver, self: self && !approver };
}

const byKey = (values = [], key = v => v.id) => new Map((values || []).map(v => [key(v), v]));

function checkState(check) {
  if (check.__typename === 'StatusContext' || (check.state && !check.status)) {
    return { SUCCESS: 'pass', FAILURE: 'fail', ERROR: 'fail', PENDING: 'pending', EXPECTED: 'pending' }[check.state] || String(check.state).toLowerCase();
  }
  if (check.status !== 'COMPLETED') return 'pending';
  return { SUCCESS: 'pass', NEUTRAL: 'pass', SKIPPED: 'skipped', FAILURE: 'fail', TIMED_OUT: 'fail', ACTION_REQUIRED: 'fail',
    STARTUP_FAILURE: 'fail', CANCELLED: 'cancelled', STALE: 'stale' }[check.conclusion] || String(check.conclusion).toLowerCase();
}
const checkName = c => [c.workflowName, c.name || c.context].filter(Boolean).join('/');
// Duplicate names (e.g. a matrix without distinct job names) get an ordinal suffix.
function keyedChecks(checks = []) {
  const seen = new Map();
  return new Map((checks || []).map(check => {
    const name = checkName(check);
    const count = (seen.get(name) || 0) + 1;
    seen.set(name, count);
    return [count > 1 ? `${name}#${count}` : name, check];
  }));
}

// gh PR JSON and REST comments differ in field names; compare them in one shape.
const normalizeComment = (c, gh) => gh
  ? { id: c.id, user: c.author, body: c.body ?? '', created: c.createdAt, updated: c.updatedAt ?? null, url: c.url, viewerDidAuthor: c.viewerDidAuthor }
  : { id: c.id, user: c.user, body: c.body ?? '', created: c.created_at, updated: c.updated_at ?? null, url: c.url,
    path: c.path, line: c.line, in_reply_to: c.in_reply_to };

// REST results for PRs that left the open list, converted to the stored gh shape
// (gh uses GraphQL node IDs, which REST reports as node_id).
export const ghComment = c => ({ id: c.node_id, author: { login: c.user?.login, id: c.user?.id }, body: c.body,
  createdAt: c.created_at, updatedAt: c.updated_at, url: c.html_url });
export const ghReview = r => ({ id: r.node_id, author: { login: r.user?.login, id: r.user?.id }, state: r.state, body: r.body,
  submittedAt: r.submitted_at, commit: { oid: r.commit_id } });

function commentChanges(items, kind, number, before, after, context, { type = 'comment', gh = false, fallbackAt } = {}) {
  const old = new Map((before || []).map(c => [c.id, normalizeComment(c, gh)]));
  const current = new Set((after || []).map(c => c.id));
  for (const raw of after || []) {
    const c = normalizeComment(raw, gh);
    const previous = old.get(c.id);
    if (previous && previous.body === c.body && (!previous.updated || !c.updated || previous.updated === c.updated)) continue;
    const change = previous ? 'edited' : 'new';
    const item = { type, kind, number, id: c.id, change, ...person(c.user, context, c.viewerDidAuthor),
      at: change === 'edited' ? (c.updated || fallbackAt || c.created) : c.created,
      created_at: c.created, updated_at: c.updated, body: c.body, url: c.url };
    if (type === 'inline_comment') Object.assign(item, { path: c.path, line: c.line, in_reply_to: c.in_reply_to });
    if (type === 'comment' && c.body.includes(PREVIEW_MARKER)) {
      item.type = 'preview';
      item.sha = /Deployed commit: `([0-9a-f]{7,40})`/.exec(c.body)?.[1] ?? null;
    }
    items.push(item);
  }
  for (const [id, c] of old) {
    if (!current.has(id)) {
      items.push({ type, kind, number, id, change: 'deleted', ...person(c.user, context, c.viewerDidAuthor),
        at: fallbackAt ?? null, body: c.body, url: c.url });
    }
  }
}

function reviewChanges(items, number, before, after, context, { url, fallbackAt } = {}) {
  const old = byKey(before);
  const current = byKey(after);
  for (const review of after || []) {
    const prior = old.get(review.id);
    if (prior && prior.state === review.state && (prior.body ?? '') === (review.body ?? '')) continue;
    items.push({ type: 'review', kind: 'pull_request', number, id: review.id, change: prior ? 'edited' : 'new',
      ...person(review.author, context), state: review.state, previous_state: prior?.state ?? null,
      commit: review.commit?.oid ?? null, body: review.body ?? '', at: review.submittedAt || fallbackAt || null, url });
  }
  for (const review of before || []) {
    if (!current.has(review.id)) {
      items.push({ type: 'review', kind: 'pull_request', number, id: review.id, change: 'deleted', ...person(review.author, context),
        state: null, previous_state: review.state, body: review.body ?? '', at: fallbackAt ?? null, url });
    }
  }
}

function approvalChange(before, after) {
  if (after.approved && !before.approved) return 'approved';
  if (!after.approved && before.approved) return after.reason === 'held by maintainer' ? 'held' : 'revoked';
  if (after.approved && (after.comment_id !== before.comment_id || after.scope !== before.scope)) return 'reapproved';
  if (!after.approved && after.reason !== before.reason) return 'reason';
  return null;
}

// Returns every observable change between two snapshots, oldest first. Items are
// self-contained so the coordinator can act on them without diffing snapshots.
// Nothing is dropped: the caller's own comments are marked self: true. Issues and
// PRs that leave the open lists get one final look (state plus comments/reviews);
// later activity on already-closed items is not watched.
export function activity(previous, current, context) {
  const items = [];
  const lookup = (fn, number) => { try { return fn(number) || {}; } catch (error) { return { error: error.message }; } };
  const reappeared = created => Boolean(previous.observed_at && created && created < previous.observed_at);
  const oldIssues = byKey(previous.issues, i => i.number);
  const newIssues = byKey(current.issues, i => i.number);
  for (const issue of current.issues) {
    const old = oldIssues.get(issue.number);
    const base = { type: 'issue', number: issue.number, title: issue.title, url: issue.url, at: issue.updated_at };
    if (!old) {
      items.push({ ...base, change: reappeared(issue.created_at) ? 'reopened' : 'opened', author: issue.author ?? null,
        labels: issue.labels, body: issue.body ?? '' });
    } else {
      if (old.title !== issue.title || (old.body ?? '') !== (issue.body ?? '')) {
        items.push({ ...base, change: 'edited', previous_title: old.title, body: issue.body ?? '' });
      }
      const added = issue.labels.filter(l => !old.labels.includes(l));
      const removed = old.labels.filter(l => !issue.labels.includes(l));
      if (added.length || removed.length) items.push({ ...base, change: 'labels', added, removed });
    }
    const beforeApproval = old?.approval || { approved: false, reason: null };
    const change = approvalChange(beforeApproval, issue.approval);
    if (change && (old || issue.approval.approved)) {
      const command = issue.comments.find(c => c.id === issue.approval.comment_id)
        || issue.comments.filter(c => context.policy.approvers.some(a => a.id === c.user?.id)
          && ['/approve', '/hold'].includes((c.body || '').trim())).at(-1);
      items.push({ type: 'approval', number: issue.number, change, approved: issue.approval.approved,
        reason: issue.approval.reason, previous_reason: beforeApproval.reason ?? null, comment_id: issue.approval.comment_id ?? command?.id ?? null,
        url: issue.approval.url ?? command?.url ?? issue.url, at: command?.created_at ?? issue.updated_at });
    }
    commentChanges(items, 'issue', issue.number, old?.comments, issue.comments, context, { fallbackAt: issue.updated_at });
  }
  for (const old of previous.issues) {
    if (newIssues.has(old.number)) continue;
    const live = lookup(context.lookupIssue, old.number);
    const at = live.closed_at ?? live.updated_at ?? null;
    items.push({ type: 'issue', number: old.number, title: old.title, url: old.url,
      change: live.state === 'closed' ? 'closed' : 'gone', state: live.state ?? null, state_reason: live.state_reason ?? null,
      closed_by: live.closed_by?.login ?? null, error: live.error ?? live.comments_error, at });
    if (Array.isArray(live.comments)) commentChanges(items, 'issue', old.number, old.comments, live.comments, context, { fallbackAt: at });
  }

  const oldPulls = byKey(previous.pull_requests, p => p.number);
  const newPulls = byKey(current.pull_requests, p => p.number);
  for (const pr of current.pull_requests) {
    const old = oldPulls.get(pr.number);
    const base = { type: 'pull_request', number: pr.number, title: pr.title, url: pr.url, head_sha: pr.headRefOid, at: pr.updatedAt };
    if (!old) {
      items.push({ ...base, change: reappeared(pr.createdAt) ? 'reopened' : 'opened', author: pr.author?.login ?? null,
        base: pr.baseRefName, head: pr.headRefName, draft: pr.isDraft, body: pr.body ?? '' });
    } else {
      if (old.headRefOid !== pr.headRefOid) items.push({ ...base, change: 'head', previous_head_sha: old.headRefOid });
      if (old.headRefName !== pr.headRefName) items.push({ ...base, change: 'head_ref', head: pr.headRefName, previous_head: old.headRefName });
      if (old.baseRefName !== pr.baseRefName) items.push({ ...base, change: 'base', base: pr.baseRefName, previous_base: old.baseRefName });
      if (old.title !== pr.title || (old.body ?? '') !== (pr.body ?? '')) items.push({ ...base, change: 'edited', previous_title: old.title, body: pr.body ?? '' });
      if (old.isDraft !== pr.isDraft) items.push({ ...base, change: pr.isDraft ? 'draft' : 'ready_for_review' });
      if (old.reviewDecision !== pr.reviewDecision) {
        items.push({ ...base, change: 'review_decision', review_decision: pr.reviewDecision || null, previous: old.reviewDecision || null });
      }
    }
    const oldChecks = keyedChecks(old?.statusCheckRollup);
    const newChecks = keyedChecks(pr.statusCheckRollup);
    for (const [name, check] of newChecks) {
      const from = oldChecks.has(name) ? checkState(oldChecks.get(name)) : null;
      const to = checkState(check);
      if (from !== to) {
        items.push({ type: 'check', number: pr.number, name, from, to, head_sha: pr.headRefOid,
          url: check.detailsUrl || check.targetUrl || null, at: check.completedAt || check.startedAt || pr.updatedAt });
      }
    }
    for (const [name, check] of oldChecks) {
      if (!newChecks.has(name)) {
        items.push({ type: 'check', number: pr.number, name, from: checkState(check), to: null, head_sha: pr.headRefOid,
          url: check.detailsUrl || check.targetUrl || null, at: pr.updatedAt });
      }
    }
    commentChanges(items, 'pull_request', pr.number, old?.comments, pr.comments, context, { gh: true, fallbackAt: pr.updatedAt });
    commentChanges(items, 'pull_request', pr.number, old?.inline_comments, pr.inline_comments, context,
      { type: 'inline_comment', fallbackAt: pr.updatedAt });
    reviewChanges(items, pr.number, old?.reviews, pr.reviews, context, { url: pr.url, fallbackAt: pr.updatedAt });
  }
  for (const old of previous.pull_requests) {
    if (newPulls.has(old.number)) continue;
    const live = lookup(context.lookupPull, old.number);
    const change = live.merged_at ? 'merged' : live.state === 'closed' ? 'closed' : live.state === 'open' ? 'unlisted' : 'gone';
    const at = live.merged_at || live.closed_at || live.updated_at || null;
    items.push({ type: 'pull_request', number: old.number, title: old.title, url: old.url, change,
      head_sha: live.head?.sha ?? old.headRefOid, merged_by: live.merged_by?.login ?? null,
      merge_commit_sha: live.merged_at ? live.merge_commit_sha ?? null : null, error: live.error ?? live.comments_error, at });
    if (Array.isArray(live.comments)) commentChanges(items, 'pull_request', old.number, old.comments, live.comments, context, { gh: true, fallbackAt: at });
    if (Array.isArray(live.inline_comments)) {
      commentChanges(items, 'pull_request', old.number, old.inline_comments, live.inline_comments, context, { type: 'inline_comment', fallbackAt: at });
    }
    if (Array.isArray(live.reviews)) reviewChanges(items, old.number, old.reviews, live.reviews, context, { url: old.url, fallbackAt: at });
  }

  const stackKey = s => s.number ?? s.id;
  const describe = s => ({ open: s.open, base: s.base?.ref ?? null, pull_requests: (s.pull_requests || []).map(p => p.number) });
  const oldStacks = byKey(previous.stacks, stackKey);
  const newStacks = byKey(current.stacks, stackKey);
  for (const s of current.stacks || []) {
    const before = oldStacks.get(stackKey(s));
    const now = describe(s);
    if (!before) items.push({ type: 'stack', number: stackKey(s), change: 'created', ...now, at: s.updated_at ?? s.created_at ?? null });
    else if (JSON.stringify(describe(before)) !== JSON.stringify(now)) {
      items.push({ type: 'stack', number: stackKey(s), change: 'changed', ...now, previous: describe(before), at: s.updated_at ?? null });
    }
  }
  for (const s of previous.stacks || []) {
    if (!newStacks.has(stackKey(s))) items.push({ type: 'stack', number: stackKey(s), change: 'removed', ...describe(s), at: null });
  }

  const oldJobs = previous.jobs || {};
  const newJobs = current.jobs || {};
  for (const [number, job] of Object.entries(newJobs)) {
    const before = oldJobs[number];
    if (!before || before.phase !== job.phase || before.recovery_reason !== job.recovery_reason || before.pr !== job.pr) {
      items.push({ type: 'job', number: Number(number), change: before ? 'updated' : 'added', from: before?.phase ?? null,
        to: job.phase, reason: job.recovery_reason ?? null, pr: job.pr ?? null, at: null });
    }
  }
  for (const [number, job] of Object.entries(oldJobs)) {
    if (!(number in newJobs)) items.push({ type: 'job', number: Number(number), change: 'removed', from: job.phase, to: null, at: null });
  }
  // Stable sort: timed items oldest first; untimed local changes last.
  return items.sort((a, b) => (a.at == null) - (b.at == null) || String(a.at ?? '').localeCompare(String(b.at ?? '')));
}

// Adds activity since the caller's fingerprint to a snapshot and stores it as the
// next baseline. The snapshot fields are unchanged for existing callers.
export function observe(github, value, since, root = ROOT) {
  const { baseline, previous } = findBaseline(since, root);
  let viewer = null;
  try { const user = github.api('user'); viewer = { id: user.id, login: user.login }; } catch { /* self marks fall back to viewerDidAuthor */ }
  const list = (suffix, convert) => github.api(github.endpoint(`${suffix}?per_page=100`), { paginate: true }).map(convert);
  // Final look at items that left the open lists: state, plus comments/reviews so a
  // closing comment or last-minute review is still itemized.
  const final = (value, lists) => {
    for (const [key, fetch] of Object.entries(lists)) {
      try { value[key] = fetch(); } catch (error) { value.comments_error = error.message; }
    }
    return value;
  };
  const items = previous ? activity(previous, value, { policy: github.policy, viewer,
    lookupPull: number => final(github.pull(number), {
      comments: () => list(`issues/${number}/comments`, ghComment),
      inline_comments: () => list(`pulls/${number}/comments`, compactComment),
      reviews: () => list(`pulls/${number}/reviews`, ghReview) }),
    lookupIssue: number => final(github.api(github.endpoint(`issues/${number}`)), {
      comments: () => list(`issues/${number}/comments`, compactComment) }) }) : [];
  storeSnapshot(value, root);
  return { fingerprint: value.fingerprint, generated_at: new Date().toISOString(), baseline,
    baseline_fingerprint: previous?.fingerprint ?? null, viewer: viewer?.login ?? null, activity: items, ...value };
}

const firstLine = text => {
  const line = String(text ?? '').split('\n').map(l => l.trim()).find(l => l && !l.startsWith('<!--')) ?? '';
  return line.length > 100 ? `${line.slice(0, 99)}…` : line;
};

export function summarize(item) {
  const who = item.author ? ` ${item.author}${item.approver ? ' (approver)' : ''}${item.self ? ' (self)' : ''}` : '';
  const ref = `#${item.number}`;
  switch (item.type) {
    case 'comment': case 'inline_comment':
      return `${item.type} ${ref}${who} ${item.change}${item.path ? ` ${item.path}:${item.line ?? ''}` : ''}: ${firstLine(item.body)}`;
    case 'preview': return `preview ${ref}${who} ${item.change}: ${item.sha ?? 'unknown sha'}`;
    case 'review': return `review ${ref}${who} ${item.change} ${item.state ?? item.previous_state}: ${firstLine(item.body)}`;
    case 'approval': return `approval ${ref} ${item.change}: ${item.reason}`;
    case 'check': return `check ${ref} ${item.name} ${item.from ?? 'new'} -> ${item.to ?? 'removed'}`;
    case 'issue': case 'pull_request': {
      const detail = { labels: `+[${(item.added || []).join(',')}] -[${(item.removed || []).join(',')}]`,
        head: `${item.previous_head_sha?.slice(0, 7)} -> ${item.head_sha?.slice(0, 7)}`,
        head_ref: `${item.previous_head} -> ${item.head}`,
        base: `${item.previous_base} -> ${item.base}`, review_decision: `${item.previous} -> ${item.review_decision}`,
        closed: item.state_reason || '', merged: item.merged_by ? `by ${item.merged_by}` : '' }[item.change] ?? firstLine(item.title);
      return `${item.type} ${ref}${who} ${item.change}${item.error ? ` (lookup failed: ${item.error})` : ''}: ${detail}`;
    }
    case 'stack': return `stack ${ref} ${item.change}: [${item.pull_requests.join(',')}]${item.open === false ? ' closed' : ''}`;
    case 'job': return `job ${ref} ${item.change}: ${item.from ?? '-'} -> ${item.to ?? '-'}${item.reason ? ` (${item.reason})` : ''}`;
    default: return `${item.type} ${ref}`;
  }
}

// Repeats bounded `watch` calls until the fingerprint changes. Designed for a
// background command: stdout is a short summary, the full JSON goes to `out`.
export const RATE_LIMITED = /rate limit|secondary rate|HTTP 429|abuse detection/i;

export function watchUntilChange({ since, out }, { execute, sleep, log = console.log, warn = console.error, maxFailures = 5,
  rateLimitReset = () => null, now = Date.now }) {
  let failures = 0;
  for (;;) {
    try {
      const text = execute(since ? ['watch', '--since', since, '--seconds', '60'] : ['status']);
      const value = JSON.parse(text);
      if (typeof value.fingerprint !== 'string' || !Array.isArray(value.activity)) throw new Error('watch output lacks fingerprint/activity');
      failures = 0;
      if (since && value.fingerprint === since) continue;
      writeAtomic(out, `${text.trimEnd()}\n`);
      log(`CHANGED baseline=${value.baseline} items=${value.activity.length} json=${out}`);
      if (value.baseline !== 'since') log(`BASELINE ${value.baseline}: itemized activity may be incomplete; review the full snapshot`);
      for (const item of value.activity) log(summarize(item));
      if (!value.activity.length) log('(no itemized activity; inspect the snapshot)');
      log(`fingerprint ${value.fingerprint}`);
      return 0;
    } catch (error) {
      const message = String(error.message || error).split('\n').slice(0, 5).join(' ');
      // A rate limit is not a persistent failure: wait for its reset without
      // consuming retries. The reset comes from the free rate_limit endpoint.
      if (RATE_LIMITED.test(message)) {
        let reset = null;
        try { reset = rateLimitReset(); } catch { /* fall back to a fixed wait */ }
        const wait = Math.min(3_600_000, Math.max(5_000, reset ? reset - now() + 5_000 : 300_000));
        warn(`RATE_LIMITED: waiting ${Math.round(wait / 1000)}s until ${new Date(now() + wait).toISOString()}: ${message}`);
        sleep(wait);
        continue;
      }
      failures++;
      if (failures >= maxFailures) {
        log(`PERSISTENT_ERROR after ${failures} consecutive failures: ${message}`);
        return 1;
      }
      warn(`watch failed (${failures}/${maxFailures}), retrying in ${60 * failures}s: ${message}`);
      sleep(60_000 * failures);
    }
  }
}

export function requireApproval(github, number) {
  const result = github.issue(number);
  if (!result.decision.approved) throw new Error(`Issue #${number}: ${result.decision.reason}`);
  return result;
}

export function checkJob(github, number, root = ROOT, { recovery = false } = {}) {
  const { decision } = requireApproval(github, number);
  const state = loadState(root);
  const job = state.jobs[number];
  if (!job) throw new Error('Claim the issue before checking authorization for work');
  if (recovery && job?.phase !== 'recovering') throw new Error('Claim with --recover before checking Git recovery authorization');
  if (!recovery && job?.phase === 'recovering') throw new Error('Only local Git recovery is authorized; complete recovery and claim normally before implementation or push');
  if (job && job.approval.scope !== decision.scope) throw new Error('Approved scope changed; claim again and revise the plan before continuing');
  if (job && ['blocked', 'done', 'held'].includes(job.phase)) throw new Error('This attempt ended or is held; check approval and claim again before continuing');
  if (job?.base_issue) {
    const dependency = parentBase(github, job.base_issue, state, job.worker_id, number);
    if (dependency.sha !== job.base_sha || digest(dependency.chain) !== digest(job.dependencies || [])) {
      throw new Error('Parent branch changed somewhere in the dependency chain; recover and claim again');
    }
  }
  if (job?.pr) {
    const pr = github.pull(job.pr);
    if (pr.state !== 'open' || pr.head.ref !== job.branch || pr.base.ref !== job.base_ref) {
      throw new Error('PR state or base changed; reconcile and claim again before continuing');
    }
  }
  return decision;
}

export function sync(github, number) {
  for (const brief of number ? [{ number }] : github.issues()) {
    const { issue, decision } = github.issue(brief.number);
    const existing = new Set(issue.labels.map(l => l.name));
    let desired = issue.state === 'closed' || existing.has('question') ? null : 'needs-approval';
    if (desired && decision.approved) desired = ['in-review', 'in-progress', 'blocked'].find(l => existing.has(l)) || 'ready';
    github.labels(issue, desired);
  }
}

export function normalizePaths(value = '.') {
  const values = Array.isArray(value) ? value : value.split(',');
  const paths = values.map(v => v.trim().replace(/^\.\//, '').replace(/\/+$/, ''));
  if (!paths.length || paths.some(p => !p || p.startsWith('/') || /[\\\x00-\x1f*?\[\]]/.test(p)
      || (p !== '.' && p.split('/').some(part => !part || part === '.' || part === '..')))) {
    throw new Error('--paths must contain literal repository-relative files/directories (or . for unknown scope)');
  }
  return [...new Set(paths)].sort();
}

export const pathsOverlap = (left, right) => left.some(a => right.some(b =>
  a === '.' || b === '.' || a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`)));

function ownedPull(pr, github, workerId, branch) {
  if (pr.state !== 'open' || pr.user?.id !== workerId || pr.head.repo?.full_name !== github.repo
      || pr.base.repo?.full_name !== github.repo || (branch && pr.head.ref !== branch)) {
    throw new Error('Expected an open same-repository PR owned by the worker on the planned branch');
  }
}

function parentBase(github, parentNumber, state, workerId, childNumber) {
  const seen = new Set([Number(childNumber)]);
  const chain = [];
  let current = Number(parentNumber);
  while (current) {
    if (seen.has(current)) throw new Error('Issue dependency cycle');
    seen.add(current);
    if (seen.size > (github.policy.max_stack_depth || 3)) throw new Error('Maximum PR stack depth exceeded');
    const { decision } = requireApproval(github, current);
    const parent = state.jobs[current];
    if (!parent || parent.phase !== 'in-review' || !parent.pr || parent.approval?.scope !== decision.scope) {
      throw new Error(`Parent issue #${current} must have a current approved in-review checkpoint and PR`);
    }
    const branch = `ai/issue-${current}`;
    const pr = github.pull(parent.pr);
    ownedPull(pr, github, workerId, branch);
    chain.push({ issue: current, pr: pr.number, branch, sha: pr.head.sha,
      approval_id: decision.comment_id, scope: decision.scope });
    if (pr.base.ref === github.policy.default_branch) break;
    const match = /^ai\/issue-([1-9][0-9]*)$/.exec(pr.base.ref);
    if (!match) throw new Error('Parent PR chain must terminate at the default branch');
    current = Number(match[1]);
  }
  return { ref: chain[0].branch, sha: chain[0].sha, issue: Number(parentNumber), chain };
}

// Serial, local-only recovery: preserve worktrees, notes and branches; never start a
// worker or infer authorization from labels. Run before dispatch after every restart.
export function reconcile(github, root = ROOT) {
  const state = loadState(root);
  const changes = [];
  const open = github.pulls();
  for (const [number, job] of Object.entries(state.jobs)) {
    const { issue, decision } = github.issue(Number(number));
    const linked = open.find(p => p.headRefName === job.branch);
    const pr = (linked || job.pr) ? github.pull(linked?.number || job.pr) : null;
    let phase = job.phase;
    let reason;
    if (issue.state === 'closed' || pr?.merged_at) {
      phase = 'done'; reason = pr?.merged_at ? 'PR merged' : 'issue closed';
    } else if (pr?.state === 'closed') {
      phase = 'blocked'; reason = 'PR closed without merging; new approval required';
    } else if (!decision.approved || job.approval?.scope !== decision.scope) {
      phase = 'held'; reason = decision.approved ? 'scope changed; replan and claim again' : decision.reason;
    } else if (job.base_issue) {
      try {
        const parent = parentBase(github, job.base_issue, state, job.worker_id, Number(number));
        if (parent.sha !== job.base_sha || digest(parent.chain) !== digest(job.dependencies || [])) {
          phase = 'held'; reason = 'parent dependency chain changed; recover and claim again';
        }
      } catch (error) { phase = 'held'; reason = `dependency needs attention: ${error.message}`; }
    }
    if (pr && job.pr !== pr.number) job.pr = pr.number;
    if (phase !== job.phase || (reason && reason !== job.recovery_reason)) {
      changes.push({ number: Number(number), from: job.phase, to: phase, reason });
      job.phase = phase;
      job.recovery_reason = reason;
    }
    if (['blocked', 'done'].includes(phase)) job.ended_approval_id = job.approval?.comment_id;
  }
  saveState(state, root);
  return { changes, jobs: state.jobs };
}

// CLI serializes claim/checkpoint/reconcile with flock. Exported functions are used by tests.
export function claim(github, number, root = ROOT, execute = run, options = {}) {
  const worker = github.worker();
  let { issue, decision } = requireApproval(github, number);
  const initialApproval = { scope: decision.scope, comment_id: decision.comment_id };
  const state = loadState(root);
  const old = state.jobs[number];
  if (old && ((['blocked', 'done'].includes(old.phase) && old.approval.comment_id === decision.comment_id)
      || old.ended_approval_id === decision.comment_id)) {
    throw new Error('This attempt ended. A new human /approve is needed to retry it.');
  }
  const active = Object.entries(state.jobs).filter(([n, j]) => ['working', 'recovering'].includes(j.phase) && n !== String(number));
  if (active.length >= github.policy.max_active_issues) throw new Error('Active issue limit reached; checkpoint the current work first');
  const paths = normalizePaths(options.paths ?? old?.paths ?? '.');
  for (const [other, job] of active) {
    if (pathsOverlap(paths, normalizePaths(job.paths || '.'))) throw new Error(`Planned paths overlap active issue #${other}; serialize that work or revise the scopes`);
  }
  const branch = `ai/issue-${number}`;
  const pulls = github.pulls();
  const linked = pulls.find(p => p.headRefName === branch);
  const previousPr = old?.pr && !linked ? github.pull(old.pr) : null;
  if (previousPr?.state === 'open') throw new Error('Stored PR is open but missing from the queue listing; reconcile before claiming');
  if (previousPr && old.approval.comment_id === decision.comment_id) throw new Error('Previous PR ended; reconcile and obtain a new human /approve before retrying');
  if (!linked && pulls.filter(p => p.headRefName.startsWith('ai/issue-')).length >= github.policy.max_open_prs) {
    throw new Error('Open AI PR limit reached; wait for review');
  }
  const livePr = linked ? github.pull(linked.number) : null;
  if (livePr) ownedPull(livePr, github, worker.id, branch);
  // A live PR's target is authoritative (for example after its parent was merged).
  // Never silently reuse a checkpoint's old base when GitHub has retargeted it.
  let parentNumber = options['base-issue'] ?? (previousPr ? null : old?.base_issue) ?? null;
  if (livePr) {
    const actualParent = livePr.base.ref === github.policy.default_branch ? null
      : Number(/^ai\/issue-([1-9][0-9]*)$/.exec(livePr.base.ref)?.[1]);
    if (Number.isNaN(actualParent)) throw new Error('Existing PR has an unsupported base branch');
    if (options['base-issue'] && Number(options['base-issue']) !== actualParent) throw new Error('Requested parent differs from the live PR base; retarget the PR deliberately first');
    parentNumber = actualParent;
  }
  let base = parentNumber ? parentBase(github, parentNumber, state, worker.id, number)
    : { ref: github.policy.default_branch, issue: null, chain: [] };
  execute(['git', 'fetch', 'origin'], { cwd: root });
  const baseSha = execute(['git', 'rev-parse', `refs/remotes/origin/${base.ref}`], { cwd: root });
  if (base.sha && base.sha !== baseSha) throw new Error('Parent head changed while fetching; retry after rechecking its PR');
  base.sha = baseSha;
  let remoteSha;
  if (livePr) {
    remoteSha = execute(['git', 'rev-parse', `refs/remotes/origin/${branch}`], { cwd: root });
    if (remoteSha !== livePr.head.sha) throw new Error('PR head changed while fetching; recheck and claim again');
  }
  const path = join(root, '.worktrees', `issue-${number}`);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(join(dirname(path), '.gdignore'), '');
  if (existsSync(path)) {
    const actual = execute(['git', 'branch', '--show-current'], { cwd: path });
    if (actual !== branch) throw new Error(`Existing worktree is on unexpected branch ${actual}`);
  } else {
    const refs = execute(['git', 'for-each-ref', '--format=%(refname)'], { cwd: root }).split('\n');
    if (refs.includes(`refs/heads/${branch}`)) execute(['git', 'worktree', 'add', path, branch], { cwd: root });
    else execute(['git', 'worktree', 'add', '-b', branch, path,
      refs.includes(`refs/remotes/origin/${branch}`) ? `origin/${branch}` : `origin/${base.ref}`], { cwd: root });
  }
  let recoveryAction;
  if (options.recover && remoteSha) {
    const dirty = execute(['git', 'status', '--porcelain'], { cwd: path });
    const head = execute(['git', 'rev-parse', 'HEAD'], { cwd: path });
    if (dirty) recoveryAction = 'Uncommitted changes preserved; inspect and save them before any rebase.';
    else if (head !== remoteSha) {
      let canFastForward = false;
      try { execute(['git', 'merge-base', '--is-ancestor', 'HEAD', remoteSha], { cwd: path }); canFastForward = true; }
      catch { /* Divergence requires deliberate recovery; never overwrite local commits. */ }
      if (canFastForward) {
        execute(['git', 'merge', '--ff-only', remoteSha], { cwd: path });
        recoveryAction = 'Clean local branch fast-forwarded to the current PR head.';
      } else recoveryAction = 'Local and remote branches differ; inspect both histories and rebase deliberately. No commits were discarded.';
    }
  }
  if (!options.recover && (parentNumber || old?.phase === 'recovering' || (old?.base_ref && old.base_ref !== base.ref))) {
    try { execute(['git', 'merge-base', '--is-ancestor', base.sha, 'HEAD'], { cwd: path }); }
    catch { throw new Error('Worktree does not contain the current base head; claim --recover to reserve and authorize local Git recovery, then claim normally'); }
  }
  let pushLease;
  if (!options.recover && remoteSha) {
    try { execute(['git', 'merge-base', '--is-ancestor', remoteSha, 'HEAD'], { cwd: path }); }
    catch {
      if ((old?.phase === 'recovering' || old?.push_lease === remoteSha)
          && old.remote_sha === remoteSha && old.base_sha === base.sha
          && !execute(['git', 'status', '--porcelain'], { cwd: path })) pushLease = remoteSha;
      else throw new Error('Local branch is behind or differs from the PR head; claim --recover before implementation or push');
    }
  }
  // Fetch/build setup may have taken time; revalidate before dispatch.
  ({ issue, decision } = requireApproval(github, number));
  if (decision.scope !== initialApproval.scope || decision.comment_id !== initialApproval.comment_id) {
    throw new Error('Approval or scope changed during setup; replan and claim again');
  }
  if (parentNumber) {
    const current = parentBase(github, parentNumber, state, worker.id, number);
    if (current.sha !== base.sha || digest(current.chain) !== digest(base.chain)) {
      throw new Error('Parent dependency chain changed during setup; recover and claim again');
    }
  }
  if (livePr) {
    const current = github.pull(livePr.number);
    ownedPull(current, github, worker.id, branch);
    if (current.base.ref !== base.ref || current.head.sha !== remoteSha) throw new Error('PR base or head changed during setup; claim again');
  }
  const job = { ...old, branch, worktree: path, phase: options.recover ? 'recovering' : 'working', approval: decision, worker_id: worker.id,
    paths, base_ref: base.ref, base_sha: base.sha, base_issue: base.issue, dependencies: base.chain,
    remote_sha: remoteSha, push_lease: pushLease,
    repair_attempts: old?.approval.comment_id === decision.comment_id ? old.repair_attempts || 0 : 0 };
  delete job.recovery_reason;
  if (options.recover) job.recovery = {
    allowed: 'Local Git recovery only. No implementation, branch push, or PR update until ordinary claim succeeds.',
    next: `Check --recovery, inspect worktree and update it to contain ${base.ref} and the current PR head; then claim without --recover.`,
    action: recoveryAction || 'Worktree preserved for deliberate local recovery.',
  };
  else delete job.recovery;
  if (linked) job.pr = linked.number;
  else delete job.pr;
  state.jobs[number] = job;
  saveState(state, root);
  github.labels(issue, 'in-progress');
  return job;
}

export function checkpoint(github, args, root = ROOT) {
  const state = loadState(root);
  const job = state.jobs[args.number];
  if (!job) throw new Error('Claim the issue before checkpointing it');
  if (args.pr && args.phase !== 'in-review') {
    const pr = github.pull(args.pr);
    ownedPull(pr, github, job.worker_id, job.branch);
    if (pr.base.ref !== job.base_ref) throw new Error('PR base does not match the planned base');
  }
  if (args.phase === 'working' && job.phase !== 'working') throw new Error('Use claim to resume work and enforce concurrency/dependency checks');
  if (args.phase === 'in-review') {
    checkJob(github, args.number, root);
    const prNumber = args.pr || job.pr;
    if (!prNumber) throw new Error('An in-review checkpoint requires --pr NUMBER');
    const pr = github.pull(prNumber);
    ownedPull(pr, github, job.worker_id, job.branch);
    if (pr.base.ref !== job.base_ref) throw new Error('PR base does not match the planned base');
  }
  if (args.phase) job.phase = args.phase;
  if (args['notes-file']) job.notes = readFileSync(args['notes-file'], 'utf8');
  if (args.session) job.session = args.session;
  if (args.pr) job.pr = Number(args.pr);
  if (args.repair) {
    job.repair_attempts = (job.repair_attempts || 0) + 1;
    if (job.repair_attempts >= github.policy.max_repair_attempts) job.phase = 'blocked';
  }
  if (['blocked', 'done'].includes(job.phase)) job.ended_approval_id = job.approval?.comment_id;
  saveState(state, root);
  return job;
}

// GitHub's native stacks preserve the human merge workflow. This function only
// creates a stack or appends verified PRs; it never merges or retargets anything.
export function stack(github, numbers) {
  if (numbers.length < 2 || numbers.length > (github.policy.max_stack_depth || 3)
      || new Set(numbers).size !== numbers.length || numbers.some(n => !Number.isSafeInteger(n) || n <= 0)) {
    throw new Error('Provide 2..max_stack_depth distinct PR numbers in bottom-to-top order');
  }
  const worker = github.worker();
  const verify = () => {
    let previous = github.policy.default_branch;
    for (const number of numbers) {
      const pr = github.pull(number);
      ownedPull(pr, github, worker.id);
      const match = /^ai\/issue-([1-9][0-9]*)$/.exec(pr.head.ref);
      if (!match || pr.base.ref !== previous) throw new Error('Stack PRs must form an ai/issue-N branch chain rooted at the default branch');
      requireApproval(github, Number(match[1]));
      previous = pr.head.ref;
    }
  };
  verify();
  const existing = github.stacks().filter(s => s.pull_requests.some(p => numbers.includes(p.number)));
  if (existing.length > 1) throw new Error('Requested PRs already belong to conflicting stacks');
  if (existing.length) {
    const current = existing[0];
    const held = current.pull_requests.map(p => p.number);
    if (!current.open || current.base.ref !== github.policy.default_branch
        || held.length > (github.policy.max_stack_depth || 3)
        || !held.slice(0, Math.min(held.length, numbers.length)).every((n, i) => numbers[i] === n)) {
      throw new Error('Existing stack conflicts with the requested order or base');
    }
    if (held.length >= numbers.length) return { action: 'existing', stack: current };
    verify();
    const value = github.api(github.endpoint(`stacks/${current.number}/add`), {
      method: 'POST', data: { pull_requests: numbers.slice(held.length) },
    });
    return { action: 'appended', stack: value };
  }
  verify();
  return { action: 'created', stack: github.api(github.endpoint('stacks'), {
    method: 'POST', data: { pull_requests: numbers },
  }) };
}

export function reply(github, number, commentId, body, { issueBody = false } = {}) {
  if (!body.trim()) throw new Error('Reply cannot be empty');
  const worker = github.worker();
  const comments = github.api(github.endpoint(`issues/${number}/comments?per_page=100`), { paginate: true });
  let marker;
  if (issueBody) {
    const { issue } = github.issue(number);
    if (issue.state !== 'open' || !issue.labels.some(label => label.name === 'question')
        || !github.policy.approvers.some(a => a.id === issue.user?.id)) {
      throw new Error('Reply target must be an open question issue authored by the maintainer');
    }
    marker = `<!-- droplet-reply:issue-body:${scopeHash(issue)} -->`;
  } else {
    const source = comments.find(c => c.id === commentId);
    if (!source || !github.policy.approvers.some(a => a.id === source.user.id)) {
      throw new Error('Reply target must be an existing maintainer comment on this issue');
    }
    marker = `<!-- droplet-reply:${commentId}:${source.updated_at} -->`;
  }
  const previous = comments.find(c => c.user.id === worker.id && (c.body || '').includes(marker));
  if (previous) return { url: previous.html_url, already_replied: true };
  const posted = github.api(github.endpoint(`issues/${number}/comments`), { method: 'POST', data: { body: `${body.trimEnd()}\n\n${marker}` } });
  return { url: posted.html_url, already_replied: false };
}

const HELP = `Usage: node tools/automation/queue.mjs COMMAND [options]
  status [--since HASH]          Read issues, approvals, questions, PR feedback/checks and checkpoints
  watch --since HASH [--seconds 50] Wait for changed GitHub state, for at most 60 seconds
                                 Both add \`activity\`: itemized changes since HASH (or the last stored snapshot)
  watch-until-change [--since HASH] [--out FILE]
                                 Repeat watch until the fingerprint changes (tools/automation/watch-until-change)
  check NUMBER [--recovery]       Verify implementation authorization, or restricted local Git recovery
  claim NUMBER [--paths CSV] [--base-issue NUMBER] [--recover]
                                 Claim independent paths or build atop an approved in-review PR
  reconcile                      Recover closed/merged/held jobs locally without deleting work
  stack --prs N,N[,N]             Create/append a native GitHub PR stack, bottom to top; never merge
  checkpoint NUMBER [--phase working|in-review|blocked|done] [--notes-file FILE]
                    [--session ID] [--pr NUMBER] [--repair]
  reply NUMBER --comment ID --body-file FILE   Answer a human comment, even before approval
  reply NUMBER --issue-body --body-file FILE   Answer a maintainer's question in the issue body
  propose --title TITLE --body-file FILE      File a discovered issue after checking duplicates
  sync-labels [--number NUMBER]   Reconcile visible labels from human approval
  setup-labels                   Create/update workflow labels
Run this helper from the canonical controller checkout, never its linked worker worktrees.
`;

export function parseArgs(argv) {
  const [command, ...rest] = argv;
  const specs = {
    status: ['since'], watch: ['since', 'seconds'], 'watch-until-change': ['since', 'out'], check: ['recovery'], claim: ['paths', 'base-issue', 'recover'], reconcile: [], stack: ['prs'],
    checkpoint: ['phase', 'notes-file', 'session', 'pr', 'repair'],
    reply: ['comment', 'issue-body', 'body-file'], propose: ['title', 'body-file'], 'sync-labels': ['number'], 'setup-labels': [],
  };
  if (!(command in specs)) throw new Error(HELP);
  const args = { command };
  if (['check', 'claim', 'checkpoint', 'reply'].includes(command)) args.number = rest.shift();
  while (rest.length) {
    const key = rest.shift().replace(/^--/, '');
    if (!specs[command].includes(key)) throw new Error(`Unknown option: ${key}`);
    args[key] = ['repair', 'recover', 'recovery', 'issue-body'].includes(key) ? true : rest.shift();
    if (args[key] === undefined) throw new Error(`Missing value for ${key}`);
  }
  for (const key of ['number', 'comment', 'pr', 'base-issue']) {
    if (args[key] !== undefined) {
      if (!/^[1-9][0-9]*$/.test(args[key])) throw new Error(`${key} must be a positive integer`);
      args[key] = Number(args[key]);
      if (!Number.isSafeInteger(args[key])) throw new Error(`${key} is too large`);
    }
  }
  if (['check', 'claim', 'checkpoint', 'reply'].includes(command) && !args.number) throw new Error('Issue number is required');
  if (command === 'watch' && !args.since) throw new Error('--since is required');
  if (command === 'reply' && (!args['body-file'] || Boolean(args.comment) === Boolean(args['issue-body']))) {
    throw new Error('Reply requires --body-file and exactly one of --comment or --issue-body');
  }
  if (command === 'propose' && (!args.title || !args['body-file'])) throw new Error('--title and --body-file are required');
  if (command === 'stack') {
    if (!args.prs || !/^[1-9][0-9]*(,[1-9][0-9]*)+$/.test(args.prs)) throw new Error('--prs must list at least two PR numbers');
    args.prs = args.prs.split(',').map(Number);
  }
  if (args.paths !== undefined) args.paths = normalizePaths(args.paths);
  if (args.phase && !['working', 'in-review', 'blocked', 'done'].includes(args.phase)) throw new Error('Invalid phase');
  args.seconds = Number(args.seconds ?? 50);
  if (!Number.isInteger(args.seconds) || args.seconds < 1 || args.seconds > 60) throw new Error('--seconds must be 1..60');
  return args;
}

function main() {
  if (process.argv.includes('--help')) { console.log(HELP); return; }
  const args = parseArgs(process.argv.slice(2));
  const gitDir = run(['git', 'rev-parse', '--absolute-git-dir']);
  const commonDir = run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir']);
  if (gitDir !== commonDir) throw new Error('Run the canonical controller checkout helper; worker worktrees must not create independent queue state');
  // Linux is the supported coordinator host. flock releases automatically on crash.
  if (['claim', 'checkpoint', 'reconcile', 'stack'].includes(args.command) && process.env.DROPLET_STATE_LOCKED !== '1') {
    mkdirSync(join(ROOT, '.automation'), { recursive: true });
    execFileSync('flock', ['--exclusive', '--wait', '10', join(ROOT, '.automation/state.lock'),
      process.execPath, fileURLToPath(import.meta.url), ...process.argv.slice(2)], {
      stdio: 'inherit', env: { ...process.env, DROPLET_STATE_LOCKED: '1' },
    });
    return;
  }
  const sleep = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  if (args.command === 'watch-until-change') {
    const out = resolve(args.out ?? join(ROOT, '.automation/watch-last.json'));
    const stored = readJson(out, {}).fingerprint;
    // An unreadable or malformed previous result falls back to a fresh status.
    const since = args.since ?? (FINGERPRINT.test(stored ?? '') ? stored : undefined);
    const self = fileURLToPath(import.meta.url);
    const execute = argv => {
      try {
        return execFileSync(process.execPath, [self, ...argv], {
          encoding: 'utf8', timeout: 600_000, maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
      } catch (error) { throw new Error(error.stderr?.toString().trim() || `watch failed: ${error.code || error.status}`); }
    };
    const rateLimitReset = () => {
      const resources = JSON.parse(run(['gh', 'api', 'rate_limit'])).resources || {};
      const limited = [resources.core, resources.graphql].filter(r => r && r.remaining === 0).map(r => r.reset * 1000);
      return limited.length ? Math.max(...limited) : null;
    };
    process.exitCode = watchUntilChange({ since, out }, { sleep, execute, rateLimitReset });
    return;
  }
  const github = new GitHub(JSON.parse(readFileSync(join(ROOT, '.github/automation.json'), 'utf8')));
  let value;
  switch (args.command) {
    case 'status': value = observe(github, snapshot(github), args.since); break;
    case 'watch': {
      const deadline = Date.now() + args.seconds * 1000;
      do {
        value = snapshot(github);
        if (value.fingerprint !== args.since || Date.now() >= deadline) break;
        sleep(Math.min(30_000, deadline - Date.now()));
      } while (Date.now() <= deadline);
      value = observe(github, value, args.since);
      break;
    }
    case 'check': value = checkJob(github, args.number, ROOT, args); break;
    case 'claim': value = claim(github, args.number, ROOT, run, args); break;
    case 'reconcile': value = reconcile(github); break;
    case 'stack': value = stack(github, args.prs); break;
    case 'checkpoint': value = checkpoint(github, args); break;
    case 'reply': value = reply(github, args.number, args.comment, readFileSync(args['body-file'], 'utf8'),
      { issueBody: args['issue-body'] }); break;
    case 'propose':
      github.worker();
      value = github.api(github.endpoint('issues'), { method: 'POST', data: {
        title: args.title, body: readFileSync(args['body-file'], 'utf8'), labels: ['needs-approval', 'agent-discovered'],
      } });
      break;
    case 'sync-labels': sync(github, args.number); value = { synced: true }; break;
    case 'setup-labels': {
      const current = new Set(github.api(github.endpoint('labels?per_page=100'), { paginate: true }).map(l => l.name));
      for (const [name, [color, description]] of Object.entries(LABELS)) {
        github.api(github.endpoint(`labels${current.has(name) ? `/${name}` : ''}`), {
          method: current.has(name) ? 'PATCH' : 'POST', data: { name, color, description },
        });
      }
      value = { labels: Object.keys(LABELS) };
    }
  }
  console.log(JSON.stringify(value, null, 2));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(`queue: ${error.message}`); process.exitCode = 1; }
}
