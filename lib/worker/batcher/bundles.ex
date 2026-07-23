defmodule BorsNG.Worker.Batcher.Bundles do
  @moduledoc """
  Bundle membership and structure.

  A bundle is a group of linked patches that merge atomically. This module owns
  the bundle state kept on `Patch` rows: `bundle_id` (membership), `bundle_reviewer`
  (an approval held while the rest catches up), and `stacked_on_id` (member
  ordering). It answers structural questions: link validation, stack cycles,
  branch staleness, and merge order.

  It reads from GitHub but never writes to it, never posts comments or statuses,
  and never creates or mutates batches. That orchestration is in
  `BorsNG.Worker.Batcher`.
  """

  alias BorsNG.Database.Batch
  alias BorsNG.Database.Patch
  alias BorsNG.Database.PatchBundle
  alias BorsNG.Database.Repo
  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.Divider

  import Ecto.Query

  @doc """
  All members of a bundle, in PR-number order.
  """
  def members(bundle_id) do
    bundle_id
    |> Patch.all_for_bundle()
    |> Repo.all()
  end

  @doc """
  The whole bundle a patch belongs to, or just the patch itself when not bundled.
  Settings that apply bundle-wide (priority, `single`) fan out through this.
  """
  def members_or_self(%Patch{bundle_id: nil} = patch), do: [patch]
  def members_or_self(%Patch{bundle_id: bundle_id}), do: members(bundle_id)

  @doc """
  The members still awaiting approval. A closed or draft member counts: it
  cannot hold approval, and the bundle cannot queue until it is ready again
  or unlinked.
  """
  def unapproved(members) do
    Enum.filter(
      members,
      &(is_nil(&1.bundle_reviewer) or &1.open == false or &1.is_draft)
    )
  end

  @doc """
  Record a reviewer's approval on a bundled patch. The approval is held until
  the rest of the bundle is approved. Returns the updated patch.

  The held approval is not re-validated against delegation state when the
  bundle later queues: if the reviewer approved under a delegation that has
  since expired or been revoked, the approval still counts. That is deliberate
  — the fail-closed delegation gate already ran when the `r+` was issued, and
  a push to this patch drops the hold via the batcher's cancel path, so
  re-approval goes back through the gate. See DELEGATION_INVALIDATION.md,
  "standing approvals".

  Invariant: a draft cannot hold an approval. It is enforced only at the
  webhook boundary — every command entry point in `BorsNG.WebhookController`
  (issue_comment, review_comment, review, and the PR-opened body handler)
  drops commands on drafts before `Command.run/1`, and converting an approved
  patch to draft revokes what it held. There is no draft guard here or in
  `patch_preflight`, so a new command entry point must gate drafts itself.
  """
  def hold_approval(patch, reviewer) do
    patch
    |> Patch.changeset(%{bundle_reviewer: reviewer})
    |> Repo.update!()
  end

  @doc """
  Drop the approval held on this patch, if any. After an r-, close, or new
  push, re-queueing the bundle requires a fresh r+ on it.
  """
  def drop_held_approval(patch_id) do
    case Repo.get(Patch, patch_id) do
      %Patch{bundle_reviewer: reviewer} = patch when not is_nil(reviewer) ->
        patch |> Patch.changeset(%{bundle_reviewer: nil}) |> Repo.update!()

      _ ->
        :ok
    end
  end

  @doc """
  Drop the approvals held on these patches. After a failed build or merge,
  re-queueing needs a fresh r+ on every member.

  Leaves the retargeting record intact. A failed bundle still has members'
  bases moved, so a later unlink must restore them. The merged case forgets
  that record separately (`forget_retargeting/1`) because merged members'
  changes are already in the base and must not be "restored".
  """
  def drop_held_approvals(patches) do
    from(p in Patch,
      where: p.id in ^Enum.map(patches, & &1.id),
      where: not is_nil(p.bundle_reviewer)
    )
    |> Repo.update_all(set: [bundle_reviewer: nil])
  end

  @doc """
  Forget the base branch recorded when these patches were retargeted at queue
  time. Called once a bundle has merged. Members' changes are now in the base,
  so a later unlink must not "restore" the pre-merge base.
  """
  def forget_retargeting(patches) do
    from(p in Patch,
      where: p.id in ^Enum.map(patches, & &1.id),
      where: not is_nil(p.retargeted_from)
    )
    |> Repo.update_all(set: [retargeted_from: nil])
  end

  @doc """
  Check that a patch may be linked with the given PR numbers. Returns
  `{:ok, members}` with the full member list (existing bundles expanded), or
  `{:error, reason}` with a reason that `Message.generate_message/1` knows.
  """
  def validate_link(patch, pr_xrefs, project_id, mode \\ :link) do
    target_xrefs =
      pr_xrefs
      |> Enum.uniq()
      |> Enum.reject(&(&1 == patch.pr_xref))

    targets =
      Enum.map(target_xrefs, &Repo.get_by(Patch, project_id: project_id, pr_xref: &1))

    cond do
      target_xrefs == [] ->
        {:error, :nothing_to_link}

      Enum.any?(targets, &is_nil/1) ->
        {:error, :not_found}

      Enum.any?([patch | targets], &(&1.open == false)) ->
        {:error, :closed}

      Enum.any?([patch | targets], &merged_by_bors?/1) ->
        {:error, :already_merged}

      Enum.any?(targets, &branch_mismatch?(mode, patch, &1)) ->
        {:error, :branch_mismatch}

      true ->
        members = expand_bundles([patch | targets])

        if Enum.any?(members, &in_incomplete_batch?/1) do
          {:error, :in_batch}
        else
          {:ok, members}
        end
    end
  end

  # `link` requires a common target branch. `stack` also accepts a stacked
  # child whose base branch is the parent's head branch. These bases are
  # normalized to the final branch when the bundle is queued.
  defp branch_mismatch?(:link, patch, target) do
    target.into_branch != patch.into_branch
  end

  defp branch_mismatch?(:stack, patch, target) do
    target.into_branch != patch.into_branch and
      (is_nil(target.head_ref) or target.head_ref != patch.into_branch)
  end

  # Linking a patch that is already bundled links its whole bundle. The
  # member sets are unioned.
  defp expand_bundles(patches) do
    extra =
      patches
      |> Enum.map(& &1.bundle_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(&members/1)

    (patches ++ extra) |> Enum.uniq_by(& &1.id)
  end

  defp in_incomplete_batch?(patch) do
    batches =
      patch.id
      |> Batch.all_for_patch(:incomplete)
      |> Repo.all()

    batches != []
  end

  # Bors already merged this patch: it is in a batch that pushed to the base
  # branch. The pull request may still show as open for a moment (the close
  # is asynchronous, and can fail). Such a patch can never be approved again
  # — `Patch.all(:awaiting_review)` excludes it for good — so a bundle
  # containing it would wait forever.
  defp merged_by_bors?(patch) do
    batches =
      patch.id
      |> Batch.all_for_patch()
      |> where([b], b.state == ^:ok)
      |> Repo.all()

    batches != []
  end

  @doc """
  Put all members on one bundle, creating it if needed, and delete any bundles
  emptied by the union. Runs in a transaction: the bundle forms completely or
  not at all. Returns the updated members.
  """
  def form(members, project_id) do
    {:ok, members} =
      Repo.transaction(fn ->
        old_bundle_ids =
          members |> Enum.map(& &1.bundle_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

        bundle_id =
          case old_bundle_ids do
            [] -> Repo.insert!(PatchBundle.new(project_id)).id
            [first | _] -> first
          end

        members =
          Enum.map(members, fn p ->
            if p.bundle_id == bundle_id do
              p
            else
              p |> Patch.changeset(%{bundle_id: bundle_id}) |> Repo.update!()
            end
          end)

        emptied = old_bundle_ids -- [bundle_id]

        if emptied != [] do
          PatchBundle
          |> where([b], b.id in ^emptied)
          |> Repo.delete_all()
        end

        members
      end)

    members
  end

  @doc """
  Bundle members together and record that the child merges after the parent.
  This is like `form/2` plus a stack edge. Returns the updated members.
  """
  def form_stacked(members, child, parent, project_id) do
    {:ok, members} =
      Repo.transaction(fn ->
        members = form(members, project_id)

        child =
          members
          |> Enum.find(&(&1.id == child.id))
          |> Patch.changeset(%{stacked_on_id: parent.id})
          |> Repo.update!()

        Enum.map(members, &if(&1.id == child.id, do: child, else: &1))
      end)

    members
  end

  @doc """
  Dissolve a bundle: clear every member's bundle state and delete the bundle
  row. Refused while any member is queued or running. Runs in a transaction,
  like `form/2`: the bundle dissolves completely or not at all. Returns
  `{:ok, members}` or `{:error, :in_batch}`.
  """
  def dissolve(bundle_id) do
    members = members(bundle_id)

    if Enum.any?(members, &in_incomplete_batch?/1) do
      {:error, :in_batch}
    else
      {:ok, members} =
        Repo.transaction(fn ->
          members =
            Enum.map(members, fn p ->
              p
              |> Patch.changeset(%{
                bundle_id: nil,
                bundle_reviewer: nil,
                stacked_on_id: nil,
                retargeted_from: nil
              })
              |> Repo.update!()
            end)

          Repo.delete!(Repo.get!(PatchBundle, bundle_id))
          members
        end)

      {:ok, members}
    end
  end

  @doc """
  The single open patch whose head branch is this patch's base branch. That
  is, the parent this patch is stacked on. Returns `:error` if there are zero
  or multiple candidates; the user must name the parent.
  """
  def infer_stack_parent(%Patch{into_branch: nil}, _project_id), do: :error

  def infer_stack_parent(patch, project_id) do
    Patch
    |> where([p], p.project_id == ^project_id)
    |> where([p], p.open)
    |> where([p], p.head_ref == ^patch.into_branch)
    |> where([p], p.id != ^patch.id)
    |> limit(2)
    |> Repo.all()
    |> case do
      [parent] -> {:ok, parent}
      _ -> :error
    end
  end

  @doc """
  Returns true if stacking `patch` on `target` would create a cycle (i.e.,
  `patch` already appears in `target`'s stacked-on ancestor chain).
  """
  def creates_stack_cycle?(target, patch) do
    walk_stack_chain(target, MapSet.new(), patch.id)
  end

  defp walk_stack_chain(nil, _seen, _goal), do: false
  defp walk_stack_chain(%Patch{id: goal}, _seen, goal), do: true

  defp walk_stack_chain(%Patch{} = p, seen, goal) do
    cond do
      # A cycle already stored (unexpected): refuse rather than loop.
      p.id in seen -> true
      is_nil(p.stacked_on_id) -> false
      true -> walk_stack_chain(Repo.get(Patch, p.stacked_on_id), MapSet.put(seen, p.id), goal)
    end
  end

  @doc """
  Returns true if the child's branch contains the current head of the parent's
  branch (i.e., is rebased on it). An unanswerable comparison counts as `false`:
  callers fail closed.
  """
  def contains_head?(repo_conn, parent, child) do
    case GitHub.compare_status(repo_conn, parent.commit, child.commit) do
      {:ok, status} when status in [:ahead, :identical] -> true
      _ -> false
    end
  end

  @doc """
  The first stacked member whose branch does not contain the current head of
  the patch it stacks on, returned as `{child, parent}`. Returns nil if every
  stack edge is fresh. An unverifiable comparison counts as stale: this check
  fails closed because merging a stale stack can silently reintroduce content
  its parent has dropped.
  """
  def stale_stack_pair(repo_conn, members) do
    by_id = Map.new(members, &{&1.id, &1})

    Enum.find_value(members, fn child ->
      parent = child.stacked_on_id && by_id[child.stacked_on_id]

      if parent != nil and not contains_head?(repo_conn, parent, child) do
        {child, parent}
      end
    end)
  end

  @doc """
  The branch a bundle ultimately merges into: the `into_branch` of its stack
  roots (members not stacked on another member). These must agree. Returns
  `{:ok, branch}` or `{:error, :branch_mismatch}`.
  """
  def final_target(members) do
    member_ids = MapSet.new(members, & &1.id)

    roots =
      Enum.filter(members, fn p ->
        is_nil(p.stacked_on_id) or p.stacked_on_id not in member_ids
      end)

    case roots |> Enum.map(& &1.into_branch) |> Enum.uniq() do
      [final] -> {:ok, final}
      _ -> {:error, :branch_mismatch}
    end
  end

  @doc """
  Order patches for merging. A patch stacked on another comes after it. PR
  number order applies otherwise. A stacked-on patch not in the list is
  ignored (its dependents count as roots).
  """
  def stack_order(patches) do
    sorted = Enum.sort_by(patches, & &1.pr_xref)
    present = MapSet.new(sorted, & &1.id)
    do_stack_order(sorted, present, MapSet.new(), [])
  end

  defp do_stack_order([], _present, _placed, acc), do: acc

  defp do_stack_order(remaining, present, placed, acc) do
    {ready, blocked} =
      Enum.split_with(remaining, fn p ->
        is_nil(p.stacked_on_id) or p.stacked_on_id in placed or
          p.stacked_on_id not in present
      end)

    case ready do
      [] ->
        # Defensive: a cycle in the stored edges. Fall back to PR number order
        # rather than dropping patches or looping.
        acc ++ remaining

      _ ->
        do_stack_order(
          blocked,
          present,
          Enum.into(ready, placed, & &1.id),
          acc ++ ready
        )
    end
  end

  @doc """
  Merge order for a batch's patch links. Bundles stay contiguous (units
  ordered by their lowest PR number). Members within a bundle merge in stack
  order. Everything else merges by PR number. A stacked pair lands as two
  adjacent commits with the parent first.
  """
  def sort_links_for_merge(patch_links) do
    patch_links
    |> Enum.sort_by(& &1.patch.pr_xref)
    |> Divider.group_units()
    |> Enum.flat_map(fn unit ->
      by_patch_id = Map.new(unit, &{&1.patch_id, &1})

      unit
      |> Enum.map(& &1.patch)
      |> stack_order()
      |> Enum.map(&Map.fetch!(by_patch_id, &1.id))
    end)
  end

  @doc """
  The ids of every patch that must leave a batch when `patch_id` does. This
  is just the patch itself or all of its bundle's members present in the
  batch's links.
  """
  def member_ids(patch_links, patch_id) do
    target = Enum.find(patch_links, &(&1.patch_id == patch_id))

    case target && target.patch.bundle_id do
      nil ->
        [patch_id]

      bundle_id ->
        patch_links
        |> Enum.filter(&(&1.patch.bundle_id == bundle_id))
        |> Enum.map(& &1.patch_id)
    end
  end

  @doc """
  Split `patch_links` into those pulled out because a closed patch shares
  their bundle (a closed patch takes its whole bundle) and the rest. Returns
  `{pulled, remaining}`.
  """
  def split_pulled_by_closed(closed_links, patch_links) do
    closed_bundles =
      closed_links
      |> Enum.map(& &1.patch.bundle_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.split_with(patch_links, &(&1.patch.bundle_id in closed_bundles))
  end
end
