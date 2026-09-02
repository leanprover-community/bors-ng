defmodule BorsNG.Worker.Attemptor.Supervisor do
  @moduledoc """
  The supervisor of all of the batchers.
  """
  use DynamicSupervisor

  @name BorsNG.Worker.Attemptor.Supervisor

  def start_link do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: @name)
  end

  @spec start(BorsNG.Database.Project.id()) :: {:ok, pid}
  def start(project_id) do
    spec = %{
      id: {BorsNG.Worker.Attemptor, project_id},
      start: {BorsNG.Worker.Attemptor, :start_link, [project_id]}
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
