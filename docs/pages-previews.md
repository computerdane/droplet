# GitHub Pages production and PR previews

The Pages workflow publishes production at the repository's Pages URL and each
open, same-repository PR targeting the default branch, or belonging to a native
GitHub PR stack rooted at that branch, at `previews/pr-N/`. Every stack layer gets
its own preview. A bot comment links to the preview and identifies its exact
commit and successful CI run. Fork PRs are not published.

## Enable it

1. Merge the workflows, scripts, and browser changes into the default branch.
   GitHub uses the default-branch version of the publisher, including when a PR
   closes. PR changes to the publisher itself take effect only after merging.
2. In **Settings → Pages → Build and deployment**, select **GitHub Actions**.
3. In **Settings → Environments → github-pages**, allow deployments from the
   default branch. Remove required reviewers if previews should deploy without
   approval. Keep production credentials out of this environment.
4. Allow Actions to write repository contents and PR comments. The workflow
   requests narrowly enumerated token permissions. Organization policy can
   still disallow them. Exclude `pages-state` from rules that require a PR or
   status checks for every branch update; protect the default branch normally.
5. Let CI finish successfully on the default branch, or rerun it if needed.
   It uploads `web-site`. The Pages workflow then bootstraps `pages-state`
   automatically. Existing PRs need a successful run of the new CI workflow.

No hosting token or additional service is required. The GitHub Pages URL supplied
by `actions/deploy-pages` is used, so custom domains and project paths work.
First-time visits may reload once while the Godot PWA service worker establishes
cross-origin isolation. Preview paths have their own registration scope and
cache namespace. Preview and production still share an origin, so previews
are public and should contain only changes you trust to run in your browser.

## How publishing works

CI checks out the PR's exact head commit and tests its web export before uploading
`web-site`. Builds get no deployment credentials. On successful CI completion,
PR closure/reopening/base change, or manual dispatch, Pages checks out only the default branch and
reconciles all currently open eligible PRs plus production:

- Query GitHub for each current head's successful **CI** workflow run.
- For PRs targeting another PR branch, query GitHub's native stacks API
  (`2026-03-10`). Require an open stack rooted at the default branch, with all
  current layer refs and SHAs matching the registered bottom-to-top chain.
  Compare adjacent layer commits through GitHub to prove each child includes
  its current parent head. A green child build from before a lower-layer push
  does not qualify until that child incorporates the updated parent.
  Merely targeting an arbitrary branch does not qualify. Revalidate the entire
  chain after downloads; stale stack metadata or a changed lower layer prevents
  publication of dependent previews. Merged layers can remain in stack history,
  but remaining layers must form a current chain rooted at the default branch.
- Accept exactly one unexpired `web-site` artifact from a same-repository run
  for that head and PR. Production uses a successful default-branch push run.
- Validate ZIP entries before extracting: no traversal, links, special files,
  hidden paths, reserved preview paths, or excessive expanded size.
- Preserve other previews and remove closed/ineligible PRs. If a current head
  has not passed CI, retain its last published preview and identify that SHA
  in its comment. Artifact expiration also leaves the published build intact.
- Recheck PR state/head after downloads to avoid publishing a head that changed
  during preparation. A further change during deployment is corrected on the
  next successful CI or closure event; the comment always reports deployed SHA.
- Save the assembled tree and commit/run/artifact manifest in `pages-state`,
  then upload that exact tree to Pages and update preview comments after success.

Nothing from an artifact is executed in the publisher. A separate **Preview
lifecycle** workflow responds to PR closure, reopening, and base changes without any token permissions or
repository checkout. Its completion triggers the trusted default-branch Pages
publisher through `workflow_run`, so closing an upper stack layer also works
with an environment restricted to the default branch. No privileged
`pull_request_target` workflow is needed.
The token is stripped when artifact downloads redirect to external storage.

All publishing runs share a non-cancelling concurrency group. GitHub can replace
pending runs, so each execution reconciles the entire desired state instead of
processing just its triggering PR. The saved tree survives Actions artifact
expiration and runner restarts. No force-pushes are used.

## Recovery and limits

Run **Actions → Pages → Run workflow** on the default branch to reconcile after
a failed deployment or missed event. State is saved before deploying; retrying
publishes the same complete tree. If a needed build artifact has expired before
its first publication, rerun CI for that head. The production version remains
at its last tested build until the current default-branch head passes CI.

If the native stacks API is unavailable, the publisher emits an Actions warning
and skips/removes stacked previews whose eligibility it cannot verify. Production
and ordinary PR previews still publish. Retry Pages after stack access recovers.
An unavailable ancestry comparison also excludes that layer and its dependents;
an unaffected lower layer remains eligible. The publishing job has a 30-minute
timeout, and a fresh run retries failed lookups.
After registering a new stack, run Pages manually if its CI already finished
before registration; stack registration alone does not trigger this workflow.

The publisher caps the assembled site at 900 MiB, leaving space below Pages'
1 GB site limit. Each export is capped at 200 MiB and each file at 99 MiB because
it must fit GitHub's ordinary git file limit. The current approximately 38 MB
engine permits a modest number of simultaneous previews. Close unneeded PRs
and rerun Pages if the combined size budget is exceeded.

`pages-state` is generated storage, not a source branch: do not merge it into
main. Git deduplicates identical assets, but historical binary versions remain
in branch history after cleanup. Monitor repository size. If growth becomes
material, migrate publication state to object storage, or deliberately archive
and recreate this generated branch during a maintenance window. The publisher
does not perform destructive history rewriting automatically.

Local validation (no GitHub access or deployment):

```sh
node --test tools/pages/*.test.mjs
```

These tests exercise artifact rejection, credential-safe redirects, full-tree
reconciliation, stale/foreign build rejection, cleanup, persistent branch
bootstrap, and size limits. A real GitHub deployment is still required to verify
repository permissions and the Pages environment configuration.
