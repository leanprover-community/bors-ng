defmodule BorsNG.BundleControllerTest do
  use BorsNG.ConnCase

  alias BorsNG.Database.Batch
  alias BorsNG.Database.Installation
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.Database.Patch
  alias BorsNG.Database.PatchBundle
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
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

    bundle = Repo.insert!(%PatchBundle{project_id: project.id})

    base =
      Repo.insert!(%Patch{
        project_id: project.id,
        pr_xref: 43,
        title: "base patch",
        commit: "aaaaaaa",
        bundle_id: bundle.id,
        bundle_reviewer: "reviewer"
      })

    stacked =
      Repo.insert!(%Patch{
        project_id: project.id,
        pr_xref: 44,
        title: "stacked patch",
        commit: "bbbbbbb",
        bundle_id: bundle.id,
        stacked_on_id: base.id
      })

    {:ok, project: project, user: user, bundle: bundle, base: base, stacked: stacked}
  end

  test "need to log in to see this", %{conn: conn, bundle: bundle} do
    conn = get(conn, "/bundles/#{bundle.id}")
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

  test "shows the members in stack order with their approval state", %{
    conn: conn,
    bundle: bundle
  } do
    conn = login(conn)
    conn = get(conn, "/bundles/#{bundle.id}")

    html = html_response(conn, 200)
    assert html =~ "Bundle Details"
    assert html =~ "(stack order)"
    assert html =~ "Waiting for approval of"
    assert html =~ "#43"
    assert html =~ "#44"
    assert html =~ "✓ held (reviewer)"
    assert html =~ "waiting"
    assert html =~ "Stacked on #43"
    assert html =~ "None"
    # base before stacked
    assert html =~ ~r/#43.*#44/s
  end

  test "links a stacked member's own changes through bors", %{
    conn: conn,
    bundle: bundle,
    stacked: stacked
  } do
    conn = login(conn)
    conn = get(conn, "/bundles/#{bundle.id}")

    html = html_response(conn, 200)
    assert html =~ "/patches/#{stacked.id}/own-changes"
    # only the stacked member gets a link; the root's diff is its own PR
    assert length(String.split(html, "own changes")) == 2
  end

  defp put_compare_status(statuses) do
    GitHub.ServerMock.put_state(%{{{:installation, 31}, 13} => %{compare_status: statuses}})
  end

  defp own_changes(conn, patch), do: get(conn, "/patches/#{patch.id}/own-changes")

  test "own changes: the range in the pull request when the child contains the parent", %{
    conn: conn,
    stacked: stacked
  } do
    stacked |> Ecto.Changeset.change(commit: "ccccccc") |> Repo.update!()
    put_compare_status(%{{"aaaaaaa", "ccccccc"} => :ahead})

    assert redirected_to(own_changes(conn, stacked), 302) ==
             "https://github.com/example/project/pull/44/files/aaaaaaa..ccccccc"
  end

  test "own changes: a compare view when the child lacks the parent's head", %{
    conn: conn,
    stacked: stacked
  } do
    put_compare_status(%{{"aaaaaaa", "bbbbbbb"} => :diverged})

    assert redirected_to(own_changes(conn, stacked), 302) ==
             "https://github.com/example/project/compare/aaaaaaa...bbbbbbb"
  end

  test "own changes: the files tab when the child's base is the parent's branch", %{
    conn: conn,
    base: base,
    stacked: stacked
  } do
    base |> Ecto.Changeset.change(head_ref: "feature") |> Repo.update!()
    stacked |> Ecto.Changeset.change(into_branch: "feature") |> Repo.update!()

    assert redirected_to(own_changes(conn, stacked), 302) ==
             "https://github.com/example/project/pull/44/files"
  end

  test "own changes: the files tab for a stack root or an unknown head commit", %{
    conn: conn,
    base: base,
    stacked: stacked
  } do
    assert redirected_to(own_changes(conn, base), 302) ==
             "https://github.com/example/project/pull/43/files"

    stacked |> Ecto.Changeset.change(commit: nil) |> Repo.update!()

    assert redirected_to(own_changes(conn, stacked), 302) ==
             "https://github.com/example/project/pull/44/files"
  end

  test "own changes: needs a login when private repositories are allowed", %{
    conn: conn,
    stacked: stacked
  } do
    System.put_env("ALLOW_PRIVATE_REPOS", "true")
    on_exit(fn -> System.delete_env("ALLOW_PRIVATE_REPOS") end)
    put_compare_status(%{{"aaaaaaa", "bbbbbbb"} => :ahead})

    assert html_response(own_changes(conn, stacked), 302) =~ "auth"

    assert redirected_to(conn |> login() |> own_changes(stacked), 302) ==
             "https://github.com/example/project/pull/44/files/aaaaaaa..bbbbbbb"
  end

  test "lists the batches the bundle entered", %{conn: conn, bundle: bundle, project: project} do
    batch =
      Repo.insert!(%Batch{
        project_id: project.id,
        state: :running
      })

    for patch <- Repo.all(Patch.all_for_bundle(bundle.id)) do
      Repo.insert!(%LinkPatchBatch{patch_id: patch.id, batch_id: batch.id})
    end

    conn = login(conn)
    conn = get(conn, "/bundles/#{bundle.id}")

    html = html_response(conn, 200)
    assert html =~ "Batch #{batch.id}"
    assert html =~ "(Running)"
    refute html =~ "None"
  end

  test "returns 404 when there is no such bundle", %{conn: conn} do
    conn = login(conn)

    assert_error_sent(404, fn ->
      get(conn, "/bundles/0")
    end)
  end
end
