defmodule BorsNG.Worker.RegistryRestartTest do
  @moduledoc """
  Regression tests for duplicate workers across a registry restart.

  The application tree is `:rest_for_one` and starts each worker's
  `DynamicSupervisor` *before* its registry, so a registry crash restarts the
  registry but not the supervisor: the workers of the previous incarnation stay
  alive and unmonitored while the new registry's `init/1` starts a second
  worker for every active project. `check_self/1` only runs at poll entry, so
  an orphan already inside a poll keeps running beside its replacement — two
  processes polling one project.

  Each registry therefore clears its supervisor's children as it starts.
  """
  use BorsNG.Worker.TestCase

  alias BorsNG.Database.Batch
  alias BorsNG.Database.Crash
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo

  defp project! do
    inst = Repo.insert!(%Installation{installation_xref: 8_000_001})

    Repo.insert!(%Project{
      name: "restart/project",
      installation_id: inst.id,
      repo_xref: 8_000_002,
      staging_branch: "staging"
    })
  end

  test "Batcher.Supervisor.terminate_all/0 clears its children for good" do
    proj = project!()

    {:ok, pid} = BorsNG.Worker.Batcher.Supervisor.start(proj.id)
    ref = Process.monitor(pid)

    BorsNG.Worker.Batcher.Supervisor.terminate_all()

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    refute Process.alive?(pid)

    # terminate_child/2 does not restart, so no replacement is left behind for
    # the incoming registry to run alongside.
    assert DynamicSupervisor.which_children(BorsNG.Worker.Batcher.Supervisor) == []
  end

  test "Attemptor.Supervisor.terminate_all/0 clears its children for good" do
    proj = project!()

    {:ok, pid} = BorsNG.Worker.Attemptor.Supervisor.start(proj.id)
    ref = Process.monitor(pid)

    BorsNG.Worker.Attemptor.Supervisor.terminate_all()

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    refute Process.alive?(pid)
    assert DynamicSupervisor.which_children(BorsNG.Worker.Attemptor.Supervisor) == []
  end

  test "terminate_all/0 is a no-op when the supervisor is empty" do
    assert BorsNG.Worker.Batcher.Supervisor.terminate_all() == :ok
    assert BorsNG.Worker.Attemptor.Supervisor.terminate_all() == :ok
  end

  test "a supervisor-ordered stop does not wipe the project's queue" do
    proj = project!()

    batch = Repo.insert!(%Batch{project_id: proj.id, into_branch: "master", state: :waiting})

    ref = make_ref()
    state = {%{proj.id => self()}, %{ref => proj.id}}

    assert {:noreply, {names, refs}} =
             BorsNG.Worker.Batcher.Registry.handle_info(
               {:DOWN, ref, :process, self(), :shutdown},
               state
             )

    # The entry is dropped, but the batch survives: a `:shutdown` is an orderly
    # stop, not a crash, so clean_up_after_crash/3 must not run.
    assert names == %{}
    assert refs == %{}
    assert Repo.get(Batch, batch.id) != nil
  end

  test "a supervisor-ordered stop does not record an attemptor crash" do
    proj = project!()

    ref = make_ref()
    state = {%{proj.id => self()}, %{ref => proj.id}}

    assert {:noreply, {names, refs}} =
             BorsNG.Worker.Attemptor.Registry.handle_info(
               {:DOWN, ref, :process, self(), {:shutdown, :terminated}},
               state
             )

    assert names == %{}
    assert refs == %{}
    assert Crash |> where([c], c.project_id == ^proj.id) |> Repo.all() == []
  end

  test "Batcher.Registry.init/1 leaves exactly one batcher per project" do
    proj = project!()

    # Project.active/0 only reports projects with a queued batch, so the
    # registry needs one to start a batcher for.
    Repo.insert!(%Batch{project_id: proj.id, into_branch: "master", state: :waiting})

    # Stand in for the pre-restart batcher the old supervisor still holds.
    {:ok, orphan} = BorsNG.Worker.Batcher.Supervisor.start(proj.id)
    ref = Process.monitor(orphan)

    {:ok, {_names, _refs}} = BorsNG.Worker.Batcher.Registry.init(:ok)

    assert_receive {:DOWN, ^ref, :process, ^orphan, _}, 1_000

    pids =
      BorsNG.Worker.Batcher.Supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_, pid, _, _} -> pid end)

    assert length(pids) == 1
    refute orphan in pids

    # Leave the supervisor as this test found it: the batcher init/1 started
    # would otherwise poll a project that vanishes with the sandbox rollback.
    BorsNG.Worker.Batcher.Supervisor.terminate_all()
  end
end
