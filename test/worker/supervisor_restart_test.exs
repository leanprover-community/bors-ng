defmodule BorsNG.Worker.SupervisorRestartTest do
  @moduledoc """
  Regression tests for the per-project workers' restart strategy.

  Each registry starts its project's batcher or attemptor on demand and handles
  its crashes, and a worker stops when its project is idle. So the supervisors
  must not restart them: a worker the supervisor brought back would be one its
  registry doesn't know. An unknown batcher crashes in `check_self/1` at every
  poll, and an unknown attemptor polls the project's tries beside the
  registry's.
  """
  use BorsNG.Worker.TestCase

  alias BorsNG.Database.Installation
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Worker.Attemptor
  alias BorsNG.Worker.Batcher

  setup do
    # Each test counts the supervisors' children, so it starts with none:
    # other tests leave their workers running. A supervisor-ordered stop isn't
    # a crash to either registry.
    Batcher.Supervisor.terminate_all()
    Attemptor.Supervisor.terminate_all()

    # And leaves none, even when it fails.
    on_exit(fn ->
      Batcher.Supervisor.terminate_all()
      Attemptor.Supervisor.terminate_all()
    end)
  end

  defp project! do
    inst = Repo.insert!(%Installation{installation_xref: 9_000_001})

    Repo.insert!(%Project{
      name: "supervisor/project",
      installation_id: inst.id,
      repo_xref: 9_000_002,
      staging_branch: "staging"
    })
  end

  defp children(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end

  defp attemptor_names do
    {names, _refs} = :sys.get_state(Attemptor.Registry)
    names
  end

  test "a batcher that stops is not restarted" do
    proj = project!()

    {:ok, pid} = Batcher.Supervisor.start(proj.id)
    assert Batcher.Registry.get(proj.id) == pid
    ref = Process.monitor(pid)

    # As when its project has nothing left to poll.
    :ok = GenServer.stop(pid, :normal)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert children(Batcher.Supervisor) == []
  end

  test "a batcher the registry doesn't know is not restarted when it crashes" do
    proj = project!()

    {:ok, registered} = Batcher.Supervisor.start(proj.id)
    assert Batcher.Registry.get(proj.id) == registered

    # A second batcher for the project: the registry keeps the first, so this
    # one would fail check_self/1 at its first poll.
    {:ok, orphan} = Batcher.Supervisor.start(proj.id)
    ref = Process.monitor(orphan)

    Process.exit(orphan, {:badmatch, :test})

    assert_receive {:DOWN, ^ref, :process, ^orphan, {:badmatch, :test}}, 1_000
    assert children(Batcher.Supervisor) == [registered]
    assert Batcher.Registry.get(proj.id) == registered
  end

  test "an attemptor that stops is not restarted" do
    proj = project!()

    pid = Attemptor.Registry.get(proj.id)
    ref = Process.monitor(pid)

    # As when its project has no try running.
    :ok = GenServer.stop(pid, :normal)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert children(Attemptor.Supervisor) == []
    refute Map.has_key?(attemptor_names(), proj.id)
  end

  test "a crashed attemptor is replaced once, by its registry" do
    proj = project!()

    pid = Attemptor.Registry.get(proj.id)
    ref = Process.monitor(pid)

    Process.exit(pid, {:badmatch, :test})

    assert_receive {:DOWN, ^ref, :process, ^pid, {:badmatch, :test}}, 1_000

    # The registry's :DOWN handler starts the replacement and records the
    # crash; the supervisor adds none of its own.
    replacement = attemptor_names()[proj.id]
    assert is_pid(replacement)
    assert replacement != pid
    assert children(Attemptor.Supervisor) == [replacement]
  end
end
