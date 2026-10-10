defmodule BorsNG.CleanupTest do
  use ExUnit.Case
  import Ecto.Query
  import ExUnit.CaptureLog

  alias BorsNG.Database.Batch
  alias BorsNG.Database.Cleanup
  alias BorsNG.Database.Crash
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Patch
  alias BorsNG.Database.PatchBundle
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

  defp age!(schema, id, age_months) do
    old =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-age_months * 31 * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.update_all(from(r in schema, where: r.id == ^id), set: [updated_at: old])
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

    age!(Patch, patch.id, age_months)
    patch
  end

  defp insert_batch(proj, state, age_months) do
    batch = Repo.insert!(%{Batch.new(proj.id, "master") | state: state})
    age!(Batch, batch.id, age_months)
    batch
  end

  defp insert_crash(proj, age_months) do
    crash = Repo.insert!(%Crash{project_id: proj.id, crash: "boom", component: "test"})
    age!(Crash, crash.id, age_months)
    crash
  end

  describe "Cleanup.run/1" do
    test "deletes old closed batches, closed patches, and crash reports", %{proj: proj} do
      old_ok = insert_batch(proj, :ok, 12)
      old_error = insert_batch(proj, :error, 12)
      old_canceled = insert_batch(proj, :canceled, 12)
      old_waiting = insert_batch(proj, :waiting, 12)
      old_running = insert_batch(proj, :running, 12)
      recent_ok = insert_batch(proj, :ok, 1)

      old_closed = insert_patch(proj, false, 12)
      recent_closed = insert_patch(proj, false, 1)
      old_open = insert_patch(proj, true, 12)

      old_crash = insert_crash(proj, 12)
      recent_crash = insert_crash(proj, 1)

      assert Cleanup.run(6) == %{batches: 3, patches: 1, crashes: 1, bundles: 0}

      refute Repo.get(Batch, old_ok.id)
      refute Repo.get(Batch, old_error.id)
      refute Repo.get(Batch, old_canceled.id)
      assert Repo.get(Batch, old_waiting.id)
      assert Repo.get(Batch, old_running.id)
      assert Repo.get(Batch, recent_ok.id)

      refute Repo.get(Patch, old_closed.id)
      assert Repo.get(Patch, recent_closed.id)
      assert Repo.get(Patch, old_open.id)

      refute Repo.get(Crash, old_crash.id)
      assert Repo.get(Crash, recent_crash.id)
    end

    test "sweeps bundles orphaned by pruned patches", %{proj: proj} do
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

      # A bundle no patch belongs to goes whatever its age.
      empty = Repo.insert!(PatchBundle.new(proj.id))

      assert Cleanup.run(6) == %{batches: 0, patches: 3, crashes: 0, bundles: 2}

      refute Repo.get(PatchBundle, orphaned.id)
      refute Repo.get(PatchBundle, empty.id)
      assert Repo.get(PatchBundle, kept.id)
      assert Repo.get(Patch, open_member.id).bundle_id == kept.id
    end

    test "returns zeros when nothing is old enough", %{proj: proj} do
      batch = insert_batch(proj, :ok, 1)
      patch = insert_patch(proj, false, 1)
      crash = insert_crash(proj, 1)

      assert Cleanup.run(6) == %{batches: 0, patches: 0, crashes: 0, bundles: 0}

      assert Repo.get(Batch, batch.id)
      assert Repo.get(Patch, patch.id)
      assert Repo.get(Crash, crash.id)
    end

    test "logs what it deleted", %{proj: proj} do
      insert_patch(proj, false, 12)
      insert_crash(proj, 12)

      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log = capture_log(fn -> Cleanup.run(6) end)

      assert log =~
               "Cleanup of data older than 6 months deleted batches: 0, patches: 1, " <>
                 "crash reports: 1, patch bundles without patches: 0"
    end

    test "refuses a months that isn't a positive integer", %{proj: proj} do
      old_closed = insert_patch(proj, false, 12)
      recent_closed = insert_patch(proj, false, 1)

      for months <- [0, -1, 1.5, "6", nil] do
        assert_raise ArgumentError, ~r/months must be a positive integer/, fn ->
          Cleanup.run(months)
        end
      end

      assert Repo.get(Patch, old_closed.id)
      assert Repo.get(Patch, recent_closed.id)
    end

    test "calls nothing in Mix, which a release doesn't have" do
      {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(Cleanup), [:imports])

      assert imports != []
      refute Enum.any?(imports, fn {mod, _, _} -> String.starts_with?("#{mod}", "Elixir.Mix") end)
    end
  end

  describe "mix bors.cleanup" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "prunes old data when --months is given", %{proj: proj} do
      old_closed = insert_patch(proj, false, 12)
      recent_closed = insert_patch(proj, false, 1)
      old_open = insert_patch(proj, true, 12)
      old_crash = insert_crash(proj, 12)

      Mix.Tasks.Bors.Cleanup.run(["--months", "6"])

      assert_received {:mix_shell, :info, ["Cleaning data older than 6 months"]}
      refute Repo.get(Patch, old_closed.id)
      assert Repo.get(Patch, recent_closed.id)
      assert Repo.get(Patch, old_open.id)
      refute Repo.get(Crash, old_crash.id)
    end

    test "does nothing without --months", %{proj: proj} do
      old_closed = insert_patch(proj, false, 12)

      Mix.Tasks.Bors.Cleanup.run([])

      assert_received {:mix_shell, :info, ["Nothing to do; pass --months N to prune old data"]}
      assert Repo.get(Patch, old_closed.id)
    end

    test "refuses --months that isn't positive", %{proj: proj} do
      old_closed = insert_patch(proj, false, 12)

      assert_raise Mix.Error, ~r/--months must be a positive integer, got: 0/, fn ->
        Mix.Tasks.Bors.Cleanup.run(["--months", "0"])
      end

      assert Repo.get(Patch, old_closed.id)
    end
  end
end
