# PR Lifecycle Labels

Some projects mark a pull request's place in the merge pipeline with GitHub
labels — `ready-to-merge` for "approved and queued," `delegated` for "someone
has been handed approval rights." Today, on `leanprover-community/mathlib4`,
those labels are driven by GitHub Actions that parse `bors` commands out of
comments (`maintainer_bors.yml` → `maintainer_bors_wf_run.yml`). That approach
can only react to comments and PR events, so it is structurally blind to state
changes that happen *inside* bors with no comment to trigger on.

The most visible casualty is the **`delegated` label that never goes away**.
Since delegations gained an expiry (`DELEGATION_INVALIDATION.md` and the
`[delegation] default_expiry_sec` feature), a delegation can end in three ways
the Actions never see: it can **time out** during `Delegation.sweep/0`, it can
be **revoked by a sensitive-path push** in the invalidator, or it can simply be
the *last* of several delegations to be removed. In all of these the label is
left stranded on the PR.

This document proposes moving label management into bors itself, where the
state already lives, and defines a small set of lifecycle labels driven by that
state.

## Status

**Implemented on the bors side.** The label write API
(`BorsNG.GitHub.add_labels/remove_label`), the `[labels]` config, the
`BorsNG.Worker.Labeler` module, and all the delegation and queue hooks described
below exist and are covered by tests. Two deliberate scope choices:

- The optional periodic full-reconcile backstop in `Delegation.sweep/0` was
  **not** implemented; the per-event reconcile in `expire_delegations` (the
  actual fix) is. The backstop can be added later if drift is ever observed.
- The queue-label reconcile reads `bors.toml` from the PR's base branch once per
  batch transition. This is a small, bounded number of extra `get_file` calls
  per PR lifecycle (negligible against an installation's rate limit); threading
  the already-fetched toml through the batcher is a possible future
  optimization.

The mathlib4 workflow cleanup is **not** done — that lands after this deploys
(see [Rollout](#rollout-and-sequencing)).

## Why bors, not GitHub Actions

Bors already owns every piece of state these labels mirror:

- **Delegations** live in the `user_patch_delegations` table and change in four
  places — creation (`bors d+`/`d=`), manual revoke (`bors d-`), **timed
  expiry** (`Delegation.sweep/0`, `lib/database/context/delegation.ex`), and
  **sensitive-path invalidation** (`lib/worker/delegation_invalidator.ex`).
  Only the first two produce anything a comment-driven workflow can observe.
- **Queue membership** is the `LinkPatchBatch` → `Batch` state machine in
  `lib/worker/batcher.ex`, which already emits side effects (PR comments, commit
  statuses, Zulip notifications) on every transition.

The infrastructure to drive labels from this state already exists; the GitHub
client merely lacks the write calls, and there is a recurring sweep
(`BorsNG.Worker.DelegationTimer`) that can act as a self-healing backstop.

The guiding principle, mirroring how the rest of bors treats GitHub side
effects, is that **labels are best-effort projections of bors's own state**.
They are reconciled toward the truth in the database; a failed label API call
is logged and dropped, never allowed to crash a batcher cast or the delegation
sweep.

## The labels

| Label | Means | Driven by |
|-------|-------|-----------|
| `delegated` | the PR has ≥1 active (non-expired) delegation | state (DB) |
| `ready-to-merge` | the PR is on the queue — a batch in `:waiting` **or** `:running` | state (DB) |
| `bors-staging` | the PR is actively building on the staging branch (`:running`) | state (DB) |
| `awaiting-requeue` | the PR was approved, its build failed terminally, and it was dropped | event (sticky) |

Three of the four are **state-derived**: their presence is a pure function of
the current database, so they are *reconciled* rather than toggled, and any
missed transition self-corrects on the next reconcile. The fourth,
`awaiting-requeue`, cannot be derived from current state (a dropped PR is
indistinguishable in the DB from one that was never approved) and is therefore
**event-driven and sticky** — set on terminal failure, cleared on the next
lifecycle move. See [`awaiting-requeue`](#awaiting-requeue-event-driven) for why.

### `delegated`

Present iff the patch has at least one delegation whose `expires_at` is null or
in the future — the same predicate `Permission.permission?(:reviewer, …)`
already uses (`patch_delegated_reviewer?`, `lib/database/context/permission.ex`),
generalized to "any active delegation on this patch."

Reconciled — not blindly removed — because a PR can carry several delegations
(`bors d=alice,bob`). The label must persist until the **last** active
delegation is gone. Reconcile points:

| Event | Site |
|-------|------|
| Delegate created | `delegate_to` in `lib/web/command.ex`, after `Permission.delegate` |
| Manual revoke (`d-`, `d-=user`) | `run(:undelegate)` / `run({:undelegate_to, _})` in `lib/web/command.ex` |
| **Timed expiry** | `expire_delegations` in `lib/database/context/delegation.ex` |
| Sensitive-path revoke | the revoke path in `lib/worker/delegation_invalidator.ex` |

The expiry reconcile is the direct fix for the stranded-label complaint. As a
backstop, `Delegation.sweep/0` (every ~15 min via `DelegationTimer`) can
reconcile `delegated` for all patches with active delegations, paced the same
way it already paces comments, so even a missed event or a restart mid-transition
converges within one sweep.

### `ready-to-merge` and `bors-staging`

`ready-to-merge` marks "in the merge pipeline": the patch is linked to a batch
in `:waiting` or `:running`. `bors-staging` marks the narrower "burning CI right
now": linked to a batch in `:running`.

**`bors-staging` is an additive overlay, not a replacement.** A PR that is
building carries *both* labels. This is a deliberate choice over making them
mutually exclusive (`ready-to-merge` = waiting-only, `bors-staging` = running):

- **Decoupled configuration.** `ready-to-merge` behaves identically whether or
  not `bors-staging` is configured, so a project can adopt or drop the staging
  overlay later without ever changing what `ready-to-merge` means. The exclusive
  model would couple the two config keys and silently redefine `ready-to-merge`
  the moment the overlay is enabled.
- **Preserved meaning.** `ready-to-merge` keeps its established sense of
  "approved and in the pipeline," so existing filters and habits don't break.

So `ready-to-merge` answers "what's in the pipeline?" and `bors-staging` answers
"what is the merge build chewing on right now?" — the latter a strict subset of
the former.

Both are state-derived, so the cleanest implementation queries the desired set
and diffs (see [Reconciliation](#reconciliation)). Natural reconcile points are
the existing batcher transitions, all of which already fire `send_status` /
`send_zulip`:

| Transition | Site | Effect |
|------------|------|--------|
| Patch reviewed (`r+`) → enters a `:waiting` batch | `do_handle_cast({:reviewed, …})` | + `ready-to-merge` |
| Batch `:waiting` → `:running` | `start_waiting_batch` | + `bors-staging` |
| Batch completes `:ok` (merged) | `complete_batch` | − both (PR also closes) |
| Batch completes `:error` / `:conflict` | `complete_batch` | − both (+ `awaiting-requeue`, see below) |
| Cancel (`r-`) / `cancel_all` | `cancel` / `cancel_all` | − both |
| PR closed | the `l.patch.open == false` reject in `poll` | − both |

Because batches are reconciled from truth, bisection (a failed multi-PR batch
splitting and re-running its halves) needs no special handling: a patch's labels
simply track whatever batch state it currently sits in.

### `awaiting-requeue` (event-driven)

This is the replacement for an existing workaround: maintainers have been using
the *stale* `ready-to-merge` label to find PRs that were approved but whose
build failed, so they can put them back on the queue. Once `ready-to-merge`
accurately tracks live queue membership (and so comes off on failure), that
signal would be lost — `awaiting-requeue` restores it as a first-class state.

It cannot be reconciled from current state: once a batch fails, bors returns the
patch to the same "awaiting review" condition as a PR that was never approved —
there is no "it failed" flag to read. So `awaiting-requeue` is **set on the
event** and **sticky** until the next lifecycle move clears it:

- **Set** when a batch fails **terminally for a single PR**. Bors bisects
  multi-PR batches and re-runs the halves, so a PR is only genuinely *dropped*
  once a size-1 batch fails (the natural endpoint of bisection). Labeling at the
  terminal point — not mid-bisection — keeps the label meaning "needs a human to
  re-queue," not "is somewhere in a retry."
- **Cleared** on re-`r+` (which re-adds `ready-to-merge`), `r-`, PR close, or a
  successful merge. Re-queuing therefore swaps `awaiting-requeue` back to
  `ready-to-merge`; the two are never both present.

## Configuration

Label management is **opt-in per project** via a new `[labels]` table in
`bors.toml`, parsed into flat fields on `BorsNG.Worker.Batcher.BorsToml`
alongside the existing `delegation_*` fields:

```toml
[labels]
on_queue  = "ready-to-merge"    # batch waiting or running
building  = "bors-staging"      # batch running (overlay on on_queue)
failed    = "awaiting-requeue"  # terminal build failure, awaiting re-queue
delegated = "delegated"
```

- Each value is a single label name (`binary`), or absent. **Absent ⇒ that
  label is unmanaged**, so every project that does not configure `[labels]` —
  i.e. every current bors user other than mathlib4 — sees no behavior change at
  all. Each label can be adopted independently.
- Keys are named by **meaning** (`on_queue`, `building`, `failed`, `delegated`),
  not by mathlib4's chosen label text, so other projects can reuse them with
  their own names.
- Validation, in the style of the existing `block_labels` / `delegation_*`
  checks in `bors_toml.ex`: each value must be a non-empty string or absent;
  anything else is a `bors.toml` configuration error with a clear message.

## Architecture

### GitHub write calls

The client (`lib/github/github.ex`, backend `lib/github/github/server.ex`) has
read-only label support today: `get_labels/2`. Two writes are added, mirroring
its structure and going through the same `BorsNG.GitHub` GenServer:

- `add_labels(repo_conn, issue_xref, [label])` → `POST issues/{n}/labels` with
  body `%{"labels" => [...]}`. Idempotent server-side (GitHub does not duplicate
  an existing label).
- `remove_label(repo_conn, issue_xref, label)` →
  `DELETE issues/{n}/labels/{URI.encode_www_form(label)}`. A `404` (label already
  absent) is treated as success.

Unlike the delegation compares, these need no extended retry budget: they are
best-effort projections, so a transient failure is logged and dropped, to be
re-reconciled later — never retried to the point of stalling a caller.

### Reconciliation

A small `Labeler` module centralizes the logic. For the state-derived labels it
**reconciles** rather than toggling, touching only the labels bors manages and
never any unrelated label:

```
managed   = the configured label name for this concern (0 or 1 names)
desired    = should that label be present right now?  (from the DB)
to_add     = desired − current
to_remove  = (managed ∩ current) − desired
```

Because each concern manages at most one label name, this is a one-element set
operation, but framing it as a diff keeps the "never touch foreign labels"
guarantee explicit and makes a missed transition self-healing. `awaiting-requeue`
is the exception: it is set/cleared by event, since its desired state is not a
function of the current DB.

### GitHub App permissions

Adding and removing labels requires the installation to hold `issues: write`.
Bors already posts PR comments (issue comments), which need the same scope, so
this is almost certainly already granted — but it should be confirmed on the
mathlib4 installation before rollout, since a missing scope would surface only
as silently-dropped label calls.

## Rollout and sequencing

Label operations are idempotent, so bors and the existing Actions can safely
manage the same labels during the overlap. The order that matters is
bors-first, so the expiry fix is live before the Actions stop running:

1. Ship and deploy the bors feature with `[labels]` **unset** — a no-op
   everywhere, including mathlib4.
2. Add `[labels]` to mathlib4's `bors.toml`. Bors begins managing the labels;
   the Actions still also manage `ready-to-merge` / `delegated` (both just add
   the same label — harmless).
3. Watch one delegation-expiry cycle to confirm bors removes `delegated` on
   timeout.
4. Strip only the `ready-to-merge` / `delegated` add/remove logic from
   `maintainer_bors.yml` and `maintainer_bors_wf_run.yml`. Everything else in
   those workflows — permission checks, `awaiting-author` / `maintainer-merge`
   cleanup — stays. The `Build failed:` → `delegated` re-apply quirk disappears
   naturally: bors keeps `delegated` for as long as the delegation is actually
   active, regardless of build failures.

## Testing

- `BorsToml` parse/validation tests for the `[labels]` table (each key present,
  absent, and malformed).
- Extend the GitHub test double (`lib/github/github/server_mock.ex`, which
  already stores `labels[issue_xref]`) to handle add and remove.
- Behavior tests:
  - delegate → `delegated` added; `d-` → removed.
  - **expiry sweep → `delegated` removed** (regression test for the original
    complaint).
  - sensitive-path revoke → `delegated` removed.
  - multiple delegatees → `delegated` persists until the last is gone.
  - `r+` → `ready-to-merge`; batch start → `+ bors-staging`; merge/cancel →
    both removed.
  - terminal failure → `ready-to-merge`/`bors-staging` removed, `awaiting-requeue`
    added; re-`r+` → swapped back.
  - everything is a no-op when `[labels]` is unset.

## Risks and edge cases

- **App scope** (`issues: write`) — verify on the installation (see above).
- **Manual label edits.** Bors only ever touches its managed set, so a
  human-removed `delegated` is re-added on the next reconcile. This is intended:
  the label is a projection of bors state, not an independent annotation.
- **Rate limits during the sweep** — reuse the existing comment pacing in
  `Delegation.sweep/0`.
- **`bors-staging` churn.** Every queued PR flickers through `bors-staging` as
  its batch runs. This is inherent to the label's meaning; projects that find it
  noisy simply leave the `building` key unset.

See also [bors-ng/rfcs](https://github.com/bors-ng/rfcs) for broader design
documentation.
