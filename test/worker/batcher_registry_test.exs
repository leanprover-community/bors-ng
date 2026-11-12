defmodule BorsNG.Worker.BatcherRegistryTest do
  @moduledoc """
  Tests for `Batcher.Registry`'s tracking of each project's batcher.

  `Batcher.Registry.get/1` used to ask the registry for a batcher, wait up to
  half a second for one to register, and then start one in the caller's
  process. A batcher registers by a cast from its `init/1`, so two callers for
  a project with no batcher each started one. The registry kept the first, and
  the second crashed in `Batcher.check_self/1` at its first message, which was
  lost. The registry now starts the batcher in its own `handle_call/3`.
  """
  use BorsNG.Worker.TestCase

  import ExUnit.CaptureLog

  alias BorsNG.Database.Batch
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Worker.Batcher

  setup do
    # Other tests leave their batchers running. Start with none, and leave
    # none, even when a test fails.
    Batcher.Supervisor.terminate_all()
    on_exit(fn -> Batcher.Supervisor.terminate_all() end)
  end

  defp project! do
    inst = Repo.insert!(%Installation{installation_xref: 9_100_001})

    Repo.insert!(%Project{
      name: "registry/project",
      installation_id: inst.id,
      repo_xref: 9_100_002,
      staging_branch: "staging"
    })
  end

  defp children do
    Batcher.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end

  # The registry handles its messages in order, so once this returns it has
  # handled every registration sent before it.
  defp registry_names do
    {names, _refs} = :sys.get_state(Batcher.Registry)
    names
  end

  test "concurrent gets for a project with no batcher start one batcher" do
    proj = project!()
    test_pid = self()

    # Release every caller at once, as webhooks for the project arriving
    # together would.
    callers =
      for _ <- 1..20 do
        spawn_link(fn ->
          receive do
            :go -> send(test_pid, {:batcher, self(), Batcher.Registry.get(proj.id)})
          end
        end)
      end

    Enum.each(callers, &send(&1, :go))

    pids =
      for caller <- callers do
        assert_receive {:batcher, ^caller, pid}, 5_000
        pid
      end

    assert [batcher] = Enum.uniq(pids)
    assert children() == [batcher]
    assert registry_names()[proj.id] == batcher
  end

  test "the warning about a second batcher names both batchers" do
    proj = project!()

    {batcher, log} =
      with_log(fn ->
        batcher = Batcher.Registry.get(proj.id)

        # The batcher's own registration reaches the registry after the get
        # that started and recorded it, and only confirms it.
        assert registry_names()[proj.id] == batcher
        batcher
      end)

    refute log =~ "already has batcher"

    {other, log} =
      with_log(fn ->
        {:ok, other} = Batcher.Supervisor.start(proj.id)
        assert registry_names()[proj.id] == batcher
        other
      end)

    assert log =~ "already has batcher #{inspect(batcher)}; not monitoring #{inspect(other)}"
  end

  test "Batcher.Registry.init/1 records the batchers it starts" do
    proj = project!()

    # Project.active/0 only reports projects with a queued batch.
    Repo.insert!(%Batch{project_id: proj.id, into_branch: "master", state: :waiting})

    # A get queued behind init/1 must find the batcher init/1 started, not
    # start another, so init/1 can't wait for the batcher to register.
    {:ok, {names, refs}} = Batcher.Registry.init(:ok)

    assert [batcher] = children()
    assert names == %{proj.id => batcher}
    assert Map.values(refs) == [proj.id]
  end
end
