defmodule BorsNG.Worker.DelegationInvalidatorTest do
  use ExUnit.Case

  alias BorsNG.Database.Context.Permission
  alias BorsNG.Database.Installation
  alias BorsNG.Database.LinkUserProject
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

  @default_toml ~s"""
  status = ["ci"]
  [delegation]
  invalidate_on_paths = ["Cargo.toml", ".github/**"]
  """

  # opts:
  #   :pr_files — the PR's net file list (pr_diff, fetched via get_pr_files)
  #   :delta    — compare map, {delegated_at_commit, head} => [filenames]
  #   :comments — pre-existing PR comments
  #   :toml     — bors.toml body (defaults to a deny-list of Cargo.toml/.github)
  defp put_mock(opts) do
    GitHub.ServerMock.put_state(%{
      {{:installation, 93}, 23} => %{
        # bors.toml stored under the "main" base ref
        branches: %{"main" => "base_tip"},
        comments: %{9 => Keyword.get(opts, :comments, [])},
        statuses: %{},
        files: %{"main" => %{"bors.toml" => Keyword.get(opts, :toml, @default_toml)}},
        pr_files: %{9 => Keyword.get(opts, :pr_files, [])},
        compare: Keyword.get(opts, :delta, %{}),
        compare_error: Keyword.get(opts, :compare_error, false)
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
    put_mock(
      # PR's author content vs base = ["Cargo.toml", "src/lib.rs"]
      pr_files: ["Cargo.toml", "src/lib.rs"],
      # changes between delegation and new head also touch Cargo.toml
      delta: %{{"old_head", "new_head_sha"} => ["Cargo.toml"]}
    )

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
    put_mock(
      # Author's PR content doesn't include Cargo.toml
      pr_files: ["src/lib.rs"],
      # delta DOES include Cargo.toml because base-merge brought it in
      delta: %{{"old_head", "new_head_sha"} => ["Cargo.toml", "src/lib.rs"]}
    )

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
    put_mock(
      pr_files: ["Cargo.toml"],
      delta: %{{"old_head", "new_head_sha"} => ["Cargo.toml"]}
    )

    # bypass Permission.delegate to insert a row without delegated_at_commit
    Repo.insert!(%UserPatchDelegation{user_id: user.id, patch_id: patch.id, expires_at: nil})

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [_] = Repo.all(UserPatchDelegation)
  end

  test "leaves delegations alone when no path matches", %{user: user, patch: patch} do
    put_mock(
      pr_files: ["src/lib.rs", "README.md"],
      delta: %{{"old_head", "new_head_sha"} => ["src/lib.rs"]}
    )

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [_] = Repo.all(UserPatchDelegation)
  end

  test "matches glob patterns under a directory", %{user: user, patch: patch} do
    put_mock(
      pr_files: [".github/workflows/ci.yml"],
      delta: %{{"old_head", "new_head_sha"} => [".github/workflows/ci.yml"]}
    )

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [] == Repo.all(UserPatchDelegation)
  end

  test "combines revocations into a single comment when multiple delegations match",
       %{user: user, patch: patch} do
    put_mock(
      pr_files: ["Cargo.toml", ".github/workflows/ci.yml"],
      delta: %{
        {"old_head_a", "new_head_sha"} => ["Cargo.toml"],
        {"old_head_b", "new_head_sha"} => [".github/workflows/ci.yml"]
      }
    )

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
    put_mock(toml: ~s/status = ["ci"]/)

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [_] = Repo.all(UserPatchDelegation)
  end

  @restrict_toml ~s"""
  status = ["ci"]
  [delegation]
  restrict_to_paths = ["src/**"]
  """

  test "revokes when an authored path is outside restrict_to_paths", %{user: user, patch: patch} do
    put_mock(
      toml: @restrict_toml,
      pr_files: ["src/lib.rs", "docs/readme.md"],
      delta: %{{"old_head", "new_head_sha"} => ["docs/readme.md"]}
    )

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [] == Repo.all(UserPatchDelegation)
    comments = GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])
    assert Enum.any?(comments, &String.contains?(&1, "outside the paths this delegation covers"))
    assert Enum.any?(comments, &String.contains?(&1, "docs/readme.md"))
  end

  test "leaves delegation alone when authored paths stay within restrict_to_paths", %{
    user: user,
    patch: patch
  } do
    put_mock(
      toml: @restrict_toml,
      pr_files: ["src/lib.rs", "src/util.rs"],
      delta: %{{"old_head", "new_head_sha"} => ["src/util.rs"]}
    )

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [_] = Repo.all(UserPatchDelegation)
  end

  test "deny-list overrides allow-list for a path inside the scope", %{user: user, patch: patch} do
    put_mock(
      toml: ~s"""
      status = ["ci"]
      [delegation]
      restrict_to_paths = ["src/**"]
      invalidate_on_paths = ["src/crypto.rs"]
      """,
      pr_files: ["src/crypto.rs"],
      delta: %{{"old_head", "new_head_sha"} => ["src/crypto.rs"]}
    )

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [] == Repo.all(UserPatchDelegation)
    comments = GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])
    assert Enum.any?(comments, &String.contains?(&1, "invalidate_on_paths"))
    assert Enum.any?(comments, &String.contains?(&1, "src/crypto.rs"))
  end

  test "keeps the delegation when a huge base-merge delta is entirely in scope", %{
    user: user,
    patch: patch
  } do
    # Regression test for leanprover-community/mathlib4#39106. The author clicked
    # "Update branch", so the delta from the delegation commit to the new head is
    # dominated by the 300+ files master touched and blows past the compare cap.
    # But the author's own net diff (pr_files) is a single in-scope file, so none
    # of that base-merge churn is authored work — the delegation must survive,
    # even though the raw delta is truncated.
    put_mock(
      pr_files: ["src/lib.rs"],
      delta: %{{"old_head", "new_head_sha"} => Enum.map(1..300, &"f#{&1}.rs")}
    )

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [_] = Repo.all(UserPatchDelegation)
    comments = GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])
    assert comments == []
  end

  test "revokes (too large) when truncation may hide the newness of an unacceptable authored path",
       %{user: user, patch: patch} do
    # Here the author's net diff DOES include a sensitive path (Cargo.toml), and
    # the delta is truncated, so bors cannot confirm whether the latest push is
    # what touched it (Cargo.toml isn't among the 300 files it could see). It
    # fails safe and revokes.
    put_mock(
      pr_files: ["Cargo.toml", "src/lib.rs"],
      delta: %{{"old_head", "new_head_sha"} => Enum.map(1..300, &"f#{&1}.rs")}
    )

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [] == Repo.all(UserPatchDelegation)
    comments = GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])
    assert Enum.any?(comments, &String.contains?(&1, "too many files"))
  end

  test "falls back to delta-only when pr_diff is truncated, over-revoking", %{
    user: user,
    patch: patch
  } do
    # Cargo.toml is in the delta but NOT in pr_files; with a complete filter it
    # would be treated as base-merge noise and ignored (see the base-merge
    # test). Truncating pr_files (>= 3000 files) drops the filter, so the
    # delta-only fallback flags it instead.
    put_mock(
      pr_files: Enum.map(1..3000, &"f#{&1}.rs"),
      delta: %{{"old_head", "new_head_sha"} => ["Cargo.toml"]}
    )

    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [] == Repo.all(UserPatchDelegation)
  end

  test "leaves delegation alone when nothing changed since delegation", %{
    user: user,
    patch: patch
  } do
    # delegated_at_commit == current head, so the delta compares a commit to
    # itself; the mock has no entry for it and returns an empty list.
    put_mock(pr_files: ["Cargo.toml"])

    delegate!(user, patch, "new_head_sha")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    assert [_] = Repo.all(UserPatchDelegation)
  end

  test "push path keeps the delegation when the delta cannot be read (fails open)", %{
    user: user,
    patch: patch
  } do
    put_mock(compare_error: true)
    delegate!(user, patch, "old_head")

    DelegationInvalidator.invalidate_for_patch(patch.id)

    # Unlike the merge-time gate, the push path fails open: it can't prove the
    # change is bad, so it keeps the delegation and posts no revoke. The
    # merge-time gate is the fail-closed backstop.
    assert [_] = Repo.all(UserPatchDelegation)

    comments = GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])
    refute Enum.any?(comments, &String.contains?(&1, "revoked"))
  end

  describe "verify_for_merge/2" do
    test "denies and revokes when a sensitive path changed since delegation", %{
      user: user,
      patch: patch
    } do
      put_mock(
        pr_files: ["Cargo.toml", "src/lib.rs"],
        delta: %{{"old_head", "new_head_sha"} => ["Cargo.toml"]}
      )

      delegate!(user, patch, "old_head")

      assert :deny == DelegationInvalidator.verify_for_merge(patch, user)
      assert [] == Repo.all(UserPatchDelegation)

      comments =
        GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])

      assert Enum.any?(comments, &String.contains?(&1, "revoked"))
      assert Enum.any?(comments, &String.contains?(&1, "Cargo.toml"))
    end

    test "allows when nothing sensitive changed since delegation", %{user: user, patch: patch} do
      put_mock(
        pr_files: ["src/lib.rs"],
        delta: %{{"old_head", "new_head_sha"} => ["src/lib.rs"]}
      )

      delegate!(user, patch, "old_head")

      assert :ok == DelegationInvalidator.verify_for_merge(patch, user)
      assert [_] = Repo.all(UserPatchDelegation)
    end

    test "does not block or revoke a project reviewer", %{user: user, patch: patch, proj: proj} do
      put_mock(
        pr_files: ["Cargo.toml"],
        delta: %{{"old_head", "new_head_sha"} => ["Cargo.toml"]}
      )

      Repo.insert!(%LinkUserProject{user_id: user.id, project_id: proj.id})
      delegate!(user, patch, "old_head")

      assert :ok == DelegationInvalidator.verify_for_merge(patch, user)
      assert [_] = Repo.all(UserPatchDelegation)
    end

    test "allows when the user has no active delegation", %{user: user, patch: patch} do
      put_mock(
        pr_files: ["Cargo.toml"],
        delta: %{{"old_head", "new_head_sha"} => ["Cargo.toml"]}
      )

      assert :ok == DelegationInvalidator.verify_for_merge(patch, user)
    end

    test "denies without revoking when the delta cannot be read (fails closed)", %{
      user: user,
      patch: patch
    } do
      put_mock(compare_error: true)
      delegate!(user, patch, "old_head")

      assert :deny == DelegationInvalidator.verify_for_merge(patch, user)
      # Fail closed, but do NOT revoke: an unreadable delta isn't proof the
      # change is bad. A later `bors r+` re-runs the gate.
      assert [_] = Repo.all(UserPatchDelegation)

      comments =
        GitHub.ServerMock.get_state() |> get_in([{{:installation, 93}, 23}, :comments, 9])

      assert Enum.any?(comments, &String.contains?(&1, "Couldn't approve via delegation"))
    end
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

    test "stays silent when the base tree is truncated", %{patch: patch} do
      # Cargo.toml is present and Gemfile is missing, which would normally warn
      # about Gemfile. But the tree is truncated, so the file set is incomplete
      # and the lint must skip rather than warn off a partial listing.
      GitHub.ServerMock.put_state(%{
        {{:installation, 93}, 23} => %{
          branches: %{"main" => "base_tip"},
          comments: %{9 => []},
          statuses: %{},
          truncated_trees: ["main"],
          files: %{"main" => %{"bors.toml" => @lint_toml, "Cargo.toml" => "_"}}
        }
      })

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
