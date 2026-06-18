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

  # The batch states this patch is currently linked to. A patch can be linked to
  # several batches over its life (e.g. a failed batch plus a fresh re-queue), so
  # we look at all of them: "on the queue" is true if *any* is live.
  defp batch_states_for_patch(patch_id) do
    patch_id
    |> Batch.all_for_patch()
    |> Repo.all()
    |> Enum.map(& &1.state)
  end

  defp with_toml(repo_conn, branch, fun) do
    case GetBorsToml.get(repo_conn, branch) do
      {:ok, toml} -> fun.(toml)
      {:error, _} -> :ok
    end
  rescue
    e ->
      Logger.warning("Labeler: queue reconcile failed: #{Exception.message(e)}")
      :ok
  end

  defp with_conn_and_toml(%Patch{} = patch, fun) do
    project = Repo.get(Project, patch.project_id)

    if project do
      conn = Project.installation_connection(project.repo_xref, Repo)

      case GetBorsToml.get(conn, patch.into_branch) do
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
