# GitHub API Resilience

This document describes how bors-ng handles transient GitHub API failures,
the deliberate design tradeoffs involved, and the known limitations.

## The `!` (bang) convention

Functions in `lib/github/github.ex` follow the Elixir convention:

- Non-bang variants (e.g. `GitHub.get_pr/2`) return `{:ok, value}` or
  `{:error, reason}` and let the caller decide what to do.
- Bang variants (e.g. `GitHub.get_pr!/2`) pattern-match on `:ok` or
  `{:ok, value}` and crash the calling process on any other result.

A crash in the Batcher or Attemptor GenServer propagates to the Registry,
which then **actively cancels all running and waiting batches** for that
project and notifies via Zulip. Users must re-approve their PRs.

## `call_with_retry`

Most GitHub API calls go through `call_with_retry/4` in `github.ex`, which:

1. Makes the GenServer call via `safe_genserver_call`, catching timeouts and
   exits as `{:error, reason}` tuples rather than letting them crash.
2. On any non-success result, sleeps with exponential backoff (with jitter)
   and retries until the configured retry window elapses.
3. Returns the last error result when the window is exhausted — the caller
   then decides what to do with it (bang variants crash; non-bang variants
   return it).

### Retry parameters

| Call type         | Initial delay | Max delay | Retry window config key                        | Default  |
|-------------------|---------------|-----------|------------------------------------------------|----------|
| Read operations   | 500 ms        | 4 000 ms  | `api_github_retry_max_elapsed_ms`              | 180 s    |
| Write operations  | 500 ms        | 4 000 ms  | `api_github_retry_write_max_elapsed_ms`        | 30 s     |
| `post_commit_status`, `get_branch` | 500 ms | 4 000 ms | `api_github_retry_max_elapsed_ms`   | 180 s    |

All write operations (`synthesize_commit!`, `force_push!`, `delete_branch!`,
`merge_branch!`, `post_comment!`) now go through `call_with_retry`. Previously
several of these used direct `GenServer.call` with no retry at all.

### Single-call timeout

`api_github_timeout` (default 100 s) is both the GenServer call timeout and
the Tesla HTTP receive timeout. With a 180 s retry window, a single timeout
exhausts most of the window — in practice the number of retries for write
operations has been low.

## Resilience layers

### Layer 1 — Tolerate notification failures (implemented)

`send_status` and `send_message` post GitHub commit statuses and PR comments.
These are **pure notifications**: bors's correctness does not depend on them
succeeding. A failure here should log and continue, not crash the process.

Prior to this fix, a GitHub timeout in `send_status` would crash the Batcher
GenServer, causing the Registry to cancel all batches.

### Layer 2 — Retry coverage for write operations (implemented)

`call_with_retry` was added to the write operations that previously made
direct GenServer calls (`synthesize_commit!`, `force_push!`, `get_branch!`,
`post_comment!`). This keeps the crash-on-exhaustion semantics (the batch
still fails if GitHub is unreachable for the full retry window) but gives
these calls a fighting chance against brief transient failures.

### Layer 3 — Batch persistence through extended outages (not yet implemented)

Keeping batches in `:running` state during extended GitHub outages and
retrying via the poll loop (every `poll_period`, default 30 min) would avoid
requiring users to re-approve PRs after an outage. This is not yet
implemented because of the following unresolved design questions:

**Error taxonomy.** We need to reliably distinguish transient failures
(timeout, 5xx) from permanent ones (401/403, non-fast-forward 422). Getting
this wrong causes infinite retry loops on permanent errors.

**Staging branch lock.** A batch stuck in `:running` freezes the staging
branch. No new batches can build on top of it for the entire outage duration.
Head-of-line blocking would affect all PRs queued behind the stuck batch.

**Partial write state.** The staging branch setup involves a sequence of
writes (`synthesize_commit!` → `merge_branch!` → `force_push!` →
`delete_branch!`). If the sequence fails partway through, the staging branch
may be in an inconsistent state. Retrying from the top is not always safe;
resuming from the middle requires tracking progress explicitly.

**User visibility.** A batch showing as "running" for hours during a GitHub
outage is ambiguous — users cannot tell whether CI is still running or bors
is stuck. A failed batch, while disruptive, at least provides clear signal.

**Maximum retry deadline.** Any retry scheme needs a deadline after which
the batch is abandoned. The right value is unclear, and the `timeout_sec`
bors.toml option (already used for CI timeouts) is a related but distinct
concept.

A design for Layer 3 should address all of these before implementation. See
also [bors-ng/rfcs](https://github.com/bors-ng/rfcs) — no RFC currently
covers GitHub API failure tolerance, so one would be appropriate before
undertaking Layer 3.
