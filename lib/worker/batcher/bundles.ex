defmodule BorsNG.Worker.Batcher.Bundles do
  @moduledoc """
  Bundle membership and structure.

  A bundle is a group of linked patches that merge atomically (see
  `BorsNG.Database.PatchBundle`). This module owns the bundle state kept on
  `Patch` rows — `bundle_id` (membership), `bundle_reviewer` (an approval
  held while the rest of the bundle catches up), and `stacked_on_id`
  (ordering between members) — and answers the structure questions over it:
  link validation, stack cycles, staleness of stacked branches, and merge
  order.

  It reads from GitHub (branch comparisons) but never writes to it, never
  posts comments or statuses, and never creates or mutates batches; that
  orchestration lives in `BorsNG.Worker.Batcher`.
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
  The whole bundle a patch belongs to, or just the patch itself when it is
  not bundled. Settings that only make sense bundle-wide (priority,
  `single`) fan out through this.
  """
  def members_or_self(%Patch{bundle_id: nil} = patch), do: [patch]
  def members_or_self(%Patch{bundle_id: bundle_id}), do: members(bundle_id)

  @doc """
  The members whose approval the bundle is still waiting on. A closed
  member counts: it cannot hold an approval, and the bundle cannot queue
  until it is reopened or unlinked.
  """
  def unapproved(members) do
    Enum.filter(members, &(is_nil(&1.bundle_reviewer) or &1.open == false))
  end

  @doc """
  Record `reviewer`'s approval on a bundled patch, held until the rest of
  the bundle is approved. Returns the updated patch.
  """
  def hold_approval(patch, reviewer) do
    patch
    |> Patch.changeset(%{bundle_reviewer: reviewer})
    |> Repo.update!()
  end

  @doc """
  Drop the approval held on this patch, if any: after an r-, a close, or a
  new push, re-queueing the bundle needs a fresh r+ on it.
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
  Drop the approvals held on these patches, e.g. once their bundle has
  merged: a future run of the same bundle needs fresh r+'s.
  """
  def drop_held_approvals(patches) do
    from(p in Patch,
      where: p.id in ^Enum.map(patches, & &1.id),
      where: not is_nil(p.bundle_reviewer)
    )
    |> Repo.update_all(set: [bundle_reviewer: nil])
  end

  @doc """
  Check that `patch` may be linked with the given PR numbers. Returns
  `{:ok, members}` with the full member list (existing bundles expanded),
  or `{:error, reason}` with a reason `Message.generate_message/1` knows.
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

  # `link` requires a common target branch. `stack` also accepts the
  # gh-stack shape, where the child's base branch is the parent's head
  # branch; such bases are normalized onto the final branch when the
  # bundle is queued (Batcher.normalize_bundle_bases/2).
  defp branch_mismatch?(:link, patch, target) do
    target.into_branch != patch.into_branch
  end

  defp branch_mismatch?(:stack, patch, target) do
    target.into_branch != patch.into_branch and
      (is_nil(target.head_ref) or target.head_ref != patch.into_branch)
  end

  # Linking a patch that is already bundled links its whole bundle: the
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

  @doc """
  Put every member on one bundle (creating it if none exists), and delete
  any bundles emptied by the union. Returns the updated members.
  """
  def form(members, project_id) do
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
  end

  @doc """
  Bundle `members` together and record that `child` merges after `parent`,
  as `form/2` plus a stack edge. Returns the updated members.
  """
  def form_stacked(members, child, parent, project_id) do
    members = form(members, project_id)

    child =
      members
      |> Enum.find(&(&1.id == child.id))
      |> Patch.changeset(%{stacked_on_id: parent.id})
      |> Repo.update!()

    Enum.map(members, &if(&1.id == child.id, do: child, else: &1))
  end

  @doc """
  Dissolve a bundle: clear every member's bundle state and delete the
  bundle row. Refused while any member is queued or running. Returns
  `{:ok, members}` or `{:error, :in_batch}`.
  """
  def dissolve(bundle_id) do
    members = members(bundle_id)

    if Enum.any?(members, &in_incomplete_batch?/1) do
      {:error, :in_batch}
    else
      members =
        Enum.map(members, fn p ->
          p
          |> Patch.changeset(%{bundle_id: nil, bundle_reviewer: nil, stacked_on_id: nil})
          |> Repo.update!()
        end)

      Repo.delete!(Repo.get!(PatchBundle, bundle_id))
      {:ok, members}
    end
  end

  @doc """
  The single open patch whose head branch is this patch's base branch (the
  gh-stack convention). Zero or several candidates -> `:error`; the user
  must name the parent.
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
  Stacking `patch` on `target` is a cycle iff `patch` already appears in
  `target`'s chain of stacked-on ancestors.
  """
  def creates_stack_cycle?(target, patch) do
    walk_stack_chain(target, MapSet.new(), patch.id)
  end

  defp walk_stack_chain(nil, _seen, _goal), do: false
  defp walk_stack_chain(%Patch{id: goal}, _seen, goal), do: true

  defp walk_stack_chain(%Patch{} = p, seen, goal) do
    cond do
      # A cycle already stored (shouldn't happen): refuse rather than loop.
      p.id in seen -> true
      is_nil(p.stacked_on_id) -> false
      true -> walk_stack_chain(Repo.get(Patch, p.stacked_on_id), MapSet.put(seen, p.id), goal)
    end
  end

  @doc """
  Whether `child`'s branch contains the current head of `parent`'s, i.e.
  is rebased on it. A comparison GitHub cannot answer counts as `false`:
  callers fail closed.
  """
  def contains_head?(repo_conn, parent, child) do
    case GitHub.compare_status(repo_conn, parent.commit, child.commit) do
      {:ok, status} when status in [:ahead, :identical] -> true
      _ -> false
    end
  end

  @doc """
  The first stacked member whose branch does not contain the current head
  of the patch it stacks on, as `{child, parent}`, or nil if every stack
  edge is fresh. An unverifiable comparison (GitHub error) counts as
  stale: this check fails closed, because merging a stale stack can
  silently reintroduce content its parent has since dropped.
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
  The branch a bundle ultimately merges into: the `into_branch` of its
  stack roots (members not stacked on another member), which must agree.
  Returns `{:ok, branch}` or `{:error, :branch_mismatch}`.
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
  Order patches for merging: a patch stacked on another (`stacked_on_id`)
  comes after it, and PR-number order applies otherwise. A stacked-on patch
  that isn't in the list is ignored (its dependents count as roots).
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
        # Defensive: a cycle in the stored edges. Fall back to PR-number
        # order rather than dropping patches or looping.
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
  Merge order for a batch's patch links: bundles stay contiguous (units
  ordered by their lowest PR number), members within a bundle in stack
  order, everything else by PR number. A stacked pair therefore lands as
  two adjacent commits, parent first.
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
  The ids of every patch that must leave a batch when `patch_id` does:
  just the patch itself, or all of its bundle's members present in the
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
  Split `patch_links` into those pulled out of the batch because a closed
  patch's link shares their bundle — a closed patch takes its whole bundle
  with it — and the rest. Returns `{pulled, remaining}`.
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
