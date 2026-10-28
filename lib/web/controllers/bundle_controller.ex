defmodule BorsNG.BundleController do
  @moduledoc """
  The bundle detail page: the members of one `bors link` / `bors stack`
  bundle, their approval state, and the batches they have entered. It also
  serves the own-changes link of a stacked pull request.
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
  alias BorsNG.Worker.Batcher.Bundles

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

  @doc """
  Redirects to a stacked patch's own changes, built from the current head
  commits. The link that bors posts on `bors stack` points here, so it
  follows later pushes. The target is the first of these that applies:

    * The Files tab of the pull request, when the patch has no parent, a
      head commit is unknown, or the patch's base branch is the parent's
      branch. In the last case, the tab shows only the patch's changes.
    * The commit range from the parent's head to the patch's head in the
      pull request (`pull/N/files/parent..child`), when the patch contains
      the parent's head. Line comments work there. GitHub shows this range
      only when the parent's head is a commit of the pull request.
    * A compare view of the two heads. It takes no line comments.
  """
  def own_changes(conn, %{"id" => id}) do
    patch = Repo.get!(Patch, id)
    project = Repo.get!(Project, patch.project_id)
    parent = patch.stacked_on_id && Repo.get(Patch, patch.stacked_on_id)
    repo_conn = Project.installation_connection(project.repo_xref, Repo)

    redirect(conn, external: own_changes_url(repo_conn, project, parent, patch))
  end

  # A head_ref is a branch name without its repository, so a parent from a
  # fork can share its name with the base branch of both pull requests.
  defp own_changes_url(repo_conn, project, parent, child) do
    repo = "#{Confex.fetch_env!(:bors, :html_github_root)}/#{project.name}"
    pr = "#{repo}/pull/#{child.pr_xref}"

    cond do
      is_nil(parent) or is_nil(parent.commit) or is_nil(child.commit) or
          (parent.head_ref != nil and child.into_branch == parent.head_ref and
             child.into_branch != parent.into_branch) ->
        "#{pr}/files"

      Bundles.contains_head?(repo_conn, parent, child) ->
        "#{pr}/files/#{parent.commit}..#{child.commit}"

      true ->
        "#{repo}/compare/#{parent.commit}...#{child.commit}"
    end
  end
end
