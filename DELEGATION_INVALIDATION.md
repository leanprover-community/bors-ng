# Delegation Path Invalidation

When a reviewer delegates approval rights on a pull request (`bors d=...`),
they are trusting another user to approve *that PR as it stands*. If the PR
later grows to touch sensitive files, that trust may no longer be warranted.

The `[delegation]` section in `bors.toml` lets a project bound what a delegation
covers, revoking it automatically when new author work strays outside that
boundary. Two complementary keys control it:

- **`restrict_to_paths`** (allow-list / whitelist): the delegation covers
  **only** changes within these paths; touching anything else revokes it.
  Unset means "no scope restriction" — never "nothing is delegable."
- **`invalidate_on_paths`** (deny-list / blacklist): these paths are sensitive
  and always revoke, **even when they fall inside** `restrict_to_paths`.

```toml
[delegation]
restrict_to_paths = ["src/**", "tests/**"]
invalidate_on_paths = ["src/crypto.rs", ".github/**"]
```

This document explains how that mechanism decides what changed, the GitHub API
limits that complicate it, the fail-safe policy chosen at those limits, and the
reasoning behind the user-facing messages. The implementation lives in
`lib/worker/delegation_invalidator.ex`, with supporting GitHub calls in
`lib/github/github/server.ex` and the merge-time gate in `lib/web/command.ex`.

## Status

All of the behavior described below is implemented, with one deliberate
omission: the proactive large-PR heads-up at delegation time was dropped (see
"User-facing messages"). Truncation is detected in the invalidator against the
documented file caps rather than via a dedicated GitHub-client signal.

## Goal and security direction

The control exists to stop a sensitive change from merging under stale trust.
Its guiding rule is therefore asymmetric:

> **Prefer over-revoking to under-revoking.** A wrongly revoked delegation
> costs a re-issue (`bors d=...` again). A wrongly *retained* delegation can
> let a sensitive change merge unreviewed. The first is annoying; the second
> defeats the feature.

Every ambiguous case below is resolved in the over-revoke direction.

## The two comparisons

bors must isolate **new author work since the delegation was issued** — and
*only* that. It does so by intersecting two GitHub compares (both use the
three-dot `base...head` form, which is relative to the merge base):

```
delta    = files in compare(delegated_at_commit, current_head)
pr_diff  = files in compare(base_branch,        current_head)
relevant = delta ∩ pr_diff
```

- **`delta`** is everything that changed since the delegation commit. This is
  the security signal — but it is too broad on its own, because clicking
  GitHub's **"Update branch"** button merges the base branch into the PR and
  also fires the `synchronize` webhook. Those base-merge files land in `delta`
  even though the author did not write them.

- **`pr_diff`** is the author's net contribution to the PR (three-dot, so
  base-only content is excluded). Its sole job is to be a **noise filter**: a
  file that entered `delta` purely via a base-merge will *not* appear in
  `pr_diff`, so the intersection drops it.

`relevant` is thus "changed since delegation **and** genuinely authored in this
PR." A delegation is invalidated when any path in `relevant` is **unacceptable**
under the rule in [Deciding what's acceptable](#deciding-whats-acceptable).

Worked example with `invalidate_on_paths = ["Cargo.lock"]`:

| Scenario | `delta` | `pr_diff` | `relevant` | Revoke? |
|----------|---------|-----------|------------|---------|
| Author clicks "Update branch", pulling master's `Cargo.lock` | `{Cargo.lock}` | `{src/foo.rs}` (Cargo.lock now matches master) | `{}` | No ✅ |
| Author edits `Cargo.lock` after delegation | `{Cargo.lock}` | `{src/foo.rs, Cargo.lock}` | `{Cargo.lock}` | Yes ✅ |

Because `pr_diff` is *only* a filter, losing it (e.g. to truncation) can only
cause us to keep noise we should have dropped — it never hides a real authored
change. That asymmetry drives the truncation policy below.

### bors.toml provenance

`bors.toml` is read from the PR's **base** branch (`patch.into_branch`), never
the head. A PR cannot disable invalidation by editing its own copy of the
config; a change to the `[delegation]` options only takes effect once it is
merged into that base branch. This is also self-consistent: the branch the
config is read from is the same branch a delegated `r+` would merge into, so the
only person who can weaken a branch's delegation rules is someone who can already
push to that branch.

Because the rules are per-base-branch they can differ between branches, and a
PR's base can change mid-flight — bors updates `into_branch` on the
`pull_request` *edited* webhook (`Syncer.sync_patch`). A live delegation is
therefore re-evaluated under the **new** base branch's `[delegation]` options
after a retarget: its `restrict_to_paths` / `invalidate_on_paths` / expiry may
differ from the branch it was granted under. To avoid surprises, keep the
`[delegation]` options uniform across the branches bors manages (`LIFECYCLE_LABELS.md`
notes the same per-branch consideration for the `delegated` label name). See
[Known limitations](#known-limitations).

## Deciding what's acceptable

Each path in `relevant` is classified against the two configured lists. The
allow-list scopes what the delegation covers; the deny-list carves sensitive
exceptions *out* of that scope. Precedence is **blacklist > whitelist >
default**:

> A path is **acceptable** iff
> `(restrict_to_paths unset OR path ∈ restrict_to_paths) AND path ∉ invalidate_on_paths`.

A delegation is revoked when any path in `relevant` is unacceptable. With
`restrict_to_paths = ["src/**"]` and `invalidate_on_paths = ["src/crypto.rs"]`:

| Changed file | In allow-list? | In deny-list? | Verdict |
|--------------|----------------|---------------|---------|
| `src/foo.rs` | ✅ | ❌ | acceptable |
| `src/crypto.rs` | ✅ | ✅ | **revoke** — deny-list overrides |
| `docs/readme.md` | ❌ | — | **revoke** — outside the delegated scope |

The two lists only interact *inside* the allow-list, where the deny-list is the
tiebreaker; everywhere else they agree. A deny-list entry that already lies
outside the allow-list is harmless but redundant (a candidate for the bors-try
lint to flag). An empty or unset allow-list imposes no scope restriction, so a
deny-list-only config behaves exactly as it does today.

## When invalidation runs

### On push — `synchronize` webhook (fail-open, self-healing)

The invalidator runs fire-and-forget from the `synchronize` handler in
`lib/web/controllers/webhook_controller.ex`, after `patch.commit` is updated to
the new head. Each run re-derives `delta` from the *fixed* `delegated_at_commit`
to the *current* head, so it is stateless across pushes:

- **Self-healing.** A dropped or failed `synchronize` (webhook delivery
  failure, node restart, transient API error) is recovered by the next push,
  which re-scans the entire range from the delegation point.
- **Fail-open.** A push cannot be blocked, so an API error here is logged and
  skipped rather than treated as a revocation trigger. Recovery relies on a
  later push or the merge-time gate.

### On approval — merge-time gate (fail-closed backstop)

The `synchronize` path can fail open at the worst moment: an unverified push
immediately followed by `bors r+`. The merge-time gate closes this. At the
`r+` authorization point in `lib/web/command.ex`, a **synchronous** check runs
before the delegation permission is honored.

It only ever needs to validate `patch.commit`, because the batcher refuses to
merge anything else: at staging (`lib/worker/batcher.ex`) it fetches the live
PR and treats `pr.head_sha != patch.commit` as a `:race`, dropping the patch
rather than merging a moved head. So if the head advances after approval, the
race guard blocks that batch and the new head goes through its own
`synchronize`.

Unlike the push path, the merge gate **fails closed**: if it cannot verify the
change is clean, it denies the approval (see the policy below).

Because it fails closed, a *transient* GitHub error is not free here: when the
delta compare can't complete, `classify_delegation/6` returns `:unverifiable`
and the gate denies the `r+`, forcing the approver to re-issue it. To keep a
brief API blip from surfacing as a spurious denial, `:get_pr_compare` is on the
**long retry budget** in `lib/github/github.ex` (`max_retry_elapsed_ms/1`,
default 180s) rather than the 30s budget used for calls where giving up early is
harmless. That budget axis is about *the cost of giving up*, not literally
reads vs. writes — see the comment on `max_retry_elapsed_ms/1` for the full
rationale. The advisory `invalidate_on_paths` lint deliberately stays on the
short budget: its reads (`get_repo_tree`, `get_pr_comments`) only gate a
cosmetic warning, so a failure just skips it.

### On close or convert-to-draft (full wipe)

Two lifecycle events drop a PR's delegations outright, independent of the
path-based checks above: **converting the PR to a draft** and **closing it
without merging**. Both signal the PR is no longer an active candidate to merge
under the granted trust, so bors wipes every delegation on the patch (and
reconciles the `delegated` label off). A PR that bors *merges* is left alone —
its delegations simply expire and are swept normally. These wipes live in the
`do_webhook_pr` handler; see `LIFECYCLE_LABELS.md` (the `delegated`
reconcile-points table) for the full lifecycle.

## GitHub API file ceilings

The two compares hit two different GitHub endpoints with two different,
silently-enforced ceilings. These were verified empirically against
`leanprover-community/mathlib4` (PR #31786 / its 7905-file commits).

### `compare(base...head)` — 300 files, first page only

- Returns **at most 300 changed files**, and only on the **first page**. There
  is no file pagination: page 2 returns zero files, and the page-1 `Link`
  header carries no `rel="next"` for files (it paginates *commits* only).
- **Truncation signal:** `length(files) == 300`. We cannot retrieve files
  301+, so hitting 300 means "there may be more we can't see."
- Docs: [Compare two commits](https://docs.github.com/en/rest/commits/commits#compare-two-commits)
  — *"The list of changed files is only shown on the first page of results, and
  it includes up to 300 changed files for the entire comparison."*

### `pulls/{n}/files` — 3000 files, via real pagination

- Returns up to a **3000-file** hard ceiling, paginated (default 30/page, max
  `per_page=100`). The cap is enforced **silently by returning empty `[]`
  pages** past 3000 — and the `Link` header *lies*: for PR #31786 it advertised
  `rel="last"` at the diff's true size (~7210 files) even though data stops at
  3000.
- **Pagination must stop on the first short/empty page** (`length < per_page`),
  *not* on the absence of `rel="next"` — otherwise a 7000-file PR triggers
  dozens of wasted requests fetching empty pages.
- **Truncation signal:** the PR object's `changed_files` field (from
  `GET /pulls/{n}`) exceeds what we retrieved, or we simply hit 3000.
- Docs: [List pull requests files](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files)
  — *"Responses include a maximum of 3000 files."* (`per_page` "max 100" is the
  page size, not a page count.)

### Why `pr_diff` uses the PR-files endpoint

`compare(into_branch, head)` is, three-dot, identical to the PR's own file list
(`into_branch` is the PR base, `head` is `patch.commit`). Sourcing `pr_diff`
from `pulls/{n}/files` raises its ceiling from 300 to 3000 — a real correctness
win, since an incomplete filter causes under-revoke. `delta` has no PR-files
equivalent (it is an arbitrary commit range) and is stuck at 300.

## Truncation policy

The two truncation cases are **not** equally severe, and treating them the same
creates a bad failure mode (see "un-actionable delegations" below). They are
handled separately:

| Case | Meaning | Handling |
|------|---------|----------|
| **`delta` truncated** (>300 files changed *after* delegation) | The delta may be incomplete, but it is dominated by base-merge noise that the `pr_diff` filter removes; an unacceptable path can only be hidden if it is also **authored** | **Filter first, then conditionally fail safe** (see below). |
| **`pr_diff` truncated** (>3000 files in the whole PR) | Only the *noise filter* is incomplete; `delta` is still fully known | **Delta-only fallback.** Evaluate `delta` without the intersection. Can only over-revoke (a base-merge file may count as authored), never under-revoke. |
| **`delta` empty** (no changes since delegation) | Nothing to check | **Short-circuit.** Do not even fetch `pr_diff`; the delegation stands. |

### The truncated-`delta` rule, refined

A naive "any `delta` truncation → revoke" is wrong. The truncated overflow
is overwhelmingly base-merge files — exactly the noise `pr_diff` strips — so by
itself it proves nothing. `delta` truncation is only dangerous when it could
hide the *newness* of an **authored** unacceptable path. So the check is
filtered, not raw:

1. Intersect the (possibly truncated) `delta` with `pr_diff` and classify the
   result. Any unacceptable path here revokes with its **specific** reason
   (sensitive / out-of-scope), truncation or not.
2. If nothing visible is unacceptable **and** `delta` was truncated, fall back
   to `:too_large` **only if some authored path (`pr_diff`) is unacceptable at
   all** — i.e. the truncation could be masking whether that path is new. If
   every authored path is in scope, the hidden overflow is all base-merge noise
   and cannot hide an authored violation, so the delegation stands.

When `pr_diff` itself is truncated (`:no_filter`), we cannot bound the authored
set, so any `delta` truncation conservatively fails safe — the over-revoke
direction, consistent with the delta-only fallback above.

### Why the split, and "un-actionable delegations"

Failing closed on *any* truncation would make a large PR **un-actionable from
the moment it is delegated**: the delegate could never `bors r+`, even after
touching nothing, purely because the PR was big when they were handed the keys.

The split avoids this. The decisive test case:

| >3000-file PR, **no changes** after delegation | Split policy | Block-on-any-truncation |
|---|---|---|
| `bors r+` | empty `delta` → nothing to check → **approves** ✅ | `pr_diff` truncated → **denied** ❌ |

Under the split policy, a delegation becomes un-actionable only if the
delegate's own post-delegation changes exceed ~300 files **and** include an
authored path outside the configured scope (per the refined truncated-`delta`
rule above). Syncing the base branch — even a busy one that pushes the raw
`delta` well past 300 — is *not* enough on its own; it is all base-merge noise.
The remaining un-actionable case is within the delegate's control and arguably
*should* demand a fresh human review. A large but finished PR stays fully
delegatable.

## User-facing messages

The entire feature reduces, for users, to one rule stated without any API
detail:

> If a change is too big for bors to check the full list of changed files, it
> assumes a protected path *might* have been touched and plays it safe.

The recurring phrase **"too many files for bors to check the full list"** is
deliberately honest (it implies the remedy — a smaller change) and never leaks
that the real cause is an API ceiling. The three places it surfaces:

1. **Standing note at delegation** (always, when either list is set): states
   the delegated scope (`restrict_to_paths`, if set) and the always-sensitive
   paths (`invalidate_on_paths`), and adds that bors also revokes "if a later
   push changes too many files for it to check the full list — even if it stays
   within scope."

2. **Revoke comment on push** (the truncation branch): "the latest push changed
   too many files for bors to check against the paths listed in
   `[delegation] invalidate_on_paths`, so it was revoked as a precaution."

3. **Approval denied at `bors r+`** (the fail-closed gate): "this pull request
   changes too many files for bors to check against the paths listed in
   `[delegation] invalidate_on_paths`. A reviewer needs to approve directly, or
   re-delegate after the change is split up."

In the ordinary (non-truncation) case, the revoke comment names the offending
path and *why* it was unacceptable — either "touched `path`, which is outside
the paths this delegation covers" (allow-list) or "touched `path`, which is
listed in `[delegation] invalidate_on_paths`" (deny-list) — so the author knows
whether to narrow their change or seek a fresh review.

A *proactive* large-PR heads-up at delegation time was considered and dropped:
under the split policy a large PR alone is no longer noteworthy (only a large
*post-delegation* push is), and that cannot be predicted when the delegation is
issued.

## Known limitations

- **Missed-push window.** All checks compare against the stored `patch.commit`,
  which the `synchronize` handler updates *synchronously* before spawning the
  (fire-and-forget) push-path invalidator. Two distinct races sit behind this,
  with different backstops — and crucially, **neither lets unverified content
  merge; the residual cost is an availability stall, not an integrity bypass:**
  - *Webhook delivered, async revocation not yet landed.* `patch.commit` is
    already fresh, so the **synchronous merge-time gate** re-derives the verdict
    from it at `r+` time regardless of whether the background invalidator has
    finished. This is the race the gate exists to close.
  - *Webhook never processed (dropped, or bors was down).* `patch.commit` stays
    stale, so the gate — which trusts the stored commit and does not re-fetch —
    cannot see the new head. The **batcher's `:race` guard** is the backstop
    here: at staging it compares the *live* head against `patch.commit`
    (`batcher.ex`) and refuses to merge a head that has moved, so the unverified
    push is dropped rather than merged. A later push (or re-`r+`) then re-gates
    against the new head and self-heals.

  Because a merge requires the live head to equal the `patch.commit` the gate
  blessed — and a push also cancels any in-flight batch (`Batcher.cancel` in the
  `synchronize` handler) — there is no path that merges a head bors never
  verified. The integrity guarantee in the second case rests entirely on the
  batcher's live-head `:race` check; weakening or bypassing it would turn the
  gate's reliance on a possibly-stale `patch.commit` into a real bypass.
- **`pr_diff` delta-only fallback over-revokes.** For a >3000-file PR whose
  `delta` includes base-merge content, the missing noise filter may revoke a
  delegation that a complete filter would have spared. This is the accepted
  safe direction.
- **`delta` is hard-capped at 300 by GitHub** with no pagination escape. This
  no longer revokes on its own (the filter runs first), but a post-delegation
  push that both exceeds 300 changed files *and* touches an out-of-scope
  authored path is un-mergeable by a delegate by design: the truncation hides
  whether that path is new, so bors fails safe.
- **Per-branch config and retargeting.** `[delegation]` options are read from
  the PR's current base branch, so retargeting a PR (GitHub's *edit base*) moves
  it onto that branch's rules — a delegation granted under one branch's
  `restrict_to_paths` / expiry is re-evaluated under the new branch's on the next
  push or `r+`. Keeping the options uniform across managed branches avoids the
  surprise; see [bors.toml provenance](#borstoml-provenance).

See also [bors-ng/rfcs](https://github.com/bors-ng/rfcs) for broader design
documentation.
