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

  # GitHub's per-endpoint changed-file ceilings. Reaching either means the file
  # list may be incomplete, which we treat as truncation. See
  # DELEGATION_INVALIDATION.md, "GitHub API file ceilings": compare(base...head)
  # caps at 300 with no file pagination; pulls/{n}/files caps at 3000.
  @compare_file_cap 300
  @pr_files_cap 3000

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
           restrict = toml.delegation_restrict_to_paths,
           deny = toml.delegation_invalidate_on_paths,
           true <- restrict != [] or deny != [] do
        do_invalidate(conn, patch, restrict, deny, delegations)
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

  defp do_invalidate(conn, patch, restrict, deny, delegations) do
    # pr_diff is the same base...head diff for every delegation; fetch it once.
    # On synchronize a push always happened, so a delta worth filtering exists.
    filter = pr_diff_filter(conn, patch)

    revoked =
      Enum.flat_map(delegations, fn d ->
        case classify_delegation(conn, patch, restrict, deny, filter, d) do
          {:revoke, reason} -> [{d, reason}]
          # :ok and :unverifiable both leave the delegation in place here:
          # the push path fails open and relies on the next push (or the
          # merge-time gate) to catch anything this run could not verify.
          _ -> []
        end
      end)

    if revoked != [] do
      ids = Enum.map(revoked, fn {d, _reason} -> d.id end)
      Repo.delete_all(from(d in UserPatchDelegation, where: d.id in ^ids))
      post_revoke_comment(conn, patch, revoked)
    end

    :ok
  end

  # Classify a single delegation against the current head.
  #
  #   :ok               delegation is still valid
  #   {:revoke, reason} revoke it; reason drives the comment
  #   :unverifiable     the delta compare failed; the caller decides (the push
  #                     path skips/fails-open, the merge-time gate fails-closed)
  #
  # reason :: {:sensitive, path} | {:out_of_scope, path} | :too_large
  @doc false
  def classify_delegation(conn, patch, restrict, deny, filter, delegation) do
    case GitHub.get_pr_compare(conn, delegation.delegated_at_commit, patch.commit) do
      # Empty delta: nothing changed since delegation, so nothing to check.
      {:ok, []} ->
        :ok

      # Hit the compare cap: we cannot enumerate the post-delegation changes,
      # so a sensitive/out-of-scope path may be hidden. Fail safe.
      {:ok, files} when length(files) >= @compare_file_cap ->
        {:revoke, :too_large}

      {:ok, files} ->
        files
        |> Enum.map(& &1.filename)
        |> apply_filter(filter)
        |> Enum.find_value(&classify_path(&1, restrict, deny))
        |> case do
          nil -> :ok
          reason -> {:revoke, reason}
        end

      # The GitHub client returns error tuples of several arities, never a bare
      # {:error, reason}, so match anything that isn't an {:ok, _} we handle.
      other ->
        Logger.warning(
          "DelegationInvalidator: delta compare failed for delegation #{delegation.id}: #{inspect(other)}"
        )

        :unverifiable
    end
  end

  # The PR's own file list, used to filter base-merge noise out of a delta.
  # {:filter, set} when fully known; :no_filter when truncated or unavailable,
  # in which case the delta is evaluated directly (delta-only fallback, which
  # can only over-revoke). See DELEGATION_INVALIDATION.md, "Truncation policy".
  @doc false
  def pr_diff_filter(conn, patch) do
    case GitHub.get_pr_files(conn, patch.pr_xref) do
      {:ok, files} when length(files) < @pr_files_cap ->
        {:filter, MapSet.new(files, & &1.filename)}

      {:ok, _capped} ->
        :no_filter

      other ->
        Logger.warning(
          "DelegationInvalidator: pr_diff (get_pr_files) failed for patch #{patch.id}: #{inspect(other)}"
        )

        :no_filter
    end
  end

  defp apply_filter(filenames, :no_filter), do: filenames

  defp apply_filter(filenames, {:filter, set}),
    do: Enum.filter(filenames, &MapSet.member?(set, &1))

  # Deny-list overrides allow-list; an unset allow-list imposes no scope. See
  # DELEGATION_INVALIDATION.md, "Deciding what's acceptable". Returns nil when
  # the path is acceptable.
  defp classify_path(path, restrict, deny) do
    cond do
      matches_any?(path, deny) -> {:sensitive, path}
      restrict != [] and not matches_any?(path, restrict) -> {:out_of_scope, path}
      true -> nil
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

  defp post_revoke_comment(conn, patch, [{delegation, reason}]) do
    msg =
      ":no_entry_sign: Delegation for @#{delegation.user.login} revoked: the latest push " <>
        reason_clause(reason) <>
        ". Re-issue with `bors d=#{delegation.user.login} for=...` if appropriate."

    safe_post(conn, patch.pr_xref, msg)
  end

  defp post_revoke_comment(conn, patch, revoked) do
    bullets =
      revoked
      |> Enum.map(fn {d, reason} -> "- @#{d.user.login} — #{reason_clause(reason)}" end)
      |> Enum.join("\n")

    msg =
      ":no_entry_sign: Delegations revoked because the latest push changed paths they " <>
        "no longer cover:\n\n" <>
        bullets <>
        "\n\nRe-issue with `bors d=...` if appropriate."

    safe_post(conn, patch.pr_xref, msg)
  end

  # Renders the reason half of a revoke comment, following "the latest push ".
  defp reason_clause({:sensitive, path}),
    do: "touched `#{path}`, which is listed in `[delegation] invalidate_on_paths` in bors.toml"

  defp reason_clause({:out_of_scope, path}),
    do:
      "touched `#{path}`, which is outside the paths this delegation covers " <>
        "(`[delegation] restrict_to_paths` in bors.toml)"

  defp reason_clause(:too_large),
    do: "changed too many files for bors to check the full list against the configured paths"

  defp safe_post(conn, pr_xref, msg) do
    GitHub.post_comment!(conn, pr_xref, msg)
  rescue
    e ->
      Logger.warning(
        "DelegationInvalidator: failed to comment on PR ##{pr_xref}: #{Exception.message(e)}"
      )
  end
end
