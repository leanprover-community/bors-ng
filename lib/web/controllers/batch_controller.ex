defmodule BorsNG.BatchController do
  @moduledoc """
  The controller for the batches

  This will either show a batch detail page
  """

  use BorsNG.Web, :controller

  alias BorsNG.BundleDisplay
  alias BorsNG.Database.Batch
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.Status
  alias BorsNG.Worker.Batcher.Bundles

  def show(conn, %{"id" => id}) do
    batch = Repo.get!(Batch, id)
    project = Repo.get(Project, batch.project_id)

    # Merge order, not PR order: bundles stay contiguous and a stacked patch
    # follows the patch it stacks on, exactly as the batcher will land them.
    patches =
      batch.id
      |> LinkPatchBatch.from_batch()
      |> Repo.all()
      |> Bundles.sort_links_for_merge()
      |> Enum.map(& &1.patch)

    statuses = Repo.all(Status.all_for_batch(batch.id))

    render(conn, "show.html",
      batch: batch,
      patches: patches,
      depths: BundleDisplay.depths(patches),
      project: project,
      statuses: statuses
    )
  end
end
