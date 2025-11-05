defmodule BorsNG.ApiController do
  @moduledoc """
  JSON API endpoints.
  """

  use BorsNG.Web, :controller

  import Ecto.Query, only: [from: 2]

  alias BorsNG.Database.Repo
  alias BorsNG.Database.Batch
  alias BorsNG.Database.Project

  @doc """
  GET /api/active-batches

  Returns the IDs of all active (incomplete) batches across all projects.
  """
  def active_batches(conn, _params) do
    ids =
      from(b in Batch,
        where: b.state == ^:waiting or b.state == ^:running,
        select: b.id
      )
      |> Repo.all()

    render(conn, "active_batches.json", batch_ids: ids)
  end

  @doc """
  GET /repositories/:id/active-batches

  Returns the IDs of all active (incomplete) batches for a specific project.
  Responds with 404 if the project does not exist.
  """
  def project_active_batches(conn, %{"id" => id}) do
    case Repo.get(Project, id) do
      nil ->
        send_resp(conn, 404, "")

      %Project{} = project ->
        ids =
          from(b in Batch.all_for_project(project.id, :incomplete), select: b.id)
          |> Repo.all()

        render(conn, "active_batches.json", batch_ids: ids)
    end
  end
end
