defmodule BorsNG.Worker.Attemptor.Registry do
  @moduledoc """
  The "Attemptor" manages the project's try branch.
  This is the registry of each individual attemptor.
  It starts the attemptor if it doesn't exist,
  restarts it if it crashes,
  and logs the crashes because that's needed sometimes.

  Note that the attemptor and registry are always on the same node.
  Sharding between them will be done by directing which registry to go to.
  """

  use GenServer
  require Logger

  alias BorsNG.Worker.Attemptor
  alias BorsNG.Database.Crash
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo

  @name BorsNG.Worker.Attemptor.Registry

  # Public API

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  def get(project_id) when is_integer(project_id) do
    GenServer.call(@name, {:get, project_id})
  end

  # Server callbacks

  def init(:ok) do
    # This registry may be restarting under a supervisor that was started
    # before it, so `Attemptor.Supervisor` can still hold the attemptors of the
    # previous incarnation. See `Attemptor.Supervisor.terminate_all/0`.
    Attemptor.Supervisor.terminate_all()

    names =
      Project.active()
      |> Repo.all()
      |> Enum.map(&{&1.id, do_start(&1.id)})
      |> Map.new()

    refs =
      names
      |> Enum.map(&{Process.monitor(elem(&1, 1)), elem(&1, 0)})
      |> Map.new()

    {:ok, {names, refs}}
  end

  def do_start(project_id) do
    {:ok, pid} = Attemptor.Supervisor.start(project_id)
    pid
  end

  def start_and_insert(project_id, {names, refs}) do
    pid = do_start(project_id)
    names = Map.put(names, project_id, pid)
    ref = Process.monitor(pid)
    refs = Map.put(refs, ref, project_id)
    {pid, {names, refs}}
  end

  def handle_call({:get, project_id}, _from, {names, _refs} = state) do
    {pid, state} =
      case names[project_id] do
        nil ->
          start_and_insert(project_id, state)

        pid ->
          {pid, state}
      end

    {:reply, pid, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, state) do
    {:noreply, forget(ref, state)}
  end

  # A supervisor-ordered stop is not a crash. `Attemptor.Supervisor.terminate_all/0`
  # exits attemptors this way, and so does application shutdown. Restarting the
  # attemptor and recording a crash for an orderly stop would be wrong, so just
  # drop the entry.
  def handle_info({:DOWN, ref, :process, _pid, :shutdown}, state) do
    {:noreply, forget(ref, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, {:shutdown, _}}, state) do
    {:noreply, forget(ref, state)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, {_, refs} = state) do
    project_id = refs[ref]
    {_pid, state} = start_and_insert(project_id, state)

    record_crash(project_id, reason)

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Drop an attemptor that stopped without crashing.
  defp forget(ref, {names, refs}) do
    {project_id, refs} = Map.pop(refs, ref)
    {Map.delete(names, project_id), refs}
  end

  # Recording the crash is best-effort. The attemptor has already been
  # restarted above, so a failed insert here (e.g. the project row was deleted,
  # leaving the crashes_project_id_fkey dangling, or the DB connection dropped)
  # must not raise and take the registry — and every attemptor it tracks — down
  # with it.
  defp record_crash(project_id, reason) do
    Repo.insert(%Crash{
      project_id: project_id,
      component: "try",
      crash: inspect(reason, pretty: true, width: 60)
    })
  rescue
    e ->
      Logger.error(
        "Failed to record attemptor crash for project #{inspect(project_id)}: #{inspect(e)}"
      )
  end
end
