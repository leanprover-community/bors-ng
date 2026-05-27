defmodule BorsNG.ProjectControllerTest do
  use BorsNG.ConnCase

  alias BorsNG.Database.Batch
  alias BorsNG.Database.Attempt
  alias BorsNG.Database.Installation
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.Database.LinkUserProject
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
  alias BorsNG.Database.UserPatchDelegation
  alias BorsNG.GitHub

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
        user_xref: 23,
        login: "ghost"
      })

    {:ok, installation: installation, project: project, user: user}
  end

  test "need to log in to see this", %{conn: conn} do
    conn = get(conn, project_path(conn, :index))
    assert html_response(conn, 302) =~ "auth"
  end

  def login(conn) do
    conn = get(conn, auth_path(conn, :index, "github"))
    assert html_response(conn, 302) =~ "MOCK_GITHUB_AUTHORIZE_URL"

    conn =
      get(
        conn,
        auth_path(
          conn,
          :callback,
          "github",
          %{"code" => "MOCK_GITHUB_AUTHORIZE_CODE"}
        )
      )

    html_response(conn, 302)
    conn
  end

  test "do not list unlinked projects", %{conn: conn} do
    conn = login(conn)
    conn = get(conn, project_path(conn, :index))
    refute html_response(conn, 200) =~ "example/project"
  end

  test "list linked projects", %{conn: conn, project: project, user: user} do
    conn = login(conn)
    Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})
    conn = get(conn, project_path(conn, :index))
    assert html_response(conn, 200) =~ "example/project"
  end

  test "show an unbatched patch", %{conn: conn, project: project, user: user} do
    conn = login(conn)
    Repo.insert!(%Batch{project_id: project.id})
    Repo.insert!(%Patch{project_id: project.id})
    Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})
    conn = get(conn, project_path(conn, :show, project))
    assert html_response(conn, 200) =~ "Awaiting review"
    refute html_response(conn, 200) =~ "Waiting to run"
    refute html_response(conn, 200) =~ "Waiting to be tried"
  end

  test "show a batched patch", %{conn: conn, project: project, user: user} do
    conn = login(conn)

    batch =
      Repo.insert!(%Batch{
        project_id: project.id,
        commit: "BC",
        state: :waiting
      })

    patch = Repo.insert!(%Patch{project_id: project.id, commit: "PC"})
    Repo.insert!(%LinkPatchBatch{patch_id: patch.id, batch_id: batch.id})
    Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})
    conn = get(conn, project_path(conn, :show, project))
    refute html_response(conn, 200) =~ "Awaiting review"
    assert html_response(conn, 200) =~ "Waiting to run"
  end

  test "show a delegated patch", %{conn: conn, project: project, user: user} do
    conn = login(conn)

    patch = Repo.insert!(%Patch{project_id: project.id})
    Repo.insert!(%UserPatchDelegation{patch_id: patch.id, user_id: user.id})
    Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})

    conn = get(conn, project_path(conn, :show, project))
    assert html_response(conn, 200) =~ "Delegated"
  end

  test "show trying and waiting attempts", %{conn: conn, project: project, user: user} do
    conn = login(conn)

    patch_waiting = Repo.insert!(%Patch{project_id: project.id, commit: "PC1"})
    patch_running = Repo.insert!(%Patch{project_id: project.id, commit: "PC2"})

    Repo.insert!(%Attempt{
      patch_id: patch_waiting.id,
      into_branch: "master",
      state: :waiting
    })

    Repo.insert!(%Attempt{
      patch_id: patch_running.id,
      into_branch: "master",
      commit: "TC2",
      state: :running
    })

    Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})
    conn = get(conn, project_path(conn, :show, project))
    assert html_response(conn, 200) =~ "Trying"
    assert html_response(conn, 200) =~ "Waiting to be tried"
  end

  test "do not show an unlinked project", %{conn: conn, project: project} do
    conn = login(conn)

    assert_raise BorsNG.PermissionDeniedError, fn ->
      get(conn, project_path(conn, :settings, project))
    end
  end

  test "show an unlinked project to admin", %{
    conn: conn,
    project: project,
    user: user
  } do
    user
    |> User.changeset(%{is_admin: true})
    |> Repo.update!()

    conn = login(conn)
    conn = get(conn, project_path(conn, :show, project))
    assert html_response(conn, 200) =~ "example/project"
  end

  test "show an unlinked project's settings to admin", %{
    conn: conn,
    project: project,
    user: user
  } do
    user
    |> User.changeset(%{is_admin: true})
    |> Repo.update!()

    conn = login(conn)
    conn = get(conn, project_path(conn, :settings, project))
    assert html_response(conn, 200) =~ "example/project"
    assert html_response(conn, 200) =~ "Reviewer"
  end

  test "add a known reviewer", %{conn: conn, project: project, user: user} do
    Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})
    Repo.insert!(%User{login: "case", user_xref: 9999})

    conn =
      conn
      |> login()
      |> post(
        project_path(conn, :add_reviewer, project),
        %{"reviewer" => %{"login" => "case"}}
      )

    resp =
      conn
      |> get(redirected_to(conn, 302))
      |> html_response(200)

    assert resp =~ "case"
    refute resp =~ "GitHub user not found"
  end

  test "reject nil reviewer", %{conn: conn, project: project, user: user} do
    Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})

    GitHub.ServerMock.put_state(%{
      users: %{}
    })

    conn =
      conn
      |> login()
      |> post(
        project_path(conn, :add_reviewer, project),
        %{"reviewer" => %{"login" => "case"}}
      )

    resp =
      conn
      |> get(redirected_to(conn, 302))
      |> html_response(200)

    assert resp =~ "GitHub user not found"
  end

  test "add an unknown reviewer", %{conn: conn, project: project, user: user} do
    Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})

    GitHub.ServerMock.put_state(%{
      users: %{
        "case" => %GitHub.User{
          login: "case",
          id: 9999
        }
      }
    })

    conn =
      conn
      |> login()
      |> post(
        project_path(conn, :add_reviewer, project),
        %{"reviewer" => %{"login" => "case"}}
      )

    resp =
      conn
      |> get(redirected_to(conn, 302))
      |> html_response(200)

    assert resp =~ "case"
    refute resp =~ "GitHub user not found"
  end

  test "reject empty reviewer", %{conn: conn, project: project, user: user} do
    Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})

    GitHub.ServerMock.put_state(%{
      users: %{
        "" => %GitHub.User{
          login: "",
          id: 9999
        }
      }
    })

    conn =
      conn
      |> login()
      |> post(
        project_path(conn, :add_reviewer, project),
        %{"reviewer" => %{"login" => ""}}
      )

    resp =
      conn
      |> get(redirected_to(conn, 302))
      |> html_response(200)

    assert resp =~ "Please enter a GitHub user"
  end

  describe "update_delegation_settings" do
    test "persists the default expiry value", %{conn: conn, project: project, user: user} do
      Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})

      conn =
        conn
        |> login()
        |> put(
          project_path(conn, :update_delegation_settings, project),
          %{"project" => %{"delegation_default_expiry_sec" => "86400"}}
        )

      assert redirected_to(conn, 302) =~ "settings"

      updated = Repo.get!(Project, project.id)
      assert updated.delegation_default_expiry_sec == 86_400
    end

    test "backfills expires_at on open patches with nil-expiry delegations",
         %{conn: conn, project: project, user: user} do
      Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})

      open_patch = Repo.insert!(%Patch{project_id: project.id, pr_xref: 1, open: true})
      closed_patch = Repo.insert!(%Patch{project_id: project.id, pr_xref: 2, open: false})

      delegatee =
        Repo.insert!(%User{user_xref: 4242, login: "alice"})

      open_delegation =
        Repo.insert!(%UserPatchDelegation{
          user_id: delegatee.id,
          patch_id: open_patch.id,
          expires_at: nil
        })

      closed_delegation =
        Repo.insert!(%UserPatchDelegation{
          user_id: delegatee.id,
          patch_id: closed_patch.id,
          expires_at: nil
        })

      conn =
        conn
        |> login()
        |> put(
          project_path(conn, :update_delegation_settings, project),
          %{"project" => %{"delegation_default_expiry_sec" => "3600"}}
        )

      assert redirected_to(conn, 302) =~ "settings"

      refreshed_open = Repo.get!(UserPatchDelegation, open_delegation.id)
      assert refreshed_open.expires_at != nil

      # Closed-patch delegations are left alone
      refreshed_closed = Repo.get!(UserPatchDelegation, closed_delegation.id)
      assert refreshed_closed.expires_at == nil
    end

    test "rejects values above the 90-day cap", %{conn: conn, project: project, user: user} do
      Repo.insert!(%LinkUserProject{user_id: user.id, project_id: project.id})
      too_big = BorsNG.Command.delegation_max_duration_sec() + 1

      conn =
        conn
        |> login()
        |> put(
          project_path(conn, :update_delegation_settings, project),
          %{"project" => %{"delegation_default_expiry_sec" => Integer.to_string(too_big)}}
        )

      assert html_response(conn, 200) =~ "Cannot update delegation settings"

      updated = Repo.get!(Project, project.id)
      assert updated.delegation_default_expiry_sec == nil
    end
  end
end
