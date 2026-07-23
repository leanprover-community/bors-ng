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
  end
end
