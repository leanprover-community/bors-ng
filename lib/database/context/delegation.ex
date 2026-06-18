defmodule BorsNG.Database.Context.Delegation do
  @moduledoc """
  Lifecycle management for PR delegations (`UserPatchDelegation`).

  Two kinds of work live here:

    * `sweep/0` — the time-driven pass. It deletes delegations that have
      passed their `expires_at` (posting an "expired" notice), posts warnings
      as a delegation approaches expiry (a week out, then a day out), and
      backfills `default_expiry_sec` onto any lingering forever-delegations.
      There is no GitHub event for "a delegation just expired" or "expires
      soon", so this has to be polled; `BorsNG.Worker.DelegationTimer` runs it
      on an interval.

    * `reconcile_default_expiry/2` — the config-driven part. When bors reads a
      `bors.toml` that sets `default_expiry_sec`, any forever-delegations on
      that PR get retroactively stamped with the default. This is invoked
      eagerly at the point bors observes the `bors.toml` (a `bors delegate`
      command or a patch preflight), and is also called from the `sweep/0`
      backfill pass so it eventually catches PRs that aren't otherwise
      touched after the default is first configured.

  Note that expiry is *enforced* lazily in
  `BorsNG.Database.Context.Permission.patch_delegated_reviewer?/2`, which
  ignores delegations whose `expires_at` has passed. The deletes here are
  therefore housekeeping plus notification, not access control.
  """

  use BorsNG.Database.Context

  alias BorsNG.Command
  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.GetBorsToml
  alias BorsNG.Worker.Labeler

  require Logger

  # Warning tiers, ordered from earliest to latest. Each fires once when a
  # delegation enters its window, recording the time in its own column so it
  # isn't repeated. The windows are disjoint — each is bounded below by the
  # next tier's threshold — so a single sweep posts at most one warning per
  # delegation, while a long-lived delegation still gets each warning in turn
  # (a week out, then a day out).
  @day_sec 24 * 60 * 60
  @week_sec 7 * @day_sec
  @warning_tiers [
    {:week_warning_sent_at, @day_sec, @week_sec, "a week"},
    {:warning_sent_at, 0, @day_sec, "24 hours"}
  ]

  @doc """
  Run the time-driven delegation pass: expire past-due delegations, warn about
  delegations approaching expiry (a week out, then a day out), and backfill
  `default_expiry_sec` onto forever-delegations whose PR hasn't been touched
  since the default was set.

  Backfill runs last so that a short default doesn't produce both a backfill
  comment and an expiry warning in the same tick; the warning, if any, lands on
  the following sweep.
  """
  def sweep do
    expire_delegations()
    warn_delegations()
    backfill_default_expiry()
  end

  @doc """
  Retroactively stamp `expires_at` on the forever-delegations of an open
  patch, using the `default_expiry_sec` observed in `bors.toml`.

  `default_expiry_sec` may be `nil` (no default configured), in which case
  this is a no-op. Returns the delegations that were stamped.
  """
  def reconcile_default_expiry(_patch, nil), do: []

  def reconcile_default_expiry(%Patch{open: false}, _duration), do: []

  def reconcile_default_expiry(%Patch{} = patch, duration) when is_integer(duration) do
    candidates =
      Repo.all(
        from(d in UserPatchDelegation,
          where: d.patch_id == ^patch.id and is_nil(d.expires_at),
          preload: [:user]
        )
      )

    case candidates do
      [] ->
        []

      delegations ->
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        expires_at = NaiveDateTime.add(now, duration, :second)
        ids = Enum.map(delegations, & &1.id)

        Repo.update_all(
          from(d in UserPatchDelegation, where: d.id in ^ids),
          set: [expires_at: expires_at, updated_at: now]
        )

        post_backfill_comment(patch, delegations, expires_at, duration)
        delegations
    end
  end

  defp post_backfill_comment(patch, delegations, expires_at, duration) do
    project = Repo.get!(Project, patch.project_id)

    logins =
      delegations
      |> Enum.map(&"@#{&1.user.login}")
      |> Enum.uniq()
      |> Enum.join(", ")

    msg =
      ":hourglass: Existing delegations on this PR (#{logins}) will expire on " <>
        "#{Command.format_expires_at(expires_at)} " <>
        "(in #{Command.format_duration(duration)}) " <>
        "following a `default_expiry_sec` setting in `bors.toml`."

    safe_post_comment(project, patch.pr_xref, msg)
  end

  defp expire_delegations do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    expired =
      Repo.all(
        from(d in UserPatchDelegation,
          where: not is_nil(d.expires_at) and d.expires_at <= ^now,
          preload: [:user, patch: :project]
        )
      )

    if expired != [] do
      ids = Enum.map(expired, & &1.id)

      Repo.delete_all(from(d in UserPatchDelegation, where: d.id in ^ids))

      expired_open = Enum.filter(expired, &(&1.patch && &1.patch.open && &1.patch.project))

      expired_open
      |> Enum.with_index()
      |> Enum.each(fn {d, idx} ->
        pace_comment(idx)
        post_expired_comment(d)
      end)

      # Reconcile the `delegated` label once per affected patch — a patch may
      # have had several delegations expire in the same tick. Done after the
      # deletes so the label reflects whether *any* delegation still stands;
      # this is the fix for the label being stranded when a delegation times
      # out (there's no GitHub event a workflow could react to).
      #
      # Paced with the lighter label throttle, not `pace_comment`: this loop
      # only writes labels (no comments), so the ~750ms content-creation budget
      # would just be dead sleep. `d.patch` carries its preloaded `:project`, so
      # `reconcile_delegated/1` reuses it rather than re-reading the project.
      expired_open
      |> Enum.uniq_by(& &1.patch_id)
      |> Enum.with_index()
      |> Enum.each(fn {d, idx} ->
        Labeler.pace_write(idx)
        Labeler.reconcile_delegated(d.patch)
      end)
    end
  end

  defp warn_delegations do
    Enum.each(@warning_tiers, &warn_tier/1)
  end

  defp warn_tier({column, lower_sec, upper_sec, label}) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    lower = NaiveDateTime.add(now, lower_sec, :second)
    upper = NaiveDateTime.add(now, upper_sec, :second)

    candidates =
      Repo.all(
        from(d in UserPatchDelegation,
          where: not is_nil(d.expires_at) and is_nil(field(d, ^column)),
          where: d.expires_at > ^lower and d.expires_at <= ^upper,
          preload: [:user, patch: :project]
        )
      )

    candidates
    |> Enum.filter(&(&1.patch && &1.patch.open && &1.patch.project))
    |> Enum.with_index()
    |> Enum.each(fn {d, idx} ->
      pace_comment(idx)

      if post_warning_comment(d, label) do
        d
        |> Ecto.Changeset.change(%{column => now})
        |> Repo.update!()
      end
    end)
  end

  # Find open patches that still carry forever-delegations and re-read each
  # one's `bors.toml`, so a `default_expiry_sec` configured after the fact gets
  # applied without waiting for the next command or batch on that PR. The
  # per-patch stamping and notification is handled by `reconcile_default_expiry/2`.
  defp backfill_default_expiry do
    patch_ids =
      Repo.all(
        from(d in UserPatchDelegation,
          where: is_nil(d.expires_at),
          distinct: true,
          select: d.patch_id
        )
      )

    patches = Repo.all(from(p in Patch, where: p.id in ^patch_ids and p.open == true))

    Enum.reduce(patches, 0, fn patch, posted ->
      pace_comment(posted)

      case backfill_patch(patch) do
        [] -> posted
        _ -> posted + 1
      end
    end)
  end

  defp backfill_patch(patch) do
    project = Repo.get!(Project, patch.project_id)
    conn = Project.installation_connection(project.repo_xref, Repo)

    # Sweep-time read: a slightly stale default-expiry config self-corrects on
    # the next sweep, and the eager command/preflight path always reads fresh,
    # so the cache is safe here and spares the sweep a per-patch GitHub read.
    case GetBorsToml.get_cached(conn, patch.into_branch) do
      {:ok, toml} -> reconcile_default_expiry(patch, toml.delegation_default_expiry_sec)
      {:error, _} -> []
    end
  rescue
    e ->
      Logger.warning(
        "delegation: backfill failed for patch ##{patch.id}: #{Exception.message(e)}"
      )

      []
  end

  # Sleep ~750ms (+jitter) between comments so a busy tick doesn't trip
  # GitHub's secondary rate limit for content creation.
  defp pace_comment(0), do: :ok

  defp pace_comment(_idx) do
    unless Application.get_env(:bors, :is_test, false) do
      Process.sleep(750 + :rand.uniform(250))
    end
  end

  defp post_expired_comment(d) do
    msg =
      ":hourglass: Delegation for @#{d.user.login} on this PR has expired " <>
        "(at #{Command.format_expires_at(d.expires_at)}). " <>
        "Reply with `bors d+` or `bors d=#{d.user.login}` with a `for=` argument to re-delegate."

    safe_post_comment(d.patch.project, d.patch.pr_xref, msg)
  end

  defp post_warning_comment(d, label) do
    now = NaiveDateTime.utc_now()
    secs_remaining = NaiveDateTime.diff(d.expires_at, now)
    duration_str = Command.format_duration(secs_remaining)

    msg =
      ":hourglass_flowing_sand: @#{d.user.login}, your delegation on this PR expires " <>
        "in less than #{label} " <>
        "(approximately #{duration_str}, at #{Command.format_expires_at(d.expires_at)})."

    safe_post_comment(d.patch.project, d.patch.pr_xref, msg)
  end

  defp safe_post_comment(project, pr_xref, msg) do
    conn = Project.installation_connection(project.repo_xref, Repo)
    GitHub.post_comment!(conn, pr_xref, msg)
    true
  rescue
    e ->
      Logger.warning(
        "delegation: failed to post comment on PR ##{pr_xref}: #{Exception.message(e)}"
      )

      false
  end
end
