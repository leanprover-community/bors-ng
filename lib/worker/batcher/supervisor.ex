defmodule BorsNG.Worker.Batcher.Supervisor do
  @moduledoc """
  The supervisor of all of the batchers.
  """
  use DynamicSupervisor

  @name BorsNG.Worker.Batcher.Supervisor

  def start_link do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: @name)
  end

  @spec start(BorsNG.Database.Project.id()) :: {:ok, pid}
  def start(project_id) do
    spec = %{
      id: {BorsNG.Worker.Batcher, project_id},
      start: {BorsNG.Worker.Batcher, :start_link, [project_id]}
    }

    DynamicSupervisor.start_child(@name, spec)
  end

  @doc """
  Terminate every batcher this supervisor currently holds, without restarting
  it.

  Called by `BorsNG.Worker.Batcher.Registry` as it starts. The application tree
  is `:rest_for_one` and starts this supervisor *before* the registry, so a
  registry crash restarts the registry but not this supervisor: the batchers
  from the previous incarnation stay alive, and the new registry neither
  monitors them (their monitors died with the old registry) nor knows their
  pids, while its `init/1` starts a second batcher for every active project.

  `Batcher.check_self/1` catches such an orphan, but only at poll entry, so one
  already inside a `poll_/1` — for a large squash-merge project that is many
  GitHub round trips long — keeps running beside the new batcher. Two processes
  then poll the same project and can start the same waiting batch. A crash in
  an unmonitored batcher is also invisible: no `:DOWN` reaches the registry, so
  nothing is recorded and no cleanup runs.

  Clearing the children here keeps the invariant the rest of the batcher relies
  on: one batcher per project.
  """
  def terminate_all do
    @name
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_, pid, _, _} when is_pid(pid) -> DynamicSupervisor.terminate_child(@name, pid)
      _ -> :ok
    end)
  end

  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
