defmodule BorsNG.BundleDisplay do
  @moduledoc """
  Display ordering and state for bundles (`bors link` / `bors stack`) in
  the web UI. Pure functions over already-loaded `Patch` structs; no
  database or GitHub access.
  """

  alias BorsNG.Database.Patch
  alias BorsNG.Worker.Batcher.Bundles

  @doc """
  Whether any member is stacked on another. A stacked bundle displays in
  stack order; a plain linked one keeps the page's descending PR order.
  """
  def stacked?(members) do
    Enum.any?(members, &(not is_nil(&1.stacked_on_id)))
  end

  @doc """
  Members in display order: each stack base first, its stacked pull
  requests on the following lines, and everything unstacked in descending
  PR order. Members on a broken chain (a cycle, or a base that left the
  bundle) fall back to descending PR order at the end.
  """
  def display_order(members) do
    ids = MapSet.new(members, & &1.id)

    {roots, rest} =
      Enum.split_with(
        members,
        &(is_nil(&1.stacked_on_id) or not MapSet.member?(ids, &1.stacked_on_id))
      )

    by_base = Enum.group_by(rest, & &1.stacked_on_id)

    ordered =
      roots
      |> Enum.sort_by(& &1.pr_xref, :desc)
      |> Enum.flat_map(&chain(&1, by_base))

    ordered_ids = MapSet.new(ordered, & &1.id)

    leftover =
      members
      |> Enum.reject(&MapSet.member?(ordered_ids, &1.id))
      |> Enum.sort_by(& &1.pr_xref, :desc)

    ordered ++ leftover
  end

  defp chain(patch, by_base) do
    stacked =
      by_base
      |> Map.get(patch.id, [])
      |> Enum.sort_by(& &1.pr_xref, :desc)
      |> Enum.flat_map(&chain(&1, by_base))

    [patch | stacked]
  end

  @doc """
  The display state of a bundle that is not fully batched:

    * `{:blocked, patch}` — a member is closed or a draft
    * `{:waiting_on, patches}` — open members still needing `r+`
    * `:ready` — every member is approved
  """
  def state(members) do
    case Bundles.unapproved(members) do
      [] ->
        :ready

      unapproved ->
        case Enum.find(unapproved, &(&1.open == false or &1.is_draft)) do
          nil -> {:waiting_on, unapproved}
          blocker -> {:blocked, blocker}
        end
    end
  end

  @doc """
  Why a blocked member blocks: it is closed, or it is a draft.
  """
  def blocker_reason(%Patch{open: false}), do: "closed"
  def blocker_reason(%Patch{}), do: "a draft"

  @doc """
  A batch's patches in display order: descending PR order, except bundle
  members stay together (sorted by their highest member) with stacks base
  first.
  """
  def batch_display_order(patches) do
    {bundled, singles} = Enum.split_with(patches, & &1.bundle_id)

    bundle_groups =
      bundled
      |> Enum.group_by(& &1.bundle_id)
      |> Enum.map(fn {_id, members} ->
        {members |> Enum.map(& &1.pr_xref) |> Enum.max(), display_order(members)}
      end)

    single_groups = Enum.map(singles, &{&1.pr_xref, [&1]})

    (bundle_groups ++ single_groups)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.flat_map(&elem(&1, 1))
  end
end
