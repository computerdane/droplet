---
name: github-loop
description: Manage Droplet's GitHub queue during a user-started development session, including issue discussion, human-approved parallel implementation, native PR stacks, review feedback, and CI repair.
---

# GitHub development loop

Read [the operating guide](../../docs/development-loop.md) once for setup and
commands. Invoke `node tools/automation/queue.mjs` from the trusted controller
checkout; never use a worker's modified helper or policy to authorize its work.

## Choose models deliberately

The manager is GPT-6 Sol. Use the configured `mechanical` (Luna), `implementer`
(Sol), `reviewer` (Sol), `planner` (Astra), and `expert` (Astra) roles when available.
Choose per subtask. Astra is appropriate for extensive planning, unfamiliar
architecture, difficult numerical work, or correctness risks that warrant extra
reasoning. A large feature such as satellite rendering normally deserves an Astra
planning pass; its routine implementation pieces can still go to Sol or Luna.
Record a brief model-selection reason with each delegation. Prefer the least costly
model likely to succeed, start with at most one Astra task at a time, and reassess
after each bounded deliverable. Do not escalate every issue by default. If a model
is unavailable, report it and choose an available alternative without changing
authentication or billing. For explicit model overrides, provide a focused task
brief rather than assuming a full-history fork can change its inherited model.

Starting this loop authorizes issue/PR comments, discovered issue creation, issue
branch pushes, PR creation, and native stack registration for approved work. It
does not authorize merging, main pushes, repository administration, or approving
issues. Normal tool permissions still apply. Use the existing Codex subscription.

## Recover and monitor

Use `reconcile`, then `status` to recover open issues, approvals, questions, PR
reviews/checks, native stacks, and local checkpoints. Inspect existing work before
dispatching. A missing checkpoint is not a reason to duplicate a remote branch or
PR. Preserve uncommitted changes and recover their intended scope.
If workers from the current session still exist, interrupt revoked workers and
wait for acknowledgment before reconciliation releases their slots or another
worker uses their file scopes. Checkpoints cannot prove a process has stopped.

While monitoring is requested, use `watch --since FINGERPRINT` between useful
actions. It waits for changes and returns after a bounded timeout. Keep watching
an empty queue until stopped; do not manufacture work. On authentication, network,
or quota errors, back off and report a persistent blocker. Goal mode can continue
across turns when the user starts a goal, but limits and interruptions can stop it.

Answer the maintainer's questions and requested refinements on unapproved issues
as well as approved ones. Use `reply NUMBER --issue-body --body-file FILE` for an
initial answer to a question in the issue body, or `reply NUMBER --comment ID
--body-file FILE` to follow up on an existing comment. Reply markers make retries
safe after restart. Questions and answers need no `/approve`; implementation
requests remain approval gated.
Revise proposed scope when asked; editing an approved issue needs a new `/approve`.
Watch general PR comments, inline comments, and reviews. Checkpoint addressed review
IDs and commit SHAs so a restart does not repeat responses.

## Schedule useful parallel work

Inspect eligible issues for likely file overlap and shared APIs, data formats,
lockfiles, migrations, and dependencies. Claim independent issues concurrently up
to policy/resource limits; do not serialize them just because one PR is unfinished.
Record planned file/directory scopes using `claim NUMBER --paths PATH1,PATH2`.
The helper rejects overlapping active claims; use `.` when the scope is uncertain.
Before expanding the write scope, update the claim and check for conflicts.
Read-only planning can precede a claim: save its handoff under
`.automation/plans/issue-N.md`, then attach it to the eventual claim's checkpoint.
Do not reserve an unknown write scope merely to conduct read-only planning.

Delegate bounded tasks with the approved issue, worktree, ownership, expected
evidence, and relevant decisions. Use cheaper models for mechanical work when
available. Keep independent review in a fresh context. Reserve enough capacity for
the manager to monitor changes and collect results. Avoid concurrent heavy builds
if RAM/CPU contention makes overall progress slower.

For dependent work, wait until the parent is in review at a stable published commit,
then `claim CHILD --base-issue PARENT --paths ...`. Both issues need current human
approval. Create the child's PR against its recorded base branch, and register the
ordered PRs with `stack --prs BOTTOM,MIDDLE,TOP`. This uses GitHub's native stack
API; branch naming or PR-body links alone do not create a stack. Keep stacks small
and focused. Do not chain unrelated issues merely to batch their merges.
After registering a stack whose CI already completed, dispatch `pages.yml` on
`main` so its newly eligible previews are reconciled.

Monitor native stack state after parent updates or partial merges. GitHub may rebase
and retarget upper layers. Fetch and inspect actual branch/PR state before further
edits; do not overwrite GitHub's new commits with stale local branches. Repair any
divergence, rerun each affected layer's CI, and wait for matching previews. The user
can review layers individually and use GitHub's native batch merge; never merge
the stack yourself. See the operating guide for official stack references.

If stale stack ancestry prevents an ordinary claim, use `claim N --recover` to
reserve its scope and slot, then `check N --recovery`. This permits local Git
recovery only. Preserve local commits and dirty files; automatic synchronization
is limited to a clean fast-forward. Inspect deliberate rebases carefully, then
finish with ordinary `claim N` before further code changes or pushes. If that
claim returns `push_lease`, use only that exact remote SHA with
`--force-with-lease=refs/heads/BRANCH:SHA` on the issue branch. Never use plain force
push or discard changes to bypass recovery. Recheck approval before the push.

## Implement and review

1. Prioritize maintainer feedback and broken PR checks, then dispatch independent
   eligible issues. Do not dispatch when `claim` fails. Explain acceptance criteria
   and material assumptions; expanded scope goes back for approval.
2. Keep monitoring while workers run. Check current authorization each monitoring
   cycle for active jobs. A hold, edit, or closure interrupts the worker and causes
   a checkpoint; no push is allowed. Recheck with `check NUMBER` before every push.
   Revocation takes effect at the next observed boundary, not mid-command.
3. Run meaningful tests and independent review. Create/update the existing PR and
   link its issue with `Closes #N`. Include actual validation, limitations, and
   manual testing steps. Pages posts a commit-specific preview link. Do not call
   the PR ready based solely on an agent's assertion.
4. Checkpoint PR and session IDs, acceptance criteria, decisions, head SHA, addressed
   feedback, tests, next steps, and blockers. Mark the issue `in-review`. A PR waiting
   for review frees an implementation slot. Address revisions within approved scope.
5. Count failed repair attempts with `checkpoint NUMBER --repair`. At the configured
   limit, mark the issue blocked and explain evidence and the needed input. A new
   approval is required to retry. Do not consume retries on infrastructure outages.

## Discoveries and stopping

Search open and closed issues before proposing an unrelated finding. `propose
--title TITLE --body-file FILE` creates a `needs-approval` / `agent-discovered`
issue. Include reproduction/evidence, impact, proposed scope, and originating
issue/PR. Do not implement it until approved; answer follow-up questions meanwhile.

On an explicit stop, stop dispatching, interrupt workers, save checkpoints, and
report outstanding work. Keep branches/worktrees for recovery. Automatic compaction
is fine; authorization and recovery facts must remain in GitHub and checkpoints.
