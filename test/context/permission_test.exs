defmodule BorsNG.Database.Context.PermissionTest do
  use BorsNG.Database.ModelCase

  alias BorsNG.Database.Context.Permission
  alias BorsNG.Database.Installation
  alias BorsNG.Database.LinkUserProject
  alias BorsNG.Database.LinkMemberProject
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.User
  alias BorsNG.Database.UserPatchDelegation

  setup do
    installation =
      Repo.insert!(%Installation{
        installation_xref: 31
      })

    project =
      Repo.insert!(%Project{
        installation_id: installation.id,
        repo_xref: 13,
        name: "example/project"
      })

    user =
      Repo.insert!(%User{
        login: "lilac"
      })

    patch =
      Repo.insert!(%Patch{
        project: project
      })

    {:ok, project: project, user: user, patch: patch}
  end

  test "user does not have permission by default", params do
    %{patch: patch, user: user} = params
    refute Permission.permission?(:reviewer, user, patch)
    refute Permission.permission?(:member, user, patch)
  end

  test "reviewers have permission", params do
    %{project: project, patch: patch, user: user} = params
    Repo.insert!(%LinkUserProject{user: user, project: project})
    assert Permission.permission?(:reviewer, user, patch)
    assert Permission.permission?(:member, user, patch)
  end

  test "delegated users have permission", params do
    %{patch: patch, user: user} = params
    Repo.insert!(%UserPatchDelegation{user: user, patch: patch})
    assert Permission.permission?(:reviewer, user, patch)
    assert Permission.permission?(:member, user, patch)
  end

  test "delegated users keep permission while expires_at is in the future", params do
    %{patch: patch, user: user} = params

    future =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(3600, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.insert!(%UserPatchDelegation{user: user, patch: patch, expires_at: future})
    assert Permission.permission?(:reviewer, user, patch)
  end

  test "expired delegations lose permission", params do
    %{patch: patch, user: user} = params

    past =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-3600, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.insert!(%UserPatchDelegation{user: user, patch: patch, expires_at: past})
    refute Permission.permission?(:reviewer, user, patch)
  end

  test "Permission.delegate replaces existing row on (user, patch)", params do
    %{patch: patch, user: user} = params

    early =
      NaiveDateTime.utc_now() |> NaiveDateTime.add(60, :second) |> NaiveDateTime.truncate(:second)

    late =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(7 * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    Permission.delegate(user, patch, expires_at: early, delegated_at_commit: "abc")
    Permission.delegate(user, patch, expires_at: late, delegated_at_commit: "def")

    [d] = Repo.all(UserPatchDelegation)
    assert d.expires_at == late
    assert d.delegated_at_commit == "def"
    assert is_nil(d.warning_sent_at)
  end

  test "DB rejects duplicate (user_id, patch_id) when bypassing the context", params do
    %{patch: patch, user: user} = params
    Repo.insert!(%UserPatchDelegation{user_id: user.id, patch_id: patch.id})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%UserPatchDelegation{user_id: user.id, patch_id: patch.id})
    end
  end

  test "members have partial permission", params do
    %{project: project, patch: patch, user: user} = params
    Repo.insert!(%LinkMemberProject{user: user, project: project})
    refute Permission.permission?(:reviewer, user, patch)
    assert Permission.permission?(:member, user, patch)
  end
end
