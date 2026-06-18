defmodule BorsNG.Worker.Labeler do
  @moduledoc """
  Projects bors's own state onto GitHub PR labels.

  Label management is opt-in per project via the `[labels]` table in
  `bors.toml` (parsed onto `BorsNG.Worker.Batcher.BorsToml`). When a label name
  is unset, the corresponding concern is unmanaged and every call here is a
  no-op, so projects that don't configure `[labels]` see no behavior change.

  Labels are **best-effort projections**: a failed GitHub call is logged and
  dropped, never raised, so it can't crash a batcher cast or the delegation
  sweep. The state-derived labels (`delegated`, `on_queue`, `building`) are
  reconciled toward the database, so a missed update self-corrects the next time
  the relevant event fires. `awaiting-requeue` (the `failed` label) cannot be
  derived from current state — a dropped PR looks just like one that was never
  approved — so it is set and cleared by event instead.

  See LIFECYCLE_LABELS.md for the full design.
  """

  use BorsNG.Database.Context

  alias BorsNG.Database.Context.Permission
  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.GetBorsToml

  require Logger

  @doc """
  Reconcile a single managed label on a PR to `present?`.

  `label` is the configured label name, or `nil` when the concern is unmanaged
  (a no-op). Idempotent and best-effort: adding a present label or removing an
  absent one is harmless, and any API error is logged and swallowed.
  """
  @spec reconcile(term, term, binary | nil, boolean) :: :ok
  def reconcile(_conn, _pr_xref, nil, _present?), do: :ok

  def reconcile(conn, pr_xref, label, true) when is_binary(label) do
    case GitHub.add_labels(conn, pr_xref, [label]) do
      :ok -> :ok
      err -> warn("add", label, pr_xref, err)
    end
  end

  def reconcile(conn, pr_xref, label, false) when is_binary(label) do
    case GitHub.remove_label(conn, pr_xref, label) do
      :ok -> :ok
      err -> warn("remove", label, pr_xref, err)
    end
  end

  @doc """
  Reconcile the `delegated` label for `patch` against whether it currently has
  any active (non-expired) delegation. Use this arity when the caller already
  holds the repo connection and parsed `bors.toml`.
  """
  def reconcile_delegated(_conn, nil, %Patch{}), do: :ok

  def reconcile_delegated(conn, toml, %Patch{} = patch) do
    present? = Permission.patch_has_active_delegation?(patch.id)
    reconcile(conn, patch.pr_xref, toml.label_delegated, present?)
  end

  @doc """
  Reconcile the `delegated` label for `patch`, loading the repo connection and
  `bors.toml` itself. Use this from sites that don't already hold them (e.g. the
  delegation sweep). A missing project or unreadable `bors.toml` is a no-op.
  """
  def reconcile_delegated(%Patch{} = patch) do
    with_conn_and_toml(patch, fn conn, toml ->
      reconcile_delegated(conn, toml, patch)
    end)
  end

  @doc """
  Reconcile the queue labels (`on_queue`, `building`) for `patches`, reading
  `bors.toml` once from `branch`. A patch is "on the queue" if it is linked to a
  batch in `:waiting` or `:running`, and "building" if any such batch is
  `:running`. Both are pure functions of current state, so this is safe to call
  at any transition and is self-correcting.

  When a patch is back on the queue, the event-driven `awaiting-requeue` label is
  cleared in the same pass — being queued again is exactly the signal that it no
  longer needs a maintainer to re-queue it.
  """
  def reconcile_queue(_repo_conn, _branch, []), do: :ok

  def reconcile_queue(repo_conn, branch, patches) when is_list(patches) do
    with_toml(repo_conn, branch, fn toml ->
      Enum.each(patches, fn patch ->
        states = batch_states_for_patch(patch.id)
        on_queue? = Enum.any?(states, &(&1 in [:waiting, :running]))
        building? = :running in states

        reconcile(repo_conn, patch.pr_xref, toml.label_on_queue, on_queue?)
        reconcile(repo_conn, patch.pr_xref, toml.label_building, building?)
        if on_queue?, do: reconcile(repo_conn, patch.pr_xref, toml.label_failed, false)
      end)
    end)
  end

  @doc """
  Set the event-driven `awaiting-requeue` (`failed`) label on `patches` — PRs
  that were approved but whose build failed terminally and were dropped from the
  queue. Reads `bors.toml` once from `branch`. The label is cleared later by
  `reconcile_queue/3` when the PR is put back on the queue.
  """
  def mark_awaiting_requeue(_repo_conn, _branch, []), do: :ok

  def mark_awaiting_requeue(repo_conn, branch, patches) when is_list(patches) do
    with_toml(repo_conn, branch, fn toml ->
      Enum.each(patches, fn patch ->
        reconcile(repo_conn, patch.pr_xref, toml.label_failed, true)
      end)
    end)
  end

  @doc """
  Backstop reconcile of the state-derived lifecycle labels (`on_queue`,
  `building`, `delegated`) across every project with open patches.

  This is the self-healing pass for drift the per-event reconciles can't catch:
  a best-effort label write that was dropped at event time, a restart
  mid-transition, or a human manually editing a managed label. It runs off the
  live path, on `BorsNG.Worker.LabelBackstopTimer`.

  Coverage is deliberately bounded:

    * **Open PRs only.** A merged PR's labels are frozen as history
      (LIFECYCLE_LABELS.md): the discovery query asks for `state=open`, and the
      sweep only ever touches patches whose `patch.open` is true.
    * **State-derived labels, plus a one-way `awaiting-requeue` clear.** The
      three state-derived labels are reconciled in both directions. The
      event-driven `failed`/`awaiting-requeue` label has no current-state
      definition, so it is never *added* here and is *removed* only when the PR
      is back on the queue (mirroring the live `reconcile_queue/3`); a stale
      `awaiting-requeue` off the queue is undecidable, so it is left alone.
    * **Each PR under its own base branch's config.** A label is reconciled only
      if the PR's *current* `into_branch` config manages that name — preserving
      the "never touch foreign labels" guarantee and the documented
      divergent-name retarget limitation.

  The sweep is diff-based. It discovers candidate PRs with
  `GitHub.list_issues_by_label/2`, whose response already carries each PR's full
  label set, so a tick with no drift performs zero writes. A second pass closes
  the one gap discovery-by-label can't see — a PR that should carry a label but
  has lost *all* its managed labels (so appears in no listing) — by adding the
  missing label to the (small) set of patches the DB says should be labeled.

  Config reads go through the short-TTL cache, and a per-project failure is
  logged and skipped so one bad installation can't abort the whole sweep.
  """
  @spec backstop_sweep() :: :ok
  def backstop_sweep do
    Repo.all(from(p in Patch, where: p.open, distinct: true, select: p.project_id))
    |> Enum.each(&backstop_project/1)
  end

  defp backstop_project(project_id) do
    project = Repo.get(Project, project_id)

    if project do
      conn = Project.installation_connection(project.repo_xref, Repo)
      tomls = open_branch_tomls(conn, project_id)

      case managed_state_names(tomls) do
        [] ->
          :ok

        managed ->
          seen = discover(conn, managed)
          writes = reconcile_seen(conn, project_id, tomls, seen, 0)
          reconcile_add_gap(conn, project_id, tomls, seen, writes)
          :ok
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.warning(
        "Labeler: backstop sweep failed for project ##{project_id}: #{Exception.message(e)}"
      )

      :ok
  end

  # Read (cached) the bors.toml for every base branch that has an open patch in
  # this project, returning %{branch => {:ok, toml} | {:error, _}}. A patch's
  # into_branch is always among these keys, so per-patch lookups never miss.
  defp open_branch_tomls(conn, project_id) do
    Repo.all(
      from(p in Patch,
        where: p.open and p.project_id == ^project_id,
        distinct: true,
        select: p.into_branch
      )
    )
    |> Map.new(fn branch -> {branch, GetBorsToml.get_cached(conn, branch)} end)
  end

  # The distinct configured names for the three state-derived concerns, across
  # all of the project's base branches. `failed` is intentionally excluded — it
  # is event-driven and not reconciled by this sweep.
  defp managed_state_names(tomls) do
    tomls
    |> Map.values()
    |> Enum.flat_map(fn
      {:ok, toml} -> [toml.label_on_queue, toml.label_building, toml.label_delegated]
      {:error, _} -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Discover PRs carrying any managed name. Returns %{pr_xref => current label
  # names}; the listing embeds each PR's full label set, so whichever name
  # surfaces a PR, we get its complete current labels for the diff.
  defp discover(conn, managed) do
    Enum.reduce(managed, %{}, fn name, acc ->
      case GitHub.list_issues_by_label(conn, name) do
        {:ok, issues} ->
          Enum.reduce(issues, acc, fn {number, names}, acc -> Map.put(acc, number, names) end)

        _ ->
          acc
      end
    end)
  end

  # Pass A: for every discovered PR that maps to an open patch in this project,
  # diff its current labels against bors's state and write only the difference.
  defp reconcile_seen(_conn, _project_id, _tomls, seen, writes) when map_size(seen) == 0 do
    writes
  end

  defp reconcile_seen(conn, project_id, tomls, seen, writes) do
    xrefs = Map.keys(seen)

    Repo.all(
      from(p in Patch,
        where: p.open and p.project_id == ^project_id and p.pr_xref in ^xrefs
      )
    )
    |> Enum.reduce(writes, fn patch, writes ->
      case tomls[patch.into_branch] do
        {:ok, toml} -> apply_diff(conn, toml, patch, Map.get(seen, patch.pr_xref, []), writes)
        _ -> writes
      end
    end)
  end

  # Pass B: the missing-add backstop. Patches the DB says should carry a label
  # but that appeared in no listing have lost *all* their managed labels; add
  # what they're due. Patches that appeared in a listing are already handled by
  # pass A (it adds any managed label they're individually missing), so they are
  # filtered out here. In steady state this set is empty and writes nothing.
  defp reconcile_add_gap(conn, project_id, tomls, seen, writes) do
    project_id
    |> desired_patches()
    |> Enum.reject(fn patch -> Map.has_key?(seen, patch.pr_xref) end)
    |> Enum.reduce(writes, fn patch, writes ->
      case tomls[patch.into_branch] do
        {:ok, toml} -> apply_diff(conn, toml, patch, [], writes)
        _ -> writes
      end
    end)
  end

  # Open patches this project should label: any with an active delegation, plus
  # any linked to a waiting/running batch. Small (the queued + delegated sets),
  # so scanning it every sweep is cheap.
  defp desired_patches(project_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    delegated =
      Repo.all(
        from(p in Patch,
          join: d in UserPatchDelegation,
          on: d.patch_id == p.id,
          where:
            p.open and p.project_id == ^project_id and
              (is_nil(d.expires_at) or d.expires_at > ^now),
          distinct: true
        )
      )

    queued =
      Repo.all(
        from(p in Patch,
          join: l in LinkPatchBatch,
          on: l.patch_id == p.id,
          join: b in Batch,
          on: b.id == l.batch_id,
          where:
            p.open and p.project_id == ^project_id and
              (b.state == ^:waiting or b.state == ^:running),
          distinct: true
        )
      )

    Enum.uniq_by(delegated ++ queued, & &1.id)
  end

  # Compute and apply the label diff for one patch, returning the running count
  # of PRs written (so writes can be paced without sleeping for the no-op
  # majority). `current` is the PR's present label names (empty for pass B).
  defp apply_diff(conn, toml, patch, current, writes) do
    {to_add, to_remove} = compute_diff(toml, patch, current)

    if to_add == [] and to_remove == [] do
      writes
    else
      pace_write(writes)

      case GitHub.add_labels(conn, patch.pr_xref, to_add) do
        :ok -> :ok
        err -> warn("add", to_add, patch.pr_xref, err)
      end

      Enum.each(to_remove, &reconcile(conn, patch.pr_xref, &1, false))
      writes + 1
    end
  end

  # The {to_add, to_remove} diff for the labels this branch manages, given the
  # PR's current label names. Unmanaged concerns (nil name) are skipped, so
  # foreign labels are never touched.
  defp compute_diff(toml, patch, current) do
    states = batch_states_for_patch(patch.id)
    on_queue? = Enum.any?(states, &(&1 in [:waiting, :running]))

    concerns = [
      {toml.label_delegated, Permission.patch_has_active_delegation?(patch.id)},
      {toml.label_on_queue, on_queue?},
      {toml.label_building, :running in states}
    ]

    {add, remove} =
      Enum.reduce(concerns, {[], []}, fn
        {nil, _present?}, acc ->
          acc

        {label, present?}, {add, remove} ->
          has? = label in current

          cond do
            present? and not has? -> {[label | add], remove}
            not present? and has? -> {add, [label | remove]}
            true -> {add, remove}
          end
      end)

    {add, maybe_clear_failed(toml, on_queue?, current, remove)}
  end

  # `awaiting-requeue` (the `failed` label) is asymmetric: the sweep can never
  # *add* it (its set-condition isn't derivable from current state — a dropped PR
  # looks like one never approved), and it can only safely *clear* it in one
  # direction — when the PR is back on the queue, mirroring the live
  # `reconcile_queue/3`. A PR carrying it while *not* queued is left alone:
  # current state can't tell a genuine awaiting-requeue from a missed `r-`/close
  # clear. So this only ever removes, and only when on the queue.
  defp maybe_clear_failed(toml, on_queue?, current, remove) do
    if not is_nil(toml.label_failed) and on_queue? and toml.label_failed in current do
      [toml.label_failed | remove]
    else
      remove
    end
  end

  # The batch states this patch is currently linked to. A patch can be linked to
  # several batches over its life (e.g. a failed batch plus a fresh re-queue), so
  # we look at all of them: "on the queue" is true if *any* is live.
  defp batch_states_for_patch(patch_id) do
    patch_id
    |> Batch.all_for_patch()
    |> Repo.all()
    |> Enum.map(& &1.state)
  end

  @doc """
  Throttle a sequence of label writes so a burst — a sweep, or many delegations
  expiring in one tick — doesn't trip GitHub's secondary rate limit for
  mutations. Indexed like the delegation sweep's comment pacing (the first write
  is free), but much lighter: a label write is a cheap, idempotent best-effort
  projection, so it doesn't deserve the ~750ms content-creation budget that
  comments use. A no-op in the test environment.
  """
  @spec pace_write(non_neg_integer) :: :ok
  def pace_write(0), do: :ok

  def pace_write(_idx) do
    unless Application.get_env(:bors, :is_test, false) do
      Process.sleep(Confex.get_env(:bors, :label_write_pace_ms, 250))
    end

    :ok
  end

  # Reconcile paths read config through the short-TTL cache (GetBorsToml.Cache),
  # not get/2: a slightly stale label config only affects a best-effort label,
  # never a merge decision, and the cache collapses the repeated base-branch
  # reads the sweep and backstop would otherwise make.
  defp with_toml(repo_conn, branch, fun) do
    case GetBorsToml.get_cached(repo_conn, branch) do
      {:ok, toml} -> fun.(toml)
      {:error, _} -> :ok
    end
  rescue
    e ->
      Logger.warning("Labeler: queue reconcile failed: #{Exception.message(e)}")
      :ok
  end

  defp with_conn_and_toml(%Patch{} = patch, fun) do
    # Use the project already preloaded by the caller (the delegation sweep
    # preloads `patch: :project`); only hit the DB when it isn't loaded.
    project =
      case patch.project do
        %Project{} = project -> project
        _ -> Repo.get(Project, patch.project_id)
      end

    if project do
      conn = Project.installation_connection(project.repo_xref, Repo)

      case GetBorsToml.get_cached(conn, patch.into_branch) do
        {:ok, toml} -> fun.(conn, toml)
        {:error, _} -> :ok
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("Labeler: reconcile failed for patch ##{patch.id}: #{Exception.message(e)}")

      :ok
  end

  defp warn(op, label, pr_xref, err) do
    Logger.warning(
      "Labeler: failed to #{op} label #{inspect(label)} on PR ##{pr_xref}: #{inspect(err)}"
    )

    :ok
  end
end
