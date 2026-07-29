defmodule BorsNG.BundleDisplayTest do
  use ExUnit.Case, async: true

  alias BorsNG.BundleDisplay
  alias BorsNG.Database.Patch

  defp patch(id, xref, opts \\ []) do
    %Patch{
      id: id,
      pr_xref: xref,
      bundle_id: Keyword.get(opts, :bundle_id, 1),
      stacked_on_id: Keyword.get(opts, :stacked_on),
      bundle_reviewer: Keyword.get(opts, :reviewer),
      open: Keyword.get(opts, :open, true),
      is_draft: Keyword.get(opts, :draft, false)
    }
  end

  describe "stacked?/1" do
    test "true when any member is stacked" do
      assert BundleDisplay.stacked?([patch(1, 10), patch(2, 11, stacked_on: 1)])
    end

    test "false for a plain linked bundle" do
      refute BundleDisplay.stacked?([patch(1, 10), patch(2, 11)])
    end
  end

  describe "display_order/1" do
    test "a plain linked bundle keeps descending PR order" do
      members = [patch(1, 10), patch(2, 12), patch(3, 11)]

      assert [12, 11, 10] =
               members |> BundleDisplay.display_order() |> Enum.map(& &1.pr_xref)
    end

    test "a stacked bundle lists the base first, then each stacked PR" do
      base = patch(1, 10)
      mid = patch(2, 11, stacked_on: 1)
      top = patch(3, 12, stacked_on: 2)

      assert [10, 11, 12] =
               [top, base, mid]
               |> BundleDisplay.display_order()
               |> Enum.map(& &1.pr_xref)
    end

    test "members whose base left the bundle become roots" do
      # 99 is not a member; 11 starts its own chain
      members = [patch(2, 11, stacked_on: 99), patch(3, 12, stacked_on: 2)]

      assert [11, 12] =
               members |> BundleDisplay.display_order() |> Enum.map(& &1.pr_xref)
    end

    test "a cycle falls back to descending PR order" do
      members = [patch(1, 10, stacked_on: 2), patch(2, 11, stacked_on: 1)]

      assert [11, 10] =
               members |> BundleDisplay.display_order() |> Enum.map(& &1.pr_xref)
    end

    test "fan-out: a base with two children lists the base, then children descending" do
      base = patch(1, 10)
      child_low = patch(2, 11, stacked_on: 1)
      child_high = patch(3, 12, stacked_on: 1)

      assert [10, 12, 11] =
               [child_low, base, child_high]
               |> BundleDisplay.display_order()
               |> Enum.map(& &1.pr_xref)
    end

    test "forest: each root heads its own chain (depth-first), roots descending" do
      r_low = patch(1, 10)
      r_high = patch(2, 20)
      c_low = patch(3, 11, stacked_on: 1)
      c_high = patch(4, 21, stacked_on: 2)

      assert [20, 21, 10, 11] =
               [c_low, r_low, c_high, r_high]
               |> BundleDisplay.display_order()
               |> Enum.map(& &1.pr_xref)
    end
  end

  describe "display_rows/1" do
    test "roots are depth 0, each stacked PR one deeper" do
      base = patch(1, 10)
      mid = patch(2, 11, stacked_on: 1)
      top = patch(3, 12, stacked_on: 2)

      assert [{10, 0}, {11, 1}, {12, 2}] =
               [top, base, mid]
               |> BundleDisplay.display_rows()
               |> Enum.map(fn {p, depth} -> {p.pr_xref, depth} end)
    end

    test "a plain linked bundle is all depth 0" do
      members = [patch(1, 10), patch(2, 12), patch(3, 11)]

      assert [{12, 0}, {11, 0}, {10, 0}] =
               members
               |> BundleDisplay.display_rows()
               |> Enum.map(fn {p, depth} -> {p.pr_xref, depth} end)
    end

    test "siblings on a branching base share a depth, base leads" do
      base = patch(1, 10)
      left = patch(2, 11, stacked_on: 1)
      right = patch(3, 12, stacked_on: 1)

      rows =
        [base, left, right]
        |> BundleDisplay.display_rows()
        |> Enum.map(fn {p, depth} -> {p.pr_xref, depth} end)

      assert hd(rows) == {10, 0}
      assert {11, 1} in rows
      assert {12, 1} in rows
    end
  end

  describe "depths/1" do
    test "depth per patch id; singles and roots at 0" do
      base = patch(1, 10, bundle_id: 7)
      top = patch(2, 11, bundle_id: 7, stacked_on: 1)
      lone = patch(3, 12, bundle_id: nil)

      # keyed by patch id (base id 1, top id 2, lone id 3), as the templates look it up
      depths = BundleDisplay.depths([lone, top, base])

      assert depths[1] == 0
      assert depths[2] == 1
      assert depths[3] == 0
    end
  end

  describe "member_status/1" do
    test "held when an approval is held" do
      assert BundleDisplay.member_status(patch(1, 10, reviewer: "r")) == :held
    end

    test "waiting with no approval" do
      assert BundleDisplay.member_status(patch(1, 10)) == :waiting
    end

    test "blocked when closed or a draft, even holding an approval" do
      assert BundleDisplay.member_status(patch(1, 10, draft: true)) == :blocked
      assert BundleDisplay.member_status(patch(1, 10, reviewer: "r", open: false)) == :blocked
    end
  end

  describe "state/1" do
    test "waiting on the members without a held approval" do
      held = patch(1, 10, reviewer: "reviewer")
      pending = patch(2, 11)

      assert {:waiting_on, [%Patch{pr_xref: 11}]} = BundleDisplay.state([held, pending])
    end

    test "blocked by a draft member" do
      held = patch(1, 10, reviewer: "reviewer")
      draft = patch(2, 11, draft: true)

      assert {:blocked, %Patch{pr_xref: 11}} = BundleDisplay.state([held, draft])
      assert BundleDisplay.blocker_reason(draft) == "a draft"
    end

    test "blocked by a closed member, even one holding an approval" do
      held = patch(1, 10, reviewer: "reviewer")
      closed = patch(2, 11, reviewer: "reviewer", open: false)

      assert {:blocked, %Patch{pr_xref: 11}} = BundleDisplay.state([held, closed])
      assert BundleDisplay.blocker_reason(closed) == "closed"
    end

    test "ready when every member holds an approval" do
      members = [patch(1, 10, reviewer: "a"), patch(2, 11, reviewer: "b")]

      assert :ready = BundleDisplay.state(members)
    end
  end

  describe "batch_display_order/1" do
    test "bundle members stay together, stacks base first" do
      base = patch(1, 10, bundle_id: 7)
      top = patch(2, 11, bundle_id: 7, stacked_on: 1)
      lone_high = patch(3, 12, bundle_id: nil)
      lone_low = patch(4, 9, bundle_id: nil)

      assert [12, 10, 11, 9] =
               [lone_low, top, lone_high, base]
               |> BundleDisplay.batch_display_order()
               |> Enum.map(& &1.pr_xref)
    end

    test "carries stack depth; singles are depth 0" do
      base = patch(1, 10, bundle_id: 7)
      top = patch(2, 11, bundle_id: 7, stacked_on: 1)
      lone = patch(3, 12, bundle_id: nil)

      assert [{12, 0}, {10, 0}, {11, 1}] =
               [lone, top, base]
               |> BundleDisplay.batch_display_rows()
               |> Enum.map(fn {p, depth} -> {p.pr_xref, depth} end)
    end
  end
end
