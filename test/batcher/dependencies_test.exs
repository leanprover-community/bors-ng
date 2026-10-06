defmodule BorsNG.Worker.Batcher.DependenciesTest do
  use BorsNG.Database.ModelCase

  alias BorsNG.Database.Installation
  alias BorsNG.Database.Patch
  alias BorsNG.Database.PatchBundle
  alias BorsNG.Database.Project
  alias BorsNG.Worker.Batcher.Dependencies

  @repo "leanprover-community/mathlib4"
  # mathlib4's dependent-issues keywords, as literal text.
  @mathlib ["- [ ] depends on:", "- [x] depends on:"]

  defp refs(body, keywords \\ ["depends on"]) do
    Dependencies.references(body, keywords, @repo)
  end

  describe "references/3" do
    test "reads mathlib's checklist lines, ticked or not" do
      body = """
      Adds a lemma.

      ---

      - [ ] depends on: #123
      - [x] depends on: #456 [some extra text]
      """

      assert refs(body, @mathlib) == [{:local, 123}, {:local, 456}]
    end

    test "reads every reference on the rest of the line, not just the first" do
      assert refs("depends on: #1, #2 and also #3") ==
               [{:local, 1}, {:local, 2}, {:local, 3}]
    end

    test "matches a keyword in any case, and its spaces as any whitespace" do
      assert refs("DEPENDS   ON #7") == [{:local, 7}]
      assert refs("depends\non #8") == [{:local, 8}]
    end

    test "reads the next non-blank line when the keyword's line has no reference" do
      # dependent-issues lets whitespace, newlines included, separate a keyword
      # from its reference, so this is a dependency it finds.
      assert refs("- [ ] depends on:\n\n  #9\n#10", @mathlib) == [{:local, 9}]
      assert refs("depends on: the following\r\n#11\r\n") == [{:local, 11}]
    end

    test "does not read the next line when the keyword's line has a reference" do
      assert refs("depends on: #1\nCloses #2") == [{:local, 1}]
    end

    test "ignores references that do not follow a keyword" do
      assert refs("Closes #12. See #13.") == []
    end

    test "ignores the example lines of mathlib's PR template" do
      body = """
      <!--
      If this PR depends on other PRs, please list them below this comment,
      using the following format:
      - [ ] depends on: #abc [optional extra text]
      - [ ] depends on: #xyz [optional extra text]

      -->
      """

      assert refs(body) == []
      assert refs(body, @mathlib) == []
    end

    test "tells this repository's references from other repositories'" do
      body = """
      depends on: leanprover-community/mathlib4#20
      depends on: Leanprover-Community/Mathlib4#21
      depends on: leanprover-community/batteries#22
      """

      assert refs(body) == [
               {:local, 20},
               {:local, 21},
               {:external, "leanprover-community/batteries#22"}
             ]
    end

    test "reads GitHub links to pull requests and issues" do
      body = """
      depends on: https://github.com/leanprover-community/mathlib4/pull/30
      depends on: https://github.com/leanprover-community/mathlib4/issues/31#issuecomment-1
      depends on: https://github.com/leanprover/lean4/pull/32
      """

      assert refs(body) == [
               {:local, 30},
               {:local, 31},
               {:external, "leanprover/lean4#32"}
             ]
    end

    test "lists each dependency once" do
      assert refs("depends on: #5\nblocked by #5", ["depends on", "blocked by"]) ==
               [{:local, 5}]
    end

    test "reads nothing from an empty description" do
      assert refs(nil) == []
      assert refs("") == []
    end
  end

  describe "check/4" do
    setup do
      inst = Repo.insert!(%Installation{installation_xref: 91})

      proj =
        Repo.insert!(%Project{
          name: @repo,
          installation_id: inst.id,
          repo_xref: 14,
          staging_branch: "staging"
        })

      {:ok, proj: proj}
    end

    defp insert_patch(proj, xref, params \\ %{}) do
      %Patch{project_id: proj.id, pr_xref: xref, commit: "c#{xref}", into_branch: "master"}
      |> Map.merge(params)
      |> Repo.insert!()
    end

    defp bundle(proj, patches) do
      bundle = Repo.insert!(PatchBundle.new(proj.id))
      Enum.map(patches, &(&1 |> Patch.changeset(%{bundle_id: bundle.id}) |> Repo.update!()))
    end

    defp check(patch, body), do: Dependencies.check(patch, body, ["depends on"], @repo)

    test "clears a dependency in the same bundle", %{proj: proj} do
      [_a, b] = bundle(proj, [insert_patch(proj, 1), insert_patch(proj, 2)])
      assert check(b, "depends on: #1") == :clear
    end

    test "clears a dependency that is closed or merged", %{proj: proj} do
      insert_patch(proj, 1, %{open: false})
      b = insert_patch(proj, 2)
      assert check(b, "depends on: #1") == :clear
    end

    test "blocks on an open dependency outside the bundle", %{proj: proj} do
      insert_patch(proj, 1)
      b = insert_patch(proj, 2)
      assert check(b, "depends on: #1") == {:blocked, ["#1"]}
    end

    test "names only the dependencies that still block", %{proj: proj} do
      insert_patch(proj, 3)
      [_a, b] = bundle(proj, [insert_patch(proj, 1), insert_patch(proj, 2)])

      body = """
      - [ ] depends on: #1
      - [ ] depends on: #3
      """

      assert check(b, body) == {:blocked, ["#3"]}
    end

    test "blocks on an open dependency in another bundle", %{proj: proj} do
      bundle(proj, [insert_patch(proj, 1), insert_patch(proj, 3)])
      [_c, b] = bundle(proj, [insert_patch(proj, 4), insert_patch(proj, 2)])
      assert check(b, "depends on: #1") == {:blocked, ["#1"]}
    end

    test "blocks on a number bors has no pull request for", %{proj: proj} do
      b = insert_patch(proj, 2)
      assert check(b, "depends on: #99") == {:blocked, ["#99"]}
      assert check(b, "depends on: #99999999999") == {:blocked, ["#99999999999"]}
    end

    test "blocks on a closed pull request of another project", %{proj: proj} do
      other =
        Repo.insert!(%Project{
          name: "other/repo",
          installation_id: proj.installation_id,
          repo_xref: 15,
          staging_branch: "staging"
        })

      insert_patch(other, 1, %{open: false})
      b = insert_patch(proj, 2)
      assert check(b, "depends on: #1") == {:blocked, ["#1"]}
    end

    test "blocks on a dependency in another repository", %{proj: proj} do
      b = insert_patch(proj, 2)

      assert check(b, "depends on: leanprover-community/batteries#1") ==
               {:blocked, ["leanprover-community/batteries#1"]}
    end

    test "reports a description that lists nothing", %{proj: proj} do
      b = insert_patch(proj, 2)
      assert check(b, "Adds a lemma.") == :unlisted
    end
  end
end
