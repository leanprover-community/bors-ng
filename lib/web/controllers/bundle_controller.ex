defmodule BorsNG.BundleController do
  @moduledoc """
  The bundle detail page: the members of one `bors link` / `bors stack`
  bundle, their approval state, and the batches they have entered.
  """

  use BorsNG.Web, :controller

  alias BorsNG.BundleDisplay
  alias BorsNG.Database.Batch
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.Database.Patch
  alias BorsNG.Database.PatchBundle
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
  alias BorsNG.Database.UserPatchDelegation

  def show(conn, %{"id" => id}) do
    bundle = Repo.get!(PatchBundle, id)
    project = Repo.get(Project, bundle.project_id)

    members =
      bundle.id
      |> Patch.all_for_bundle()
      |> Repo.all()

    batches =
      from(b in Batch,
        join: l in LinkPatchBatch,
        on: l.batch_id == b.id,
        join: p in Patch,
        on: p.id == l.patch_id,
        where: p.bundle_id == ^bundle.id,
        distinct: true,
        order_by: [desc: b.id]
      )
      |> Repo.all()

    delegations =
      from(upd in UserPatchDelegation,
        join: u in User,
        on: u.id == upd.user_id,
        where: upd.patch_id in ^Enum.map(members, & &1.id),
        select: {upd.patch_id, u.login}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    render(conn, "show.html",
      bundle: bundle,
      project: project,
      members: BundleDisplay.display_rows(members),
      state: BundleDisplay.state(members),
      stacked: BundleDisplay.stacked?(members),
      batches: batches,
      delegations: delegations
    )
  end
end
