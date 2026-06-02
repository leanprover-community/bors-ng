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

  If the PR is rebased or force-pushed, `delegated_at_commit` may no longer
  be an ancestor of the current head. The three-dot compare then anchors at
  an earlier merge-base, widening `delta`. This errs toward over-revoking
  (the safe direction for a security control): the worst case is a delegation
  that must be re-issued, never one that silently survives a sensitive change.

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
  Fire-and-forget entry point. Safe to call from a supervised task. Loads
  the patch (with its project) fresh from the DB to avoid stale state.
  """
  @spec invalidate_for_patch(Patch.id()) :: :ok
  def invalidate_for_patch(patch_id) do
    case Repo.one(from(p in Patch, where: p.id == ^patch_id, preload: :project)) do
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
      conn = Project.installation_connection(patch.project.repo_xref, Repo)

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

        revoked =
          Enum.flat_map(delegations, fn d ->
            matching_path(conn, patch, patterns, pr_diff_set, d)
          end)

        if revoked != [] do
          ids = Enum.map(revoked, fn {d, _path} -> d.id end)
          Repo.delete_all(from(d in UserPatchDelegation, where: d.id in ^ids))
          post_revoke_comment(conn, patch, revoked)
        end

      # The GitHub client returns error tuples of several arities
      # ({:error, action, status, params}, {:error, reason, action}, ...),
      # never a bare {:error, reason}, so match anything that isn't {:ok, _}.
      other ->
        Logger.warning(
          "DelegationInvalidator: compare(base, head) failed for patch #{patch.id}: #{inspect(other)}"
        )

        :ok
    end
  end

  defp matching_path(conn, patch, patterns, pr_diff_set, delegation) do
    case GitHub.get_pr_compare(conn, delegation.delegated_at_commit, patch.commit) do
      {:ok, delta_files} ->
        matched =
          delta_files
          |> Enum.map(& &1.filename)
          |> Enum.filter(&MapSet.member?(pr_diff_set, &1))
          |> Enum.find(&matches_any?(&1, patterns))

        case matched do
          nil -> []
          path -> [{delegation, path}]
        end

      # See note in do_invalidate/4: the client never returns a bare
      # {:error, reason}; match any non-{:ok, _} shape.
      other ->
        Logger.warning(
          "DelegationInvalidator: compare(delegation #{delegation.id}, head) failed: #{inspect(other)}"
        )

        []
    end
  end

  @doc false
  def matches_any?(path, patterns) do
    Enum.any?(patterns, fn pattern -> path == pattern or :glob.matches(path, pattern) end)
  end

  @doc """
  Returns the subset of `patterns` that match zero entries in `tree`.

  Used by the bors-try lint to flag typos in `[delegation] invalidate_on_paths`
  before they silently fail to protect anything.
  """
  @spec unmatched_paths([binary], [binary]) :: [binary]
  def unmatched_paths(patterns, tree) do
    Enum.reject(patterns, fn pattern ->
      Enum.any?(tree, &matches_any?(&1, [pattern]))
    end)
  end

  @doc """
  Fire-and-forget lint of a patch's base-branch bors.toml. If any pattern in
  `[delegation] invalidate_on_paths` matches zero files in the base branch's
  HEAD tree, posts a single warning comment on the PR.
  """
  @spec lint_for_patch(Patch.id()) :: :ok
  def lint_for_patch(patch_id) do
    case Repo.one(from(p in Patch, where: p.id == ^patch_id, preload: :project)) do
      nil ->
        :ok

      patch ->
        try do
          lint(patch)
        rescue
          e ->
            Logger.warning(
              "DelegationInvalidator.lint: crashed for patch #{patch_id}: #{Exception.message(e)}"
            )

            :ok
        end
    end
  end

  defp lint(patch) do
    conn = Project.installation_connection(patch.project.repo_xref, Repo)

    with {:ok, toml} <- GetBorsToml.get(conn, patch.into_branch),
         [_ | _] = patterns <- toml.delegation_invalidate_on_paths,
         {:ok, tree} <- GitHub.get_repo_tree(conn, patch.into_branch) do
      case unmatched_paths(patterns, tree) do
        [] -> :ok
        bad -> post_lint_comment(conn, patch.pr_xref, bad)
      end
    else
      _ -> :ok
    end
  end

  defp post_lint_comment(conn, pr_xref, bad) do
    rendered = bad |> Enum.map(&"`#{&1}`") |> Enum.join(", ")

    msg =
      ":warning: These patterns in `[delegation] invalidate_on_paths` match no files " <>
        "in the base branch's HEAD: " <>
        rendered <>
        ". Check for typos — they may not protect what you intended."

    # The lint fires on every `bors try`, so dedup before posting. Match on the
    # exact body: if the set of unmatched patterns changes, the message changes
    # and we warn afresh. If reading comments fails, fall back to posting — a
    # possible duplicate beats silently dropping the warning.
    case GitHub.get_pr_comments(conn, pr_xref) do
      {:ok, comments} -> unless msg in comments, do: safe_post(conn, pr_xref, msg)
      _ -> safe_post(conn, pr_xref, msg)
    end
  end

  defp post_revoke_comment(conn, patch, [{delegation, matched_path}]) do
    msg =
      ":no_entry_sign: Delegation for @#{delegation.user.login} revoked: " <>
        "the latest push touched `#{matched_path}`, which is listed in " <>
        "`[delegation] invalidate_on_paths` in bors.toml. " <>
        "Re-issue with `bors d=#{delegation.user.login} for=...` if appropriate."

    safe_post(conn, patch.pr_xref, msg)
  end

  defp post_revoke_comment(conn, patch, revoked) do
    bullets =
      revoked
      |> Enum.map(fn {d, path} -> "- @#{d.user.login} — touched `#{path}`" end)
      |> Enum.join("\n")

    msg =
      ":no_entry_sign: Delegations revoked because the latest push touched paths " <>
        "listed in `[delegation] invalidate_on_paths` in bors.toml:\n\n" <>
        bullets <>
        "\n\nRe-issue with `bors d=...` if appropriate."

    safe_post(conn, patch.pr_xref, msg)
  end

  defp safe_post(conn, pr_xref, msg) do
    GitHub.post_comment!(conn, pr_xref, msg)
  rescue
    e ->
      Logger.warning(
        "DelegationInvalidator: failed to comment on PR ##{pr_xref}: #{Exception.message(e)}"
      )
  end
end
