defmodule BorsNG.CleanupTest do
  use ExUnit.Case
  import Ecto.Query

  alias BorsNG.Database.Installation
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo

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
        name: "example/cleanup"
      }
      |> Repo.insert!()

    {:ok, proj: proj}
  end

  defp insert_patch(proj, open, age_months) do
    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: :rand.uniform(1_000_000),
        commit: "abc",
        into_branch: "master",
        open: open
      }
      |> Repo.insert!()

    old =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-age_months * 31 * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.update_all(from(p in Patch, where: p.id == ^patch.id), set: [updated_at: old])
    patch
  end

  test "prunes old closed patches when --months is given", %{proj: proj} do
    old_closed = insert_patch(proj, false, 12)
    recent_closed = insert_patch(proj, false, 1)
    old_open = insert_patch(proj, true, 12)

    Mix.Tasks.Bors.Cleanup.run(["--months", "6"])

    refute Repo.get(Patch, old_closed.id)
    assert Repo.get(Patch, recent_closed.id)
    assert Repo.get(Patch, old_open.id)
  end

  test "does nothing without --months", %{proj: proj} do
    old_closed = insert_patch(proj, false, 12)

    Mix.Tasks.Bors.Cleanup.run([])

    assert Repo.get(Patch, old_closed.id)
  end

  test "sweeps bundles orphaned by pruned patches", %{proj: proj} do
    alias BorsNG.Database.PatchBundle

    # Both members old and closed: pruning them orphans the bundle.
    orphaned = Repo.insert!(PatchBundle.new(proj.id))
    old_a = insert_patch(proj, false, 12)
    old_b = insert_patch(proj, false, 12)

    Repo.update_all(from(p in Patch, where: p.id in ^[old_a.id, old_b.id]),
      set: [bundle_id: orphaned.id]
    )

    # One member still open: this bundle stays referenced.
    kept = Repo.insert!(PatchBundle.new(proj.id))
    old_member = insert_patch(proj, false, 12)
    open_member = insert_patch(proj, true, 12)

    Repo.update_all(from(p in Patch, where: p.id in ^[old_member.id, open_member.id]),
      set: [bundle_id: kept.id]
    )

    Mix.Tasks.Bors.Cleanup.run(["--months", "6"])

    refute Repo.get(PatchBundle, orphaned.id)
    assert Repo.get(PatchBundle, kept.id)
    assert Repo.get(Patch, open_member.id).bundle_id == kept.id
  end
end
