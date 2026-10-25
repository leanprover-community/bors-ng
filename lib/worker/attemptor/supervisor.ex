defmodule BorsNG.Worker.Attemptor.Supervisor do
  @moduledoc """
  The supervisor of all of the batchers.
  """
  use DynamicSupervisor

  @name BorsNG.Worker.Attemptor.Supervisor

  def start_link do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: @name)
  end

  @doc """
  Start an attemptor for the project. The supervisor never restarts it:
  `BorsNG.Worker.Attemptor.Registry` starts attemptors on demand and restarts
  one that crashes, and an attemptor stops when its project has no try
  running.

  A restart here would leave an attemptor the registry doesn't know: beside the
  registry's own replacement after a crash, and in place of one that stopped,
  until the registry starts another. It would poll the project's tries beside
  the registry's, and come back each time it stopped.
  """
  @spec start(BorsNG.Database.Project.id()) :: {:ok, pid}
  def start(project_id) do
    spec = %{
      id: {BorsNG.Worker.Attemptor, project_id},
      start: {BorsNG.Worker.Attemptor, :start_link, [project_id]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(@name, spec)
  end

  @doc """
  Terminate every attemptor this supervisor currently holds, without restarting
  it.

  Called by `BorsNG.Worker.Attemptor.Registry` as it starts, for the reason
  spelled out in `BorsNG.Worker.Batcher.Supervisor.terminate_all/0`: the
  `:rest_for_one` application tree starts this supervisor before the registry,
  so a registry restart would otherwise leave the previous attemptors running
  alongside the ones its `init/1` starts.
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
