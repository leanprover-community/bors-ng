defmodule BorsNG.Worker.DelegationInvalidator do
  @moduledoc """
  Invalidates PR delegations when new author commits touch paths configured
  in bors.toml's `[delegation] invalidate_on_paths = [...]` list.

  ## bors.toml syntax

      [delegation]
      invalidate_on_paths = [
        "Cargo.toml",
        "Cargo.lock",
        ".github/**",
        "deps/**",
      ]

  Each entry is a glob pattern matched against repository-relative paths
  (forward slashes, no leading `./`). Matching uses Erlang's `:glob` module,
  which differs from gitignore in two important ways:

    * `*` matches any sequence of characters **including `/`**, so
      `.github/*` and `.github/**` are equivalent. There is no need to write
      `**` to recurse into subdirectories.
    * `?` matches a single character (not directory-aware).

  Patterns are anchored: `Cargo.toml` matches only the top-level file, not
  `foo/Cargo.toml`. Use `**/Cargo.toml` to match anywhere in the tree.

  ## Triggering and false-positive avoidance

  Runs from the `synchronize` webhook. To avoid false positives from
  GitHub's "Update branch" button (which also fires `synchronize`), we use
  the intersection of two compares to isolate "new author work since the
  delegation was issued":

      delta    = files in `compare(delegated_at_commit, current_head)`
      pr_diff  = files in `compare(base_branch, current_head)`   (three-dot)
      relevant = delta ∩ pr_diff

  `pr_diff` is a three-dot compare anchored at the base branch, so it
  represents only content the author has added in the PR (base-only content
  is naturally excluded). The intersection drops anything in `delta` that
  came from a base-merge.

  A delegation is invalidated when any path in `relevant` matches any
  configured glob.

  ## bors.toml provenance

  The `bors.toml` config is read from the PR's BASE branch, **not** from the
  PR head. A PR therefore cannot disable invalidation by editing its own
  copy of `bors.toml`.
  """

  import Ecto.Query

  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.UserPatchDelegation
  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.GetBorsToml

  require Logger

  @doc """
  Fire-and-forget entry point. Safe to call from `Task.start`. Loads the
  patch fresh from the DB to avoid stale state.
  """
  @spec invalidate_for_patch(Patch.id()) :: :ok
  def invalidate_for_patch(patch_id) do
    case Repo.get(Patch, patch_id) do
      nil ->
        :ok

      patch ->
        try do
          run(patch)
        rescue
          e ->
            Logger.warning(
              "DelegationInvalidator: crashed for patch #{patch_id}: #{Exception.message(e)}"
            )

            :ok
        end
    end
  end

  defp run(patch) do
    delegations = candidate_delegations(patch.id)

    if delegations == [] do
      :ok
    else
      project = Repo.get!(Project, patch.project_id)
      conn = Project.installation_connection(project.repo_xref, Repo)

      with {:ok, toml} <- GetBorsToml.get(conn, patch.into_branch),
           [_ | _] = patterns <- toml.delegation_invalidate_on_paths do
        do_invalidate(conn, patch, patterns, delegations)
      else
        _ -> :ok
      end
    end
  end

  defp candidate_delegations(patch_id) do
    from(d in UserPatchDelegation,
      where: d.patch_id == ^patch_id and not is_nil(d.delegated_at_commit),
      preload: [:user]
    )
    |> Repo.all()
  end

  defp do_invalidate(conn, patch, patterns, delegations) do
    case GitHub.get_pr_compare(conn, patch.into_branch, patch.commit) do
      {:ok, pr_diff_files} ->
        pr_diff_set = MapSet.new(pr_diff_files, & &1.filename)

        Enum.each(delegations, fn d ->
          check_delegation(conn, patch, patterns, pr_diff_set, d)
        end)

      {:error, reason} ->
        Logger.warning(
          "DelegationInvalidator: compare(base, head) failed for patch #{patch.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp check_delegation(conn, patch, patterns, pr_diff_set, delegation) do
    case GitHub.get_pr_compare(conn, delegation.delegated_at_commit, patch.commit) do
      {:ok, delta_files} ->
        matched =
          delta_files
          |> Enum.map(& &1.filename)
          |> Enum.filter(&MapSet.member?(pr_diff_set, &1))
          |> Enum.find(&matches_any?(&1, patterns))

        case matched do
          nil -> :ok
          path -> invalidate!(conn, patch, delegation, path)
        end

      {:error, reason} ->
        Logger.warning(
          "DelegationInvalidator: compare(delegation #{delegation.id}, head) failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc false
  def matches_any?(path, patterns) do
    Enum.any?(patterns, fn pattern -> path == pattern or :glob.matches(path, pattern) end)
  end

  defp invalidate!(conn, patch, delegation, matched_path) do
    Repo.delete!(delegation)

    msg =
      ":no_entry_sign: Delegation for @#{delegation.user.login} revoked: " <>
        "the latest push touched `#{matched_path}`, which is listed in " <>
        "`[delegation] invalidate_on_paths` in bors.toml. " <>
        "Re-issue with `bors d=#{delegation.user.login} for=...` if appropriate."

    try do
      GitHub.post_comment!(conn, patch.pr_xref, msg)
    rescue
      e ->
        Logger.warning(
          "DelegationInvalidator: failed to comment on PR ##{patch.pr_xref}: #{Exception.message(e)}"
        )
    end
  end
end
