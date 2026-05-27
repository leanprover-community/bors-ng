defmodule Mix.Tasks.Bors.Cleanup do
  use Mix.Task
  import Mix.Ecto
  import Ecto.Query

  require Logger

  alias BorsNG.Command
  alias BorsNG.Database.Project
  alias BorsNG.Database.UserPatchDelegation
  alias BorsNG.GitHub

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

    Enum.each(expired, fn d ->
      BorsNG.Database.Repo.delete!(d)

      if d.patch && d.patch.open && d.patch.project do
        post_expired_comment(d)
      end
    end)
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

    Enum.each(candidates, fn d ->
      cond do
        is_nil(d.patch) or not d.patch.open or is_nil(d.patch.project) ->
          :skip

        post_warning_comment(d) ->
          d
          |> Ecto.Changeset.change(warning_sent_at: now)
          |> BorsNG.Database.Repo.update!()

        true ->
          :skip
      end
    end)
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
