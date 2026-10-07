defmodule BorsNG.Worker.Batcher.DependenciesTest do
  use BorsNG.Database.ModelCase

  alias BorsNG.Database.Installation
  alias BorsNG.Database.Patch
  alias BorsNG.Database.PatchBundle
  alias BorsNG.Database.Project
  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.Dependencies

  @repo "leanprover-community/mathlib4"
  # mathlib4's dependent-issues keywords, as literal text.
  @mathlib ["- [ ] depends on:", "- [x] depends on:"]

  defp refs(body, keywords \\ ["depends on:"]) do
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

    test "with mathlib's keywords, a sentence is no dependency" do
      assert refs("This depends on: #5 landing first.", @mathlib) == []
    end

    test "reads only the reference right after the keyword" do
      assert refs("depends on: #1, #2 and also #3") == [{:local, 1}]
      assert refs("depends on: the lemma in #4") == []
    end

    test "matches a keyword in any case, and its spaces as any whitespace" do
      assert refs("DEPENDS   ON #7", ["depends on"]) == [{:local, 7}]
      assert refs("depends\non #8", ["depends on"]) == [{:local, 8}]
      assert refs("-  [ ]  depends on: #9", @mathlib) == [{:local, 9}]
    end

    test "lets whitespace, newlines included, separate a keyword from its reference" do
      assert refs("- [ ] depends on:\n\n  #9\n#10", @mathlib) == [{:local, 9}]
      assert refs("depends on:\r\n#11\r\n") == [{:local, 11}]
      # JavaScript's \s, which dependent-issues uses, takes Unicode spaces too.
      assert refs("depends on: #12") == [{:local, 12}]
    end

    test "needs whitespace before the reference, and a whole number" do
      assert refs("depends on:#5") == []
      assert refs("depends on: #5a") == []
      assert refs("depends on: #0") == []
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

      assert refs(body, ["depends on"]) == []
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
               {:external, "leanprover-community/batteries", 22}
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
               {:external, "leanprover/lean4", 32}
             ]
    end

    test "reads a link only with its owner and repository" do
      assert refs("depends on: https://github.com//pull/33") == []
      # A repository may be named `issues`.
      assert refs("depends on: https://github.com/owner/issues/issues/34") ==
               [{:external, "owner/issues", 34}]
    end

    test "needs two characters in an owner or repository name, as issue-regex does" do
      assert refs("depends on: x/tool#5") == []
      assert refs("depends on: tools/y#5") == []
      assert refs("depends on: https://github.com/a/b/pull/5") == []
      assert refs("depends on: ab/cd#5") == [{:external, "ab/cd", 5}]
    end

    test "takes only ASCII as word characters, as JavaScript does" do
      # Erlang's PCRE tables are Latin-1, where `é` is a word character.
      assert refs("depends on: #5é") == [{:local, 5}]
      assert refs("depends on: owner/répo#5") == []
      assert refs("depends on: #5_") == []
    end

    test "takes only JavaScript's whitespace" do
      # JavaScript's `\s` takes the ideographic space, but not U+0085.
      assert refs("depends on:\u0085#5") == []
      assert refs("depends on:\u3000#5") == [{:local, 5}]
    end

    test "folds case as JavaScript does, never into ASCII from outside it" do
      # PCRE's `:caseless` matches the Kelvin sign as `k` and `ſ` as `s`.
      assert refs("dependſ on: #5") == []
      assert refs("depends on: #5\u212a") == [{:local, 5}]
      assert refs("DÉPEND DE #5", ["dépend de"]) == [{:local, 5}]
      assert refs("depends on: HTTPS://GITHUB.COM/a1/b1/PULL/5") == [{:external, "a1/b1", 5}]
    end

    test "lists each dependency once" do
      assert refs("depends on #5\nblocked by #5", ["depends on", "blocked by"]) ==
               [{:local, 5}]

      # GitHub names are case-insensitive.
      assert refs("depends on lean/Lean4#5\nblocked by Lean/lean4#5", [
               "depends on",
               "blocked by"
             ]) == [{:external, "lean/Lean4", 5}]
    end

    test "reads nothing from an empty description" do
      assert refs(nil) == []
      assert refs("") == []
    end

    test "reads a description that is not valid UTF-8" do
      assert refs(<<"depends on: #5 ", 0xFF>>) == [{:local, 5}]
    end
  end

  describe "check/5" do
    setup do
      GitHub.ServerMock.put_state(%{})
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

    @conn {{:installation, 91}, 14}

    defp check(patch, body), do: Dependencies.check(@conn, patch, body, ["depends on:"], @repo)

    # What GitHub says of this repository's issues, and of other repositories'.
    defp put_issue_states(local, external \\ %{}) do
      GitHub.ServerMock.put_state(%{@conn => %{issue_states: local}, issue_states: external})
    end

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

    test "asks GitHub about a number bors has no pull request for", %{proj: proj} do
      # Issues, or pull requests that closed before bors was installed.
      put_issue_states(%{7 => :closed, 8 => :open})
      b = insert_patch(proj, 2)
      assert check(b, "depends on: #7") == :clear
      assert check(b, "depends on: #8") == {:blocked, ["#8"]}
    end

    test "blocks on a number GitHub does not have", %{proj: proj} do
      b = insert_patch(proj, 2)
      assert check(b, "depends on: #99") == {:blocked, ["#99"]}
      assert check(b, "depends on: #99999999999") == {:blocked, ["#99999999999"]}
    end

    test "does not ask GitHub about a pull request bors has", %{proj: proj} do
      put_issue_states(%{1 => :closed})
      insert_patch(proj, 1)
      b = insert_patch(proj, 2)
      assert check(b, "depends on: #1") == {:blocked, ["#1"]}
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

    test "asks GitHub about a dependency in another repository", %{proj: proj} do
      put_issue_states(%{}, %{
        {"leanprover-community/batteries", 1} => :closed,
        {"leanprover-community/batteries", 2} => :open
      })

      b = insert_patch(proj, 2)
      assert check(b, "depends on: leanprover-community/batteries#1") == :clear

      assert check(b, "depends on: leanprover-community/batteries#2") ==
               {:blocked, ["leanprover-community/batteries#2"]}

      # Missing, or in a private repository bors is not installed on.
      assert check(b, "depends on: leanprover-community/batteries#3") ==
               {:blocked, ["leanprover-community/batteries#3"]}
    end

    test "names blocking dependencies in the order the description lists them",
         %{proj: proj} do
      put_issue_states(%{8 => :open}, %{{"leanprover/lean4", 1} => :open})
      insert_patch(proj, 3)
      b = insert_patch(proj, 2)

      body = """
      - [ ] depends on: leanprover/lean4#1
      - [ ] depends on: #3
      - [ ] depends on: #8
      """

      assert check(b, body) == {:blocked, ["leanprover/lean4#1", "#3", "#8"]}
    end

    test "fails when GitHub cannot say whether a dependency is closed", %{proj: proj} do
      put_issue_states(%{}, %{{"leanprover/lean4", 1} => :error})
      b = insert_patch(proj, 2)

      assert {:error, :get_issue_state, 502, _} = check(b, "depends on: leanprover/lean4#1")
    end

    test "names a dependency that surely blocks, even when GitHub cannot answer for another",
         %{proj: proj} do
      put_issue_states(%{}, %{{"leanprover/lean4", 1} => :error})
      insert_patch(proj, 3)
      b = insert_patch(proj, 2)

      body = """
      - [ ] depends on: leanprover/lean4#1
      - [ ] depends on: #3
      """

      assert check(b, body) == {:blocked, ["#3"]}
    end

    test "asks GitHub nothing more once it fails to answer", %{proj: proj} do
      # Had bors asked about lean4#2, it would block on it.
      put_issue_states(%{}, %{{"leanprover/lean4", 1} => :error, {"leanprover/lean4", 2} => :open})

      b = insert_patch(proj, 2)

      body = """
      - [ ] depends on: leanprover/lean4#1
      - [ ] depends on: leanprover/lean4#2
      """

      assert {:error, :get_issue_state, 502, _} = check(b, body)
    end

    test "clears a description that lists nothing", %{proj: proj} do
      b = insert_patch(proj, 2)
      assert check(b, "Adds a lemma.") == :clear
    end
  end
end
