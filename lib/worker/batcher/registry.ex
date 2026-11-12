defmodule BorsNG.Worker.Batcher.Registry do
  @moduledoc """
  The "Batcher" manages the backlog of batches that each project has.
  This is the registry of each individual batcher.
  It starts the batcher if it doesn't exist,
  restarts it if it crashes,
  and logs the crashes because that's needed sometimes.

  Note that the batcher and registry are always on the same node.
  Sharding between them will be done by directing which registry to go to.
  """

  use GenServer

  alias BorsNG.Worker.Batcher
  alias BorsNG.Worker.Zulip
  alias BorsNG.Database.Batch
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Crash
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo

  require Logger

  @name BorsNG.Worker.Batcher.Registry

  # Public API

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc """
  The project's batcher, which the registry starts if the project has none.

  The registry starts the batcher and records it in the same call, so
  concurrent calls for a project get the same one. A caller must not start one
  itself: the registry would keep the first batcher it hears of, and
  `Batcher.check_self/1` would crash the other at its first message, which is
  lost.
  """
  def get(project_id) when is_integer(project_id) do
    GenServer.call(@name, {:get, project_id})
  end

  @doc """
  Called by each batcher's `init/1` to register itself.

  The registry records a batcher it starts before the batcher's registration
  arrives, so for one of those this confirms what the registry has. It records
  a batcher started some other way, if the project has none.
  """
  def monitor(pid, project_id) do
    GenServer.cast(@name, {:monitor, project_id, pid})
  end

  # Server callbacks

  def init(:ok) do
    # This registry may be restarting under a supervisor that was started
    # before it, so `Batcher.Supervisor` can still hold the batchers of the
    # previous incarnation — unmonitored here, and about to be joined by the
    # ones started below. See `Batcher.Supervisor.terminate_all/0`.
    Batcher.Supervisor.terminate_all()

    # Record each batcher as it starts, rather than wait for its registration:
    # the Endpoint starts before this registry, so a webhook's `get/1` can be
    # queued ahead of the registrations, and would start a second batcher.
    state =
      Project.active()
      |> Repo.all()
      |> Enum.map(fn %{id: id} -> id end)
      |> Enum.uniq()
      |> Enum.reduce({Map.new(), Map.new()}, fn project_id, state ->
        {_pid, state} = start_and_insert(project_id, state)
        state
      end)

    {:ok, state}
  end

  defp start_and_insert(project_id, state) do
    {:ok, pid} = Batcher.Supervisor.start(project_id)
    {pid, insert(project_id, pid, state)}
  end

  defp insert(project_id, pid, {names, refs}) do
    ref = Process.monitor(pid)
    {Map.put(names, project_id, pid), Map.put(refs, ref, project_id)}
  end

  def handle_call({:get, project_id}, _from, {names, _refs} = state) do
    {pid, state} =
      case names[project_id] do
        nil -> start_and_insert(project_id, state)
        pid -> {pid, state}
      end

    {:reply, pid, state}
  end

  def handle_cast({:monitor, project_id, pid}, {names, _refs} = state) do
    new_state =
      case names[project_id] do
        nil ->
          insert(project_id, pid, state)

        # Started by this registry, which recorded it then.
        ^pid ->
          state

        registered ->
          Logger.warning(
            "Project #{inspect(project_id)} already has batcher #{inspect(registered)}; not monitoring #{inspect(pid)}"
          )

          state
      end

    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, pid, :normal}, state) do
    {:noreply, forget(ref, pid, state)}
  end

  # A supervisor-ordered stop is not a crash. `Batcher.Supervisor.terminate_all/0`
  # exits batchers this way, and so does application shutdown. Reacting as if
  # the batcher had crashed would delete the project's queued batches and post a
  # crash alert for an orderly stop, so just drop the entry.
  def handle_info({:DOWN, ref, :process, pid, :shutdown}, state) do
    {:noreply, forget(ref, pid, state)}
  end

  def handle_info({:DOWN, ref, :process, pid, {:shutdown, _}}, state) do
    {:noreply, forget(ref, pid, state)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, {names, refs}) do
    Logger.warning(
      "Batcher #{inspect(pid)} for project #{inspect(refs[ref])} crashed with state #{inspect({names, refs})}"
    )

    {project_id, refs} = Map.pop(refs, ref)

    names =
      if names[project_id] == pid do
        Map.delete(names, project_id)
      else
        names
      end

    # Notify, clean up the project's batches, and record the crash. State has
    # already been pruned above, so this is best-effort: a failure here (e.g.
    # the project row was deleted, leaving crashes_project_id_fkey dangling, or
    # the DB connection dropped) must not raise and take the registry — and
    # every batcher it tracks — down with it.
    clean_up_after_crash(project_id, pid, reason)

    {:noreply, {names, refs}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Drop a batcher that stopped without crashing. Only forget the name if it
  # still points at this pid: a replacement may already have registered.
  defp forget(ref, pid, {names, refs}) do
    {project_id, refs} = Map.pop(refs, ref)

    names =
      if names[project_id] == pid do
        Map.delete(names, project_id)
      else
        names
      end

    {names, refs}
  end

  defp clean_up_after_crash(project_id, pid, reason) do
    crash_messages =
      try do
        build_messages(project_id, pid, reason)
      rescue
        e ->
          e_message = """
          Failed to build crash message:
          ```elixir
          #{inspect(e, pretty: true, width: 60)}
          ```
          """

          Logger.error(e_message)

          [
            """
            #{e_message}

            Crash reason:
            ```elixir
            #{inspect(reason, pretty: true, width: 60)}
            ```
            """
          ]
      end

    case crash_messages do
      [first | rest] ->
        Zulip.send_message("🚨 bors batch worker crashed!\n\n" <> first)

        rest
        |> Enum.each(&Zulip.send_message/1)

      # impossible
      _ ->
        :ok
    end

    project_id
    |> Batch.all_for_project(:waiting)
    |> Repo.all()
    |> Enum.each(&Repo.delete!/1)

    project_id
    |> Batch.all_for_project(:running)
    |> Repo.all()
    |> Enum.map(&Batch.changeset(&1, %{state: :canceled}))
    |> Enum.each(&Repo.update!/1)

    Repo.insert(%Crash{
      project_id: project_id,
      component: "batch",
      crash: Enum.join(crash_messages, "\n")
    })
  rescue
    e ->
      Logger.error(
        "Failed to handle batcher crash for project #{inspect(project_id)}: #{inspect(e)}"
      )
  end

  defp build_messages(project_id, pid, reason) do
    project = Repo.get(Project, project_id)

    project_pr_url =
      Confex.fetch_env!(:bors, :html_github_root) <> "/" <> project.name <> "/pull/"

    header = """
    Project: `#{project.name}`
    Batcher Process ID: `#{inspect(pid)}`
    Crash reason:
    ```elixir
    #{inspect(reason, pretty: true, width: 60)}
    ```
    """

    waiting =
      project_id
      |> Batch.all_for_project(:waiting)
      |> Repo.all()

    waiting_messages = pr_messages(waiting, "Waiting", "deleted", project.name, project_pr_url)

    running =
      project_id
      |> Batch.all_for_project(:running)
      |> Repo.all()

    running_messages = pr_messages(running, "Running", "canceled", project.name, project_pr_url)

    List.flatten([header, waiting_messages, running_messages])
  end

  defp pr_messages(batches, prev_state, action, project_name, project_pr_url) do
    num_batches = length(batches)

    if num_batches > 0 do
      [
        "The following #{num_batches} batch(es) were \"#{prev_state}\" and will now be #{action}:",
        batches
        |> batch_prs()
        |> Enum.with_index(1)
        |> Enum.map(fn {{batch_id, pr_xrefs}, batch_index} ->
          num_prs = length(pr_xrefs)

          [
            """
            **Batch #{batch_id}**, (#{batch_index}/#{num_batches}) of "#{prev_state}" batch(es) to be #{action}.

            The batch contained the following #{num_prs} PR(s):
            """,
            pr_xrefs
            |> Enum.with_index(1)
            |> Enum.map(fn {pr_xref, pr_index} ->
              "(#{pr_index}/#{num_prs}) of Batch #{batch_id}: [#{project_name}##{pr_xref}](#{project_pr_url}#{pr_xref})"
            end)
          ]
        end)
      ]
    else
      []
    end
  end

  # Given a list of batches, return a list of tuples:
  # {batch.id, [list of PR numbers (pr_xref) of all patches in the batch]}
  defp batch_prs(batches) do
    Enum.map(batches, fn batch ->
      pr_xrefs =
        batch.id
        |> Patch.all_for_batch()
        |> Repo.all()
        |> Enum.map(& &1.pr_xref)

      {batch.id, pr_xrefs}
    end)
  end
end
