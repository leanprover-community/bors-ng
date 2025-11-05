defmodule BorsNG.ApiControllerTest do
  use BorsNG.ConnCase

  alias BorsNG.Database.Repo
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Project
  alias BorsNG.Database.Batch

  setup do
    installation = Repo.insert!(%Installation{installation_xref: 101})

    project1 =
      Repo.insert!(%Project{
        installation_id: installation.id,
        repo_xref: 201,
        name: "example/project1"
      })

    project2 =
      Repo.insert!(%Project{
        installation_id: installation.id,
        repo_xref: 202,
        name: "example/project2"
      })

    {:ok, project1: project1, project2: project2}
  end

  test "global active batches endpoint returns only waiting/running across projects", %{
    conn: conn,
    project1: project1,
    project2: project2
  } do
    b1 = Repo.insert!(%Batch{project_id: project1.id, state: :waiting})
    b2 = Repo.insert!(%Batch{project_id: project1.id, state: :running})
    _b3 = Repo.insert!(%Batch{project_id: project1.id, state: :ok})
    b4 = Repo.insert!(%Batch{project_id: project2.id, state: :waiting})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/active-batches")

    resp = json_response(conn, 200)
    assert Map.has_key?(resp, "batch_ids")
    assert Enum.sort(resp["batch_ids"]) == Enum.sort([b1.id, b2.id, b4.id])
  end

  test "project-scoped active batches endpoint returns only that project's active batches", %{
    conn: conn,
    project1: project1,
    project2: project2
  } do
    b1 = Repo.insert!(%Batch{project_id: project1.id, state: :waiting})
    b2 = Repo.insert!(%Batch{project_id: project1.id, state: :running})
    _b3 = Repo.insert!(%Batch{project_id: project1.id, state: :ok})
    _b4 = Repo.insert!(%Batch{project_id: project2.id, state: :waiting})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get("/repositories/#{project1.id}/active-batches")

    resp = json_response(conn, 200)
    assert Map.has_key?(resp, "batch_ids")
    assert Enum.sort(resp["batch_ids"]) == Enum.sort([b1.id, b2.id])
  end

  test "project-scoped active batches returns 404 for missing project", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get("/repositories/999999/active-batches")

    assert conn.status == 404
  end
end
