# GitHub development sessions

Start an interactive Codex session on your Linux computer when you want to work.
It uses your existing subscription, a separate GitHub bot identity, and local
checkpoints. GitHub Actions runs CI and publishes Pages previews independently.

## One-time setup

1. Merge the setup after reviewing CI. Approval and publishing workflows run
   trusted code from `main` and become active after merge.
2. Create a separate GitHub machine-user account and invite it to this repository
   as a collaborator. Store its token securely, never in Git, prompts, issues, or
   command arguments. The local helper currently uses `GET /user`, so use a bot
   account token, not a GitHub App installation token. For a bot collaborating on
   another user's repository, check GitHub's token eligibility: fine-grained PATs
   may not support that relationship; a classic PAT with `public_repo` is the
   compatibility option for this public repository. Keep the bot account limited
   to this repository. See [GitHub token guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).
3. Supply the bot token as `GH_TOKEN` in the coordinator's environment, or use a
   separate `GH_CONFIG_DIR` logged into the bot. Use a dedicated HTTPS controller
   clone and `gh auth setup-git` with that bot configuration so pushes also use
   its identity. A personal SSH origin can otherwise push with your personal key.
4. Run `node tools/automation/queue.mjs setup-labels` as the maintainer once. The
   issue workflow also sets up these labels after merge. `.github/automation.json`
   identifies the human approver by stable numeric GitHub account ID.
5. Configure `main` to require PRs and the CI checks `test`, `desktop`, and `web`,
   with branches up to date before merging.
   Block deletion/force pushes and give the bot no bypass. Once PRs are bot-authored,
   require one approval and dismiss stale approvals. CODEOWNERS flags sensitive
   changes. Repository settings and credentials remain under your control.
6. Keep Pages set to **GitHub Actions**. See [Pages setup](pages-previews.md) for
   publication state, environment permissions, cleanup, and storage limits.

The helper rejects worker operations authenticated as your approving account.
Do not disable that check to avoid bot setup. Branch rules and execution isolation
remain necessary: scripts in a writable checkout are not a security boundary.
Do not expose personal credentials or production secrets to workers.

## Start, discuss, and stop

Use Node.js 22+, `gh`, `git`, `flock`, and subscription-authenticated Codex on Linux:

```sh
nix develop
bash tools/automation/start
```

The launcher opens GPT-6 Sol with the repository skill and a monitoring goal. A
lock prevents a second coordinator in the same checkout. The `.agents/skills/github-loop`
symlink also makes `$github-loop` discoverable in a new Codex session; the launcher
works without discovery because it supplies the skill path explicitly.
Trust the dedicated controller checkout in Codex so its project configuration and
agent roles load. The launcher uses `--approve-for-me` (verified with Codex CLI
0.156.1) to route tool approval requests through automatic review while retaining
the workspace sandbox. This is separate from your issue `/approve` gate. A denied
tool action or managed permission policy can still block work; the manager must
report it. The launcher does not disable the sandbox.

Ask questions and request refinements on issues, including unapproved discoveries.
Codex answers while the loop runs and catches up after restarting. Questions and
discussion do not authorize implementation. To approve an issue, post this as an
entire, unedited comment:

```text
/approve
```

Use `/hold` to withdraw approval. Editing the title/body, closing/reopening the
issue, or editing the approval comment requires a new `/approve`. Labels alone
cannot authorize work. A command deleted from GitHub disappears from the live
decision history; revoke with a new `/hold`, not by deleting old comments. An edit
in the same timestamp second as approval conservatively requires a fresh comment.

Tell Codex to stop and let it checkpoint before closing. Goal controls also include
`/goal pause` and `/goal resume`. A goal does not survive every process failure,
usage limit, or blocker automatically; restart the launcher to reconstruct work
from GitHub and `.automation/state.json`. Keep `.worktrees/` for unfinished changes.
Run only one coordinator at a time, with multiple workers. The lock and checkpoints
are local to this checkout; they do not coordinate separate clones or machines.
Moving machines requires transferring checkpoints and unfinished work deliberately.

| Label | Meaning |
| --- | --- |
| `needs-approval` | Awaiting approval, held, or changed scope |
| `ready` | Approved and eligible |
| `in-progress` | Active implementation |
| `in-review` | PR awaiting your review |
| `blocked` | Needs input or exhausted repair attempts |
| `agent-discovered` | Additional label for a finding proposed by Codex |

The issue workflow reconciles labels, and the dispatcher independently verifies
the human comment and edit history. Holds stop work at the next polling boundary;
they cannot interrupt an already-running command instantaneously.

## Parallel work and native stacks

The orchestrator should run independent issues concurrently, considering shared
files, APIs, data formats, and integration risks. Defaults allow three active
implementations and six open AI PRs. Resource contention or overlapping work can
reduce concurrency; an unfinished independent PR should not force serial work.

Claims record planned file/directory scopes. Prefix overlap is rejected between
active jobs. Use `.` for unknown scope and refine it after investigation. This is
a scheduling aid, not filesystem enforcement or proof of semantic independence.
Before expanding scope, update the claim and check for conflicts.
Read-only investigation can save a handoff in `.automation/plans/issue-N.md`
without reserving a write scope. Interrupt revoked workers and wait for them to
stop before reusing their scopes or implementation slots.

For dependent changes, claim a child from a stable approved parent already in
review. Open the child's PR against the parent's branch and register the ordered
PR numbers with the native stacks API. Each issue needs its own human approval.
The default maximum stack depth is three. Unrelated changes remain independent PRs.

GitHub native stacks support layer-by-layer review and batch merging subject to
repository requirements. On a partial merge, GitHub can rebase and retarget upper
layers. The manager must fetch actual current state, repair divergence, and wait
for fresh checks/previews before declaring the stack ready. Only you merge.
See [GitHub's stack announcement](https://github.blog/changelog/2026-07-30-stacked-pull-requests-are-now-in-public-preview/)
and [REST stack API](https://docs.github.com/en/rest/pulls/stacks).

## Model routing

GPT-6 Sol is the coordinator and normal implementation model. It chooses a model
per subtask, not once for the entire issue:

| Agent | Model / initial effort | Use |
| --- | --- | --- |
| `mechanical` | GPT-6 Luna / high | Bounded templates, straightforward edits, evidence gathering |
| `implementer` | GPT-6 Sol / medium | Routine implementation and testing |
| `reviewer` | GPT-6 Sol / high | Independent correctness and regression review |
| `planner` | GPT-6 Astra / low | Ambiguous architecture, extensive planning, unfamiliar domains |
| `expert` | GPT-6 Astra / low | Difficult implementation, numerical reasoning, unresolved hard failures |

A satellite-rendering request would normally get an Astra planning pass covering
formats, projections, rendering integration, performance, validation, and a phased
implementation. The manager then assigns routine components to Sol or Luna and
keeps Astra on the parts whose difficulty justifies it. Planning does not authorize
unapproved implementation or unrelated issues.

Record the model choice and escalation reason in the checkpoint. Prefer the least
costly model likely to succeed; escalating a failed mechanical task to Sol is often
enough. Use Astra when the ambiguity, impact, or evidence warrants it, not simply
because work is available. Start with at most one Astra task at a time and reassess
after its bounded deliverable. These are routing instructions, not a billing cap.
Model availability and usage limits still depend on your subscription/workspace.
[Official subagent configuration](https://learn.chatgpt.com/docs/agent-configuration/subagents)
supports per-agent models and reasoning effort; `.codex/agents` contains the roles.

## Controller commands

Use the trusted controller helper, never an issue worktree's edited copy:

```sh
node tools/automation/queue.mjs reconcile
node tools/automation/queue.mjs status
node tools/automation/queue.mjs watch --since FINGERPRINT --seconds 50
node tools/automation/queue.mjs claim 42 --paths scripts/hud.gd,tests/unit/test_touch.gd
node tools/automation/queue.mjs claim 43 --base-issue 42 --paths scripts/ppi_view.gd
node tools/automation/queue.mjs claim 43 --recover
node tools/automation/queue.mjs check 43 --recovery
node tools/automation/queue.mjs check 42
node tools/automation/queue.mjs checkpoint 42 --phase in-review --pr 57 --notes-file /tmp/handoff.md
node tools/automation/queue.mjs stack --prs 57,58
node tools/automation/queue.mjs checkpoint 42 --repair
node tools/automation/queue.mjs reply 42 --comment 123456 --body-file /tmp/reply.md
node tools/automation/queue.mjs propose --title 'Observed problem' --body-file /tmp/finding.md
```

`status`/`watch` read GitHub, including issue questions and PR inline feedback.
`claim` checks approval, limits, conflicts, dependencies, and existing work before
creating an issue worktree. `check` guards further work/pushes against revoked or
changed scope. `checkpoint` is local and still works after a hold; update visible
issue labels to match separately. `reply` adds a retry marker. Search for duplicates
before `propose`. `stack` registers or appends a native stack; it does not merge.

`claim --recover` reserves a slot and scope for local Git recovery when stack
updates have made ancestry stale. It does not permit implementation or pushing.
Preserve dirty files and local commits, inspect the actual remote branches, and
finish recovery with ordinary `claim` before proceeding. A deliberate local
rebase may return an exact `push_lease`; use that SHA with an explicit
`--force-with-lease=refs/heads/BRANCH:SHA`, after checking current approval. Never
use plain force pushes. If CI completed before native stack registration, dispatch
`pages.yml` on `main` to refresh previews.

Save acceptance criteria, decisions, models and escalation reasons, current commits,
session IDs, tests/evidence, addressed feedback IDs, dependencies, next actions, and
blockers. Record each failed repair with `--repair`; the third blocks that attempt.
A new approval is required to retry it. Infrastructure outages are not code failures.

The helper does not call a model, but bounded polling still resumes Codex to process
tool results, so idle monitoring is not completely free. Authentication failures,
API outages, and subscription limits require backoff and reporting, not treating
the queue as empty.

## First live trial

After bot setup and merge, verify a small issue through: discovery → question and
reply → approval → PR/preview → review revision → hold → restart → reapproval →
human merge and cleanup. Restart with an existing PR to check duplicate avoidance.
Then try two disjoint issues and a two-layer native stack. Automated tests exercise
the invariants, but a live trial is needed to verify account permissions/settings.
