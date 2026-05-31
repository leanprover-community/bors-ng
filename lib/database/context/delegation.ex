defmodule BorsNG.Database.Context.Delegation do
  @moduledoc """
  Lifecycle management for PR delegations (`UserPatchDelegation`).

  Two kinds of work live here:

    * `sweep/0` — the time-driven pass. It deletes delegations that have
      passed their `expires_at` (posting an "expired" notice) and posts a
      24-hour warning for delegations about to expire. There is no GitHub
      event for "a delegation just expired" or "expires in 24h", so this has
      to be polled; `BorsNG.Worker.DelegationTimer` runs it on an interval.

    * `reconcile_default_expiry/2` — the config-driven part. When bors reads a
      `bors.toml` that sets `default_expiry_sec`, any forever-delegations on
      that PR get retroactively stamped with the default. This is invoked at
      the point bors observes the `bors.toml`, not on a timer.

  Note that expiry is *enforced* lazily in
  `BorsNG.Database.Context.Permission.patch_delegated_reviewer?/2`, which
  ignores delegations whose `expires_at` has passed. The deletes here are
  therefore housekeeping plus notification, not access control.
  """

  use BorsNG.Database.Context

  alias BorsNG.Command
  alias BorsNG.GitHub

  require Logger

  @doc """
  Run the time-driven delegation pass: expire past-due delegations and warn
  about delegations expiring within 24 hours.
  """
  def sweep do
    expire_delegations()
    warn_delegations()
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

      expired
      |> Enum.filter(&(&1.patch && &1.patch.open && &1.patch.project))
      |> Enum.with_index()
      |> Enum.each(fn {d, idx} ->
        pace_comment(idx)
        post_expired_comment(d)
      end)
    end
  end

  defp warn_delegations do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    warn_until = NaiveDateTime.add(now, 24 * 60 * 60, :second)

    candidates =
      Repo.all(
        from(d in UserPatchDelegation,
          where: not is_nil(d.expires_at) and is_nil(d.warning_sent_at),
          where: d.expires_at > ^now and d.expires_at <= ^warn_until,
          preload: [:user, patch: :project]
        )
      )

    candidates
    |> Enum.filter(&(&1.patch && &1.patch.open && &1.patch.project))
    |> Enum.with_index()
    |> Enum.each(fn {d, idx} ->
      pace_comment(idx)

      if post_warning_comment(d) do
        d
        |> Ecto.Changeset.change(warning_sent_at: now)
        |> Repo.update!()
      end
    end)
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

  defp post_warning_comment(d) do
    now = NaiveDateTime.utc_now()
    secs_remaining = NaiveDateTime.diff(d.expires_at, now)
    duration_str = Command.format_duration(secs_remaining)

    msg =
      ":hourglass_flowing_sand: @#{d.user.login}, your delegation on this PR expires " <>
        "in approximately #{duration_str} " <>
        "(at #{Command.format_expires_at(d.expires_at)})."

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
