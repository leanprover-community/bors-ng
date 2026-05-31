defmodule BorsNG.Database.Context.DelegationTest do
  use ExUnit.Case

  alias BorsNG.Database.Context.Delegation
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
  alias BorsNG.Database.UserPatchDelegation
  alias BorsNG.GitHub

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    inst =
      %Installation{installation_xref: 92}
      |> Repo.insert!()

    proj =
      %Project{
        installation_id: inst.id,
        repo_xref: 21,
        staging_branch: "staging",
        name: "example/delegation"
      }
      |> Repo.insert!()

    user =
      %User{user_xref: 41, login: "alice"}
      |> Repo.insert!()

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 7,
        commit: "abc",
        into_branch: "master",
        open: true
      }
      |> Repo.insert!()

    GitHub.ServerMock.put_state(%{
      {{:installation, 92}, 21} => %{
        branches: %{},
        comments: %{7 => []},
        statuses: %{}
      }
    })

    {:ok, proj: proj, user: user, patch: patch}
  end

  defp comments do
    GitHub.ServerMock.get_state() |> get_in([{{:installation, 92}, 21}, :comments, 7])
  end

  describe "sweep/0" do
    test "deletes expired delegations and posts a notification", %{user: user, patch: patch} do
      past =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-3600, :second)
        |> NaiveDateTime.truncate(:second)

      Repo.insert!(%UserPatchDelegation{
        user_id: user.id,
        patch_id: patch.id,
        expires_at: past,
        delegated_at_commit: "abc"
      })

      Delegation.sweep()

      assert [] == Repo.all(UserPatchDelegation)
      assert Enum.any?(comments(), &String.contains?(&1, "Delegation for @alice"))
      assert Enum.any?(comments(), &String.contains?(&1, "expired"))
    end

    test "does not post expired comment when patch is closed", %{user: user, patch: patch} do
      {:ok, _} =
        patch
        |> Patch.changeset(%{open: false})
        |> Repo.update()

      past =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-3600, :second)
        |> NaiveDateTime.truncate(:second)

      Repo.insert!(%UserPatchDelegation{
        user_id: user.id,
        patch_id: patch.id,
        expires_at: past
      })

      Delegation.sweep()

      assert [] == Repo.all(UserPatchDelegation)
      assert comments() == []
    end

    test "sends a warning comment when expiry is within 24h", %{user: user, patch: patch} do
      soon =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(3600, :second)
        |> NaiveDateTime.truncate(:second)

      d =
        Repo.insert!(%UserPatchDelegation{
          user_id: user.id,
          patch_id: patch.id,
          expires_at: soon
        })

      Delegation.sweep()

      reloaded = Repo.get!(UserPatchDelegation, d.id)
      refute is_nil(reloaded.warning_sent_at)

      assert Enum.any?(comments(), &String.contains?(&1, "expires"))
      assert Enum.any?(comments(), &String.contains?(&1, "@alice"))
    end

    test "does not warn twice on the same delegation", %{user: user, patch: patch} do
      soon =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(3600, :second)
        |> NaiveDateTime.truncate(:second)

      already =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-60, :second)
        |> NaiveDateTime.truncate(:second)

      Repo.insert!(%UserPatchDelegation{
        user_id: user.id,
        patch_id: patch.id,
        expires_at: soon,
        warning_sent_at: already
      })

      Delegation.sweep()

      assert comments() == []
    end

    test "leaves future-expiring delegations alone", %{user: user, patch: patch} do
      future =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(7 * 86_400, :second)
        |> NaiveDateTime.truncate(:second)

      d =
        Repo.insert!(%UserPatchDelegation{
          user_id: user.id,
          patch_id: patch.id,
          expires_at: future
        })

      Delegation.sweep()

      reloaded = Repo.get!(UserPatchDelegation, d.id)
      assert is_nil(reloaded.warning_sent_at)
      assert reloaded.expires_at == future
    end
  end

  describe "reconcile_default_expiry/2" do
    test "backfills expires_at on an open patch and comments", %{user: user, patch: patch} do
      d =
        Repo.insert!(%UserPatchDelegation{
          user_id: user.id,
          patch_id: patch.id,
          expires_at: nil
        })

      assert [_] = Delegation.reconcile_default_expiry(patch, 3600)

      reloaded = Repo.get!(UserPatchDelegation, d.id)
      refute is_nil(reloaded.expires_at)

      assert Enum.any?(comments(), &String.contains?(&1, "@alice"))
      assert Enum.any?(comments(), &String.contains?(&1, "bors.toml"))
    end

    test "is a no-op when there is no default duration", %{user: user, patch: patch} do
      d =
        Repo.insert!(%UserPatchDelegation{
          user_id: user.id,
          patch_id: patch.id,
          expires_at: nil
        })

      assert [] == Delegation.reconcile_default_expiry(patch, nil)

      reloaded = Repo.get!(UserPatchDelegation, d.id)
      assert is_nil(reloaded.expires_at)
      assert comments() == []
    end

    test "does not touch delegations that already have an expiry", %{user: user, patch: patch} do
      future =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(7 * 86_400, :second)
        |> NaiveDateTime.truncate(:second)

      d =
        Repo.insert!(%UserPatchDelegation{
          user_id: user.id,
          patch_id: patch.id,
          expires_at: future
        })

      assert [] == Delegation.reconcile_default_expiry(patch, 3600)

      reloaded = Repo.get!(UserPatchDelegation, d.id)
      assert reloaded.expires_at == future
      assert comments() == []
    end

    test "does not backfill delegations on closed patches", %{user: user, patch: patch} do
      {:ok, closed} =
        patch
        |> Patch.changeset(%{open: false})
        |> Repo.update()

      d =
        Repo.insert!(%UserPatchDelegation{
          user_id: user.id,
          patch_id: patch.id,
          expires_at: nil
        })

      assert [] == Delegation.reconcile_default_expiry(closed, 3600)

      reloaded = Repo.get!(UserPatchDelegation, d.id)
      assert is_nil(reloaded.expires_at)
      assert comments() == []
    end
  end
end
