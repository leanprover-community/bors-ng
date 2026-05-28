defmodule Mix.Tasks.Bors.Cleanup do
  use Mix.Task
  import Mix.Ecto
  import Ecto.Query

  require Logger

  alias BorsNG.Command
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.UserPatchDelegation
  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher

  @requirements ["app.start"]

  @shortdoc "Prune old batches and patches, expire delegations"

  @moduledoc """
  Maintenance task: deletes old batches/patches/crashes, expires delegations
  that have passed their `expires_at`, and posts 24-hour warning comments
  for delegations about to expire.

  Delegation passes always run. Pass `--months N` to additionally clean
  closed batches, patches, and crash reports older than N months.

  ## Examples
      mix bors.cleanup
      mix bors.cleanup --months 6

  ## Command line options
    * `--months` - integer; also delete batches/patches/crashes older than this
  """

  @doc false
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [months: :integer])

    Enum.each(repos(), fn repo ->
      ensure_repo(repo, args)

      run_delegation_pass()

      case opts do
        [months: months] when is_integer(months) ->
          Mix.shell().info("Cleaning data older than #{inspect(months)} months")
          run_age_pass(months)

        _ ->
          :ok
      end
    end)
  end

  def repos, do: [BorsNG.Application.fetch_repo()]

  defp run_age_pass(months) do
    negative_months = 0 - months

    BorsNG.Database.Repo.delete_all(
      from(p in BorsNG.Database.Batch,
        where:
          p.state in [^:ok, ^:error, ^:canceled] and
            p.updated_at < datetime_add(^NaiveDateTime.utc_now(), ^negative_months, "month")
      )
    )

    BorsNG.Database.Repo.delete_all(
      from(p in BorsNG.Database.Patch,
        where:
          not p.open and
            p.updated_at < datetime_add(^NaiveDateTime.utc_now(), ^negative_months, "month")
      )
    )

    BorsNG.Database.Repo.delete_all(
      from(p in BorsNG.Database.Crash,
        where: p.updated_at < datetime_add(^NaiveDateTime.utc_now(), ^negative_months, "month")
      )
    )
  end

  defp run_delegation_pass do
    expire_delegations()
    warn_delegations()
    backfill_delegations()
  end

  # Forever-delegations on open PRs get retroactively stamped with the
  # project's bors.toml default once that key appears. Groups candidates
  # by {project, into_branch} so we fetch bors.toml once per group. Each
  # affected PR gets one comment, paced to stay under GitHub's secondary
  # rate limit.
  defp backfill_delegations do
    candidates =
      BorsNG.Database.Repo.all(
        from(d in UserPatchDelegation,
          join: p in Patch,
          on: p.id == d.patch_id,
          where: is_nil(d.expires_at) and p.open,
          preload: [:user, patch: :project]
        )
      )
      |> Enum.filter(&(&1.patch && &1.patch.project))

    candidates
    |> Enum.group_by(&{&1.patch.project.id, &1.patch.into_branch})
    |> Enum.flat_map(fn {_key, group} ->
      project = hd(group).patch.project
      branch = hd(group).patch.into_branch

      case fetch_default_expiry(project, branch) do
        nil -> []
        duration when is_integer(duration) -> [{group, duration}]
      end
    end)
    |> apply_backfill()
  end

  defp fetch_default_expiry(project, branch) do
    conn = Project.installation_connection(project.repo_xref, BorsNG.Database.Repo)

    case Batcher.GetBorsToml.get(conn, branch) do
      {:ok, toml} -> toml.delegation_default_expiry_sec
      {:error, _} -> nil
    end
  end

  defp apply_backfill(groups) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    groups
    |> Enum.flat_map(fn {delegations, duration} ->
      expires_at = NaiveDateTime.add(now, duration, :second)
      ids = Enum.map(delegations, & &1.id)

      BorsNG.Database.Repo.update_all(
        from(d in UserPatchDelegation, where: d.id in ^ids),
        set: [expires_at: expires_at, updated_at: now]
      )

      delegations
      |> Enum.group_by(& &1.patch, & &1.user)
      |> Enum.map(fn {patch, users} -> {patch, users, expires_at, duration} end)
    end)
    |> Enum.with_index()
    |> Enum.each(fn {entry, idx} ->
      pace_comment(idx)
      post_backfill_comment(entry)
    end)
  end

  defp post_backfill_comment({patch, users, expires_at, duration}) do
    logins =
      users
      |> Enum.map(&"@#{&1.login}")
      |> Enum.uniq()
      |> Enum.join(", ")

    msg =
      ":hourglass: Existing delegations on this PR (#{logins}) will expire on " <>
        "#{Command.format_expires_at(expires_at)} " <>
        "(in #{Command.format_duration(duration)}) " <>
        "following a `default_expiry_sec` setting in `bors.toml`."

    safe_post_comment(patch.project, patch.pr_xref, msg)
  end

  defp expire_delegations do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    expired =
      BorsNG.Database.Repo.all(
        from(d in UserPatchDelegation,
          where: not is_nil(d.expires_at) and d.expires_at <= ^now,
          preload: [:user, patch: :project]
        )
      )

    if expired != [] do
      ids = Enum.map(expired, & &1.id)

      BorsNG.Database.Repo.delete_all(from(d in UserPatchDelegation, where: d.id in ^ids))

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
      BorsNG.Database.Repo.all(
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
        |> BorsNG.Database.Repo.update!()
      end
    end)
  end

  # Sleep ~750ms (+jitter) between comments so a busy cron tick doesn't
  # trip GitHub's secondary rate limit for content creation.
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
    duration_str = Command.format_duration(max(secs_remaining, 60))

    msg =
      ":hourglass_flowing_sand: @#{d.user.login}, your delegation on this PR expires " <>
        "in approximately #{duration_str} " <>
        "(at #{Command.format_expires_at(d.expires_at)})."

    safe_post_comment(d.patch.project, d.patch.pr_xref, msg)
  end

  defp safe_post_comment(project, pr_xref, msg) do
    conn = Project.installation_connection(project.repo_xref, BorsNG.Database.Repo)
    GitHub.post_comment!(conn, pr_xref, msg)
    true
  rescue
    e ->
      Logger.warning(
        "bors.cleanup: failed to post comment on PR ##{pr_xref}: #{Exception.message(e)}"
      )

      false
  end
end
