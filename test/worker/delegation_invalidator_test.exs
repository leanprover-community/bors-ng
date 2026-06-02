defmodule BorsNG.Worker.DelegationInvalidatorTest do
  use ExUnit.Case

  alias BorsNG.Database.Context.Permission
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
  alias BorsNG.Database.UserPatchDelegation
  alias BorsNG.GitHub
  alias BorsNG.Worker.DelegationInvalidator

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    inst = Repo.insert!(%Installation{installation_xref: 93})

    proj =
      Repo.insert!(%Project{
        installation_id: inst.id,
        repo_xref: 23,
        staging_branch: "staging",
        name: "example/inval"
      })

    user = Repo.insert!(%User{user_xref: 51, login: "alice"})

    patch =
      Repo.insert!(%Patch{
        project_id: proj.id,
        pr_xref: 9,
        commit: "new_head_sha",
        into_branch: "main",
        open: true
      })

    {:ok, proj: proj, user: user, patch: patch}
  end

  defp put_mock(compare_map, comments \\ []) do
    GitHub.ServerMock.put_state(%{
      {{:installation, 93}, 23} => %{
        branches: %{
          # bors.toml stored under the "main" base ref
          "main" => "base_tip"
        },
        comments: %{9 => comments},
        statuses: %{},
        files: %{
          "main" => %{
            "bors.toml" => ~s"""
            status = ["ci"]
            [delegation]
            invalidate_on_paths = ["Cargo.toml", ".github/**"]
            """
          }
        },
        compare: compare_map
      }
    })
  end

  defp delegate!(user, patch, delegated_at_commit) do
    Permission.delegate(user, patch,
      expires_at:
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(86_400, :second)
        |> NaiveDateTime.truncate(:second),
      delegated_at_commit: delegated_at_commit
    )
  end

  test "invalidates when a sensitive path is newly touched", %{user: user, patch: patch} do
    put_mock(%{
      # 3-dot diff: PR's author content vs base = ["Cargo.toml", "src/lib.rs"]
      {"main", "new_head_sha"} => ["Cargo.toml", "src/lib.rs"],
      # changes between delegation and new head also touch Cargo.toml
      {"old_head", "new_head_sha"} => ["Cargo.toml"]
    })

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [] == Repo.all(UserPatchDelegation)
    comments = GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])
    assert Enum.any?(comments, &String.contains?(&1, "revoked"))
    assert Enum.any?(comments, &String.contains?(&1, "Cargo.toml"))
  end

  test "does NOT invalidate on a base-merge bringing sensitive content from base", %{
    user: user,
    patch: patch
  } do
    put_mock(%{
      # Author's PR content doesn't include Cargo.toml
      {"main", "new_head_sha"} => ["src/lib.rs"],
      # delta DOES include Cargo.toml because base-merge brought it in
      {"old_head", "new_head_sha"} => ["Cargo.toml", "src/lib.rs"]
    })

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [d] = Repo.all(UserPatchDelegation)
    assert d.user_id == user.id
    comments = GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])
    assert comments == []
  end

  test "ignores delegations without delegated_at_commit (legacy rows)", %{
    user: user,
    patch: patch
  } do
    put_mock(%{
      {"main", "new_head_sha"} => ["Cargo.toml"],
      {"old_head", "new_head_sha"} => ["Cargo.toml"]
    })

    # bypass Permission.delegate to insert a row without delegated_at_commit
    Repo.insert!(%UserPatchDelegation{user_id: user.id, patch_id: patch.id, expires_at: nil})

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [_] = Repo.all(UserPatchDelegation)
  end

  test "leaves delegations alone when no path matches", %{user: user, patch: patch} do
    put_mock(%{
      {"main", "new_head_sha"} => ["src/lib.rs", "README.md"],
      {"old_head", "new_head_sha"} => ["src/lib.rs"]
    })

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [_] = Repo.all(UserPatchDelegation)
  end

  test "matches glob patterns under a directory", %{user: user, patch: patch} do
    put_mock(%{
      {"main", "new_head_sha"} => [".github/workflows/ci.yml"],
      {"old_head", "new_head_sha"} => [".github/workflows/ci.yml"]
    })

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [] == Repo.all(UserPatchDelegation)
  end

  test "combines revocations into a single comment when multiple delegations match",
       %{user: user, patch: patch} do
    put_mock(%{
      {"main", "new_head_sha"} => ["Cargo.toml", ".github/workflows/ci.yml"],
      {"old_head_a", "new_head_sha"} => ["Cargo.toml"],
      {"old_head_b", "new_head_sha"} => [".github/workflows/ci.yml"]
    })

    bob = Repo.insert!(%User{user_xref: 52, login: "bob"})

    delegate!(user, patch, "old_head_a")
    delegate!(bob, patch, "old_head_b")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [] == Repo.all(UserPatchDelegation)

    comments = GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])
    assert length(comments) == 1
    [combined] = comments
    assert String.contains?(combined, "alice")
    assert String.contains?(combined, "bob")
    assert String.contains?(combined, "Cargo.toml")
    assert String.contains?(combined, ".github/workflows/ci.yml")
  end

  test "no-op when bors.toml has no delegation paths configured", %{user: user, patch: patch} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 93}, 23} => %{
        branches: %{"main" => "base_tip"},
        comments: %{9 => []},
        statuses: %{},
        files: %{"main" => %{"bors.toml" => ~s/status = ["ci"]/}},
        compare: %{}
      }
    })

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [_] = Repo.all(UserPatchDelegation)
  end

  describe "matches_any?/2" do
    test "literal path match" do
      assert DelegationInvalidator.matches_any?("Cargo.toml", ["Cargo.toml"])
      refute DelegationInvalidator.matches_any?("Cargo.lock", ["Cargo.toml"])
    end

    test "directory glob" do
      assert DelegationInvalidator.matches_any?(".github/workflows/ci.yml", [".github/**"])
      assert DelegationInvalidator.matches_any?(".github/dependabot.yml", [".github/**"])
      refute DelegationInvalidator.matches_any?("src/main.rs", [".github/**"])
    end

    test "any of multiple patterns matches" do
      patterns = ["Cargo.toml", ".github/**"]
      assert DelegationInvalidator.matches_any?("Cargo.toml", patterns)
      assert DelegationInvalidator.matches_any?(".github/foo.yml", patterns)
      refute DelegationInvalidator.matches_any?("README.md", patterns)
    end
  end

  describe "unmatched_paths/2" do
    test "returns patterns matching zero tree entries" do
      tree = ["Cargo.toml", "src/main.rs", ".github/workflows/ci.yml"]

      assert DelegationInvalidator.unmatched_paths(
               ["Cargo.toml", "Gemfile", ".github/**"],
               tree
             ) == ["Gemfile"]
    end

    test "returns [] when all patterns match" do
      tree = ["Cargo.toml", ".github/workflows/ci.yml"]
      assert DelegationInvalidator.unmatched_paths(["Cargo.toml", ".github/**"], tree) == []
    end

    test "returns all patterns when tree is empty" do
      assert DelegationInvalidator.unmatched_paths(["Cargo.toml", "Gemfile"], []) ==
               ["Cargo.toml", "Gemfile"]
    end
  end

  describe "lint_for_patch/1" do
    @lint_toml ~s"""
    status = ["ci"]
    [delegation]
    invalidate_on_paths = ["Cargo.toml", "Gemfile"]
    """

    defp put_lint_mock(extra_files, comments \\ []) do
      GitHub.ServerMock.put_state(%{
        {{:installation, 93}, 23} => %{
          branches: %{"main" => "base_tip"},
          comments: %{9 => comments},
          statuses: %{},
          files: %{"main" => Map.merge(%{"bors.toml" => @lint_toml}, extra_files)}
        }
      })
    end

    test "posts a warning when a pattern matches no files", %{patch: patch} do
      # Tree has Cargo.toml but no Gemfile, so Gemfile is unmatched
      put_lint_mock(%{"Cargo.toml" => "_"})

      DelegationInvalidator.lint_for_patch(patch.id)

      comments =
        GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])

      assert Enum.any?(comments, &String.contains?(&1, "match no files"))
      assert Enum.any?(comments, &String.contains?(&1, "`Gemfile`"))
      refute Enum.any?(comments, &String.contains?(&1, "`Cargo.toml`"))
    end

    test "does not repeat the same warning across tries", %{patch: patch} do
      put_lint_mock(%{"Cargo.toml" => "_"})

      DelegationInvalidator.lint_for_patch(patch.id)
      DelegationInvalidator.lint_for_patch(patch.id)

      comments =
        GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])

      assert Enum.count(comments, &String.contains?(&1, "match no files")) == 1
    end

    test "warns afresh when the set of unmatched patterns changes", %{patch: patch} do
      # First try: Cargo.toml exists, so only Gemfile is unmatched.
      put_lint_mock(%{"Cargo.toml" => "_"})
      DelegationInvalidator.lint_for_patch(patch.id)

      carried =
        GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])

      # Second try: Cargo.toml has since been deleted, so the unmatched set is
      # now {Cargo.toml, Gemfile} — a different message. Carry the first
      # warning forward to prove dedup keys on the exact body, not on substring.
      put_lint_mock(%{}, carried)
      DelegationInvalidator.lint_for_patch(patch.id)

      comments =
        GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])

      assert Enum.count(comments, &String.contains?(&1, "match no files")) == 2

      assert Enum.any?(
               comments,
               &(String.contains?(&1, "`Cargo.toml`") and String.contains?(&1, "`Gemfile`"))
             )
    end

    test "stays silent when every pattern matches", %{patch: patch} do
      put_lint_mock(%{"Cargo.toml" => "_", "Gemfile" => "_"})

      DelegationInvalidator.lint_for_patch(patch.id)

      comments =
        GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])

      assert comments == []
    end

    test "stays silent when invalidate_on_paths is empty", %{patch: patch} do
      GitHub.ServerMock.put_state(%{
        {{:installation, 93}, 23} => %{
          branches: %{"main" => "base_tip"},
          comments: %{9 => []},
          statuses: %{},
          files: %{"main" => %{"bors.toml" => ~s(status = ["ci"])}}
        }
      })

      DelegationInvalidator.lint_for_patch(patch.id)

      comments =
        GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])

      assert comments == []
    end
  end
end
