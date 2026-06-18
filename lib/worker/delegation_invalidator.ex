defmodule BorsNG.Worker.DelegationInvalidator do
  @moduledoc """
  Invalidates PR delegations when new author work touches paths a project has
  restricted, and re-checks delegations at merge time.

  Configured under `[delegation]` in `bors.toml` (read from the PR's BASE
  branch, so a PR cannot disable it by editing its own copy):

      [delegation]
      restrict_to_paths   = ["src/**"]         # allow-list: delegation covers only these
      invalidate_on_paths = ["src/crypto.rs"]  # deny-list: always revoke (overrides the allow-list)

  Each entry is a glob matched against repository-relative paths via Erlang's
  `:glob`, which differs from gitignore: `*` matches across `/` (so
  `.github/*` and `.github/**` are equivalent, and `?` matches a single
  character), and patterns are anchored — `Cargo.toml` matches only the
  top-level file; use `**/Cargo.toml` to match anywhere in the tree.

  The full design — the two-compare model and "Update branch" noise filter,
  the allow-list/deny-list acceptability rule, GitHub's compare/PR-files
  ceilings and the resulting truncation policy, the synchronize-time
  (fail-open) versus merge-time (fail-closed) checks, and the user-facing
  messages — lives in `DELEGATION_INVALIDATION.md` at the repo root.
  """

  import Ecto.Query

  alias BorsNG.Database.Context.Permission
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
  alias BorsNG.Database.UserPatchDelegation
  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.GetBorsToml
  alias BorsNG.Worker.Labeler

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
        do_invalidate(conn, toml, patch, restrict, deny, delegations)
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

  defp do_invalidate(conn, toml, patch, restrict, deny, delegations) do
    # pr_diff is the same base...head diff for every delegation; fetch it once.
    # On synchronize a push always happened, so a delta worth filtering exists.
    filter = pr_diff_filter(conn, patch)
    filter_fun = fn -> filter end

    revoked =
      Enum.flat_map(delegations, fn d ->
        case classify_delegation(conn, patch, restrict, deny, filter_fun, d) do
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
      Labeler.reconcile_delegated(conn, toml, patch)
    end

    :ok
  end

  @doc """
  Synchronous merge-time gate, called from the `bors r+` authorization path.

  Re-checks the commenter's active delegation on the patch against the current
  head and **fails closed**: returns `:deny` (after revoking + commenting, or
  after a check it could not complete) so the caller refuses the approval.
  Returns `:ok` when there is nothing to block — the commenter is a project
  reviewer, has no active delegation, the config has no path lists, or the
  delegation is still valid. See DELEGATION_INVALIDATION.md, "When invalidation
  runs".
  """
  @spec verify_for_merge(Patch.t(), User.t()) :: :ok | :deny
  def verify_for_merge(patch, user) do
    patch = Repo.preload(patch, :project)

    # Project reviewers hold approval rights independent of any delegation, so
    # the delegation gate must not block (or revoke) them.
    if Permission.get_permission(user, patch.project) == :reviewer do
      :ok
    else
      case active_delegations_for(patch.id, user.id) do
        [] ->
          :ok

        delegations ->
          conn = Project.installation_connection(patch.project.repo_xref, Repo)

          with {:ok, toml} <- GetBorsToml.get(conn, patch.into_branch),
               restrict = toml.delegation_restrict_to_paths,
               deny = toml.delegation_invalidate_on_paths,
               true <- restrict != [] or deny != [] do
            decide_merge(conn, toml, patch, restrict, deny, delegations)
          else
            _ -> :ok
          end
      end
    end
  end

  defp decide_merge(conn, toml, patch, restrict, deny, delegations) do
    # Lazy + computed at most once: a (user, patch) delegation is unique, and an
    # empty delta short-circuits before the filter is ever forced.
    filter_fun = fn -> pr_diff_filter(conn, patch) end

    Enum.reduce_while(delegations, :ok, fn d, _acc ->
      case classify_delegation(conn, patch, restrict, deny, filter_fun, d) do
        :ok ->
          {:cont, :ok}

        {:revoke, reason} ->
          Repo.delete_all(from(x in UserPatchDelegation, where: x.id == ^d.id))
          post_revoke_comment(conn, patch, [{d, reason}])
          Labeler.reconcile_delegated(conn, toml, patch)
          {:halt, :deny}

        # Couldn't read the delta: don't delete (we can't prove it's bad), but
        # refuse this approval so a sensitive change can't slip through a failed
        # check. A later `bors r+` re-runs the gate.
        :unverifiable ->
          safe_post(conn, patch.pr_xref, unverifiable_message())
          {:halt, :deny}
      end
    end)
  end

  defp active_delegations_for(patch_id, user_id) do
    now = NaiveDateTime.utc_now()

    from(d in UserPatchDelegation,
      where:
        d.patch_id == ^patch_id and d.user_id == ^user_id and
          not is_nil(d.delegated_at_commit) and
          (is_nil(d.expires_at) or d.expires_at > ^now),
      preload: [:user]
    )
    |> Repo.all()
  end

  defp unverifiable_message do
    ":warning: Couldn't approve via delegation: bors was unable to read this pull " <>
      "request's changes from GitHub just now, so it can't confirm the delegation is " <>
      "still valid. Please try `bors r+` again in a moment."
  end

  # Classify a single delegation against the current head.
  #
  #   :ok               delegation is still valid
  #   {:revoke, reason} revoke it; reason drives the comment
  #   :unverifiable     the delta compare failed; the caller decides (the push
  #                     path skips/fails-open, the merge-time gate fails-closed)
  #
  # reason :: {:sensitive, path} | {:out_of_scope, path} | :too_large
  #
  # filter_fun is a thunk returning the pr_diff filter; it is forced only when a
  # non-empty delta actually needs filtering — including a truncated one, which
  # must be filtered before we react to its size — so an empty delta never
  # triggers a pr_diff fetch (the merge-time short-circuit).
  @doc false
  def classify_delegation(conn, patch, restrict, deny, filter_fun, delegation) do
    case GitHub.get_pr_compare(conn, delegation.delegated_at_commit, patch.commit) do
      # Empty delta: nothing changed since delegation, so nothing to check.
      {:ok, []} ->
        :ok

      {:ok, files} ->
        # GitHub caps compare at 300 files with no file pagination, so hitting
        # the cap means the delta may be incomplete. Crucially we must filter
        # *before* reacting to that: the delta is dominated by base-merge noise
        # — clicking "Update branch" drags in every file master touched since
        # the branch point — and that noise is exactly what the pr_diff filter
        # removes. Bailing to :too_large on the raw delta size (as we used to)
        # revokes every delegation the moment the author syncs a busy base
        # branch like mathlib4's master, which is the very case the filter
        # exists to allow.
        truncated? = length(files) >= @compare_file_cap
        filter = filter_fun.()

        files
        |> Enum.map(& &1.filename)
        |> apply_filter(filter)
        |> Enum.find_value(&classify_path(&1, restrict, deny))
        |> case do
          # A visible authored+new path is unacceptable: revoke with its
          # specific reason, regardless of truncation.
          reason when not is_nil(reason) ->
            {:revoke, reason}

          # Nothing unacceptable among the files we could see. A truncated delta
          # still leaves uncertainty, but only if some *authored* path is
          # unacceptable to begin with — otherwise the hidden overflow is all
          # base-merge noise and cannot mask an unacceptable authored change. So
          # we fail safe only when truncation could actually be hiding the
          # newness of an unacceptable authored path.
          nil ->
            if truncated? and filter_admits_unacceptable?(filter, restrict, deny) do
              {:revoke, :too_large}
            else
              :ok
            end
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

  # Can a truncated delta hide the newness of an unacceptable authored change?
  # With a complete authored file list it can only do so if some authored path
  # is unacceptable in the first place. With no filter (pr_diff truncated or
  # unavailable) we can't bound the authored set, so any truncated delta must
  # fail safe.
  defp filter_admits_unacceptable?(:no_filter, _restrict, _deny), do: true

  defp filter_admits_unacceptable?({:filter, set}, restrict, deny) do
    Enum.any?(set, fn path -> classify_path(path, restrict, deny) != nil end)
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
         # A truncated tree comes back as {:ok, {:truncated, _}}; match only a
         # path list so truncation falls through to the catch-all and skips the
         # lint rather than warning off an incomplete file set.
         {:ok, tree} when is_list(tree) <- GitHub.get_repo_tree(conn, patch.into_branch) do
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
