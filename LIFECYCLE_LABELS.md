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

**Implemented on the bors side.** The label write/read API
(`BorsNG.GitHub.add_labels` / `remove_label` / `list_issues_by_label`), the
`[labels]` config, the `BorsNG.Worker.Labeler` module — both the per-event
reconciles and the periodic [backstop sweep](#backstop-sweep) — its timer
(`BorsNG.Worker.LabelBackstopTimer`), the per-base-branch [config
cache](#config-cache) (`GetBorsToml.get_cached`), and all the delegation and
queue hooks described below exist and are covered by tests.

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
client gains a small set of label write/list calls, and a dedicated recurring
sweep (`BorsNG.Worker.LabelBackstopTimer`) acts as the self-healing backstop.

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
| Convert-to-draft (wipes delegations) | the `is_draft` clause of `do_webhook_pr`, after `undelegate_patch` |
| Close without merging (wipes delegations) | the `closed` clause of `do_webhook_pr`, when `pr.merged` is false |

Closing a PR without merging now also **wipes its delegations** (mirroring the
convert-to-draft path), so the label comes off an abandoned PR. A PR that bors
*merges* is left alone — its delegations expire and get swept in time, and the
`delegated` label stays as the historical marker described above.

The expiry reconcile is the direct fix for the stranded-label complaint. The
periodic [backstop sweep](#backstop-sweep) is the second line of defence: even a
missed event, a dropped best-effort write, or a restart mid-transition converges
on the next sweep.

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
| Patch reviewed (`r+`) → enters a `:waiting` batch | `run` (via `do_handle_cast({:reviewed, …})`) | + `ready-to-merge`, − `awaiting-requeue` |
| Batch `:waiting` → `:running` | `start_waiting_batch` | + `bors-staging` |
| Batch merges `:ok` | `maybe_complete_batch` | **labels left in place** (frozen as history; see below) |
| Batch fails terminally (`:error` / `:conflict` / timeout) | `maybe_complete_batch` / `start_waiting_batch` / `timeout_batch` | − `ready-to-merge` / `bors-staging`, + `awaiting-requeue` |
| Cancel (`r-`) / `cancel_all` | `cancel_patch` / `cancel_all` | − both |
| PR closed without merging | `closed` webhook → `Batcher.cancel` | − both (also wipes delegations, see [`delegated`](#delegated)) |

Because batches are reconciled from truth, bisection (a failed multi-PR batch
splitting and re-running its halves) needs no special handling: a patch's labels
simply track whatever batch state it currently sits in.

**A successful merge is the one transition that does *not* reconcile.** The PR
closes, so its labels can no longer drift, and leaving them in place turns
`ready-to-merge` / `delegated` into a (best-effort) historical record of how the
PR merged — in particular, which merged PRs had been delegated. Failures leave
the PR *open*, so those still reconcile their queue labels off. The asymmetry is
deliberate: open PRs reflect live state, closed-by-merge PRs are frozen.

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
- **Cleared** on re-`r+` (which re-adds `ready-to-merge`), `r-`, or a PR close
  without merging. Re-queuing therefore swaps `awaiting-requeue` back to
  `ready-to-merge`; the two are never both present. (A *successful merge* leaves
  labels untouched, but a PR that merged is not awaiting a re-queue — it reached
  `awaiting-requeue` only via a failure, and re-queuing it would have cleared the
  label before it ever got the chance to merge.)

Because it is event-driven, `awaiting-requeue` is **not** reconciled by the
[backstop sweep](#backstop-sweep) the way the state-derived labels are; see there
for why the listing mechanism is the same but the per-PR decision is not.

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

### Which branch the config is read from

The `[labels]` config is read from the **PR's base branch** (`patch.into_branch`)
— the current tip of the branch the PR targets — never from the PR's own head.
This matches how the `[delegation]` options are read, and gives the same safety
property: a PR cannot change the label (or delegation) rules it is evaluated
under by editing `bors.toml` in the PR itself; the change only takes effect once
it is merged into that base branch. It is also self-consistent — the branch the
config is read from is the same branch the batch merges into, so the only person
who can weaken a branch's config is someone who can already push to that branch.

Because config is per-base-branch, a project whose branches carry **different**
`[labels]` names can strand a label across a **base-branch retarget**. The
reconcile only ever touches the names configured on the PR's *current* base (the
"never touch foreign labels" guarantee, see [Reconciliation](#reconciliation));
if a PR is moved from a branch where `on_queue = "ready-to-merge"` to one where
it is `"queued"` (or unset), the `ready-to-merge` it picked up earlier is now
unmanaged and is left stranded — and bors updates `into_branch` live on the
`pull_request` *edited* webhook, so the switch is immediate.

**Recommendation: keep the `[labels]` names (and, ideally, the `[delegation]`
options) uniform across the branches bors manages.** If the managed *names* are
branch-invariant, the managed set never changes on a retarget and nothing
strands — the configs may still legitimately differ in other ways. For mathlib4
this is automatic, since PRs effectively target a single branch.

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

### Backstop sweep

The per-event reconciles keep labels accurate in the normal case, but a label
can still drift out of sync: a best-effort write dropped at event time, a crash
mid-transition, or a human editing a managed label by hand.
`BorsNG.Worker.Labeler.backstop_sweep/0` — run on its own timer
(`BorsNG.Worker.LabelBackstopTimer`, hourly by default, deliberately decoupled
from the delegation sweep) — is the self-healing pass for that drift.

It is **discovery-driven and diff-based**. For each project with open patches it
resolves the per-base-branch `[labels]` config (through the [cache](#config-cache)),
lists the PRs carrying each managed *state-derived* name with
`GitHub.list_issues_by_label/2`, and reconciles each. Because that listing
endpoint returns every PR's full label set, the sweep gets each candidate's
current labels in the same call it uses to find them, so it diffs locally and a
tick with no drift performs **zero writes**. A second "add-gap" pass adds a label
to the (small) set of patches the DB says should be labeled but that surfaced in
no listing — the one case discovery-by-label can't see: a PR that lost *all* its
managed labels.

Two properties bound it. It only ever touches **open** patches (`patch.open`),
so a merged PR's frozen labels are never disturbed — belt-and-suspenders with the
`state=open` listing filter. And it reconciles a label only where the PR's
*current* base config manages that name, preserving "never touch foreign labels"
and the [retarget limitation](#which-branch-the-config-is-read-from).

**Why it sweeps the three state-derived labels but not `awaiting-requeue`.** The
discovery mechanism would be identical — list the (small) set of PRs carrying the
label, then reconcile — but the *per-PR decision* is not. For a state-derived
label the decision is total: the DB always says whether the label should be
present right now (`delegated` ⇔ an active delegation; `on_queue` / `building` ⇔
a live batch), so a found label can be kept or removed with confidence.
`awaiting-requeue` has no current-state predicate — a dropped PR is
indistinguishable in the DB from one never approved, the whole reason it is
event-driven — so the sweep can never *add* it, and for a PR carrying only
`awaiting-requeue` it cannot tell one genuinely awaiting re-queue from a dropped
`r-`/close clear. The single direction that *is* derivable — clearing it once the
PR is back on the queue — is the live `reconcile_queue/3` rule, and the backstop
applies it too: a re-queued PR also carries `on_queue`, so it is already
discovered (with its full label set, including a stale `awaiting-requeue`) via the
`on_queue` listing, and the sweep clears the stale label with no dedicated listing
of its own. What it deliberately does *not* do is list `awaiting-requeue`
directly: the PRs that would add — carrying it while neither queued nor delegated
— are exactly the undecidable ones, and that listing's cost would scale with the
sticky, ever-growing population while deciding almost nothing.

### Config cache

The label reconcile paths re-read the same base-branch `bors.toml` many times —
the delegation sweep once per expiring patch, the backstop once per PR it touches
— so a short-TTL cache keyed by `(repo_xref, branch)` collapses those into one
read per branch per window. `GetBorsToml.get_cached/2` wraps the plain `get/2`,
backed by an ETS table owned by `…GetBorsToml.Cache`; it caches both successes
and errors (errors more briefly, so a freshly-added or fixed `bors.toml` is
picked up promptly) and prunes expired entries periodically. The table is public
with read concurrency, so the batcher casts, the sweep, and the backstop read it
without serializing through one process.

It is used **only** by the reconcile paths (the `Labeler` and the delegation
sweep/backfill). The batcher's merge-decision reads stay on `get/2`: a stale
config must never drive an actual merge. A non-positive TTL bypasses the cache
entirely, which is how the test environment keeps config reads fresh.

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
  already stores `labels[issue_xref]`) to handle add, remove, and
  list-by-label.
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
- Backstop sweep tests: strands removed (`delegated`/`ready-to-merge`), add-gap
  re-adds a fully-stripped label, a stale `awaiting-requeue` left alone off the
  queue but cleared once back on it, a closed/merged PR never touched, and no
  write when labels already match.
- Config-cache tests: hit serves a stale value within TTL, expiry/error
  caching, and a non-positive TTL bypass.

## Risks and edge cases

- **App scope** (`issues: write`) — verify on the installation (see above).
- **Manual label edits.** Bors only ever touches its managed set, so a
  human-removed `delegated` is re-added on the next reconcile. This is intended:
  the label is a projection of bors state, not an independent annotation.
- **Base-branch retarget with divergent label names.** Config is read per base
  branch (see [Which branch the config is read from](#which-branch-the-config-is-read-from)),
  so moving a PR to a branch whose `[labels]` names differ can strand the old
  branch's label. Keeping label names uniform across managed branches avoids it;
  it is otherwise a documented limitation, like manual label edits above.
- **Rate limits during the sweeps.** Label writes are throttled by
  `Labeler.pace_write/1` (lighter than the comment pacing, since a label write
  is cheap and idempotent); the backstop's discovery is label-filtered
  server-side, so it lists only the few PRs carrying a managed label rather than
  every open PR, and a no-drift tick writes nothing.
- **`bors-staging` churn.** Every queued PR flickers through `bors-staging` as
  its batch runs. This is inherent to the label's meaning; projects that find it
  noisy simply leave the `building` key unset.

See also [bors-ng/rfcs](https://github.com/bors-ng/rfcs) for broader design
documentation.
