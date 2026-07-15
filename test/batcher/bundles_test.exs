defmodule BorsNG.Worker.Batcher.BundlesTest do
  use ExUnit.Case, async: true

  alias BorsNG.Database.Patch
  alias BorsNG.Worker.Batcher.Bundles

  describe "stack_order/1" do
    defp fake_patch(id, xref, stacked_on \\ nil) do
      %Patch{id: id, pr_xref: xref, stacked_on_id: stacked_on}
    end

    test "no edges: PR-number order" do
      a = fake_patch(1, 5)
      b = fake_patch(2, 3)
      assert Bundles.stack_order([a, b]) == [b, a]
    end

    test "a child merges after its parent even with a lower PR number" do
      parent = fake_patch(2, 9)
      child = fake_patch(1, 1, 2)
      assert Bundles.stack_order([child, parent]) == [parent, child]
    end

    test "chains order root-first" do
      a = fake_patch(3, 3)
      b = fake_patch(2, 2, 3)
      c = fake_patch(1, 1, 2)
      assert Bundles.stack_order([c, b, a]) == [a, b, c]
    end

    test "a stacked-on patch outside the list is ignored" do
      a = fake_patch(1, 5, 99)
      b = fake_patch(2, 1)
      assert Bundles.stack_order([a, b]) == [b, a]
    end

    test "a stored cycle falls back to PR-number order" do
      a = fake_patch(1, 1, 2)
      b = fake_patch(2, 2, 1)
      assert Bundles.stack_order([a, b]) == [a, b]
    end
  end
end
