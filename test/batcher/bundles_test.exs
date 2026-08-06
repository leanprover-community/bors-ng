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

    test "fan-out: two children of one parent come after it, in PR-number order" do
      a = fake_patch(1, 5)
      b = fake_patch(2, 6, 1)
      c = fake_patch(3, 7, 1)
      assert Bundles.stack_order([c, b, a]) == [a, b, c]
    end

    test "forest: multiple roots order breadth-first (roots first, by PR number)" do
      r1 = fake_patch(1, 2)
      r2 = fake_patch(2, 4)
      c1 = fake_patch(3, 1, 1)
      c2 = fake_patch(4, 3, 2)
      assert Bundles.stack_order([c1, r1, c2, r2]) == [r1, r2, c1, c2]
    end
  end

  describe "final_target/1" do
    defp target_patch(id, into, stacked_on \\ nil) do
      %Patch{id: id, into_branch: into, stacked_on_id: stacked_on}
    end

    test "a single root gives its branch" do
      root = target_patch(1, "master")
      child = target_patch(2, "feature-a", 1)
      assert {:ok, "master"} = Bundles.final_target([child, root])
    end

    test "multiple roots that agree give the shared branch" do
      r1 = target_patch(1, "master")
      r2 = target_patch(2, "master")
      c1 = target_patch(3, "feature-a", 1)
      assert {:ok, "master"} = Bundles.final_target([r1, r2, c1])
    end

    test "roots that disagree are a mismatch" do
      r1 = target_patch(1, "master")
      r2 = target_patch(2, "develop")
      assert {:error, :branch_mismatch} = Bundles.final_target([r1, r2])
    end

    test "a member stacked on an out-of-set parent counts as a root" do
      # 2's parent (99) is not in the set, so 2 is a root; its branch must
      # agree with the in-set root, and here it does not.
      root = target_patch(1, "master")
      orphan = target_patch(2, "develop", 99)
      assert {:error, :branch_mismatch} = Bundles.final_target([root, orphan])
    end
  end

  describe "own_changes_url/3" do
    test "points into the child pull request's files view, parent head to child head" do
      project = %BorsNG.Database.Project{name: "example/project"}
      parent = %Patch{commit: "abc", pr_xref: 43}
      child = %Patch{commit: "def", pr_xref: 44}

      assert Bundles.own_changes_url(project, parent, child) ==
               "https://github.com/example/project/pull/44/files/abc..def"
    end

    test "nil when either head commit is unknown" do
      project = %BorsNG.Database.Project{name: "example/project"}
      known = %Patch{commit: "abc", pr_xref: 43}
      unknown = %Patch{commit: nil, pr_xref: 44}

      assert Bundles.own_changes_url(project, unknown, known) == nil
      assert Bundles.own_changes_url(project, known, unknown) == nil
    end
  end
end
