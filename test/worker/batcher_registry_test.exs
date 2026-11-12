defmodule BorsNG.Worker.BatcherRegistryTest do
  @moduledoc """
  Tests for `Batcher.Registry`'s tracking of each project's batcher.
  """
  use BorsNG.Worker.TestCase

  import ExUnit.CaptureLog

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

  # The registry handles its messages in order, so once this returns it has
  # handled every registration sent before it.
  defp registry_names do
    {names, _refs} = :sys.get_state(Batcher.Registry)
    names
  end

  test "the warning about a second batcher names both batchers" do
    proj = project!()

    {batcher, log} =
      with_log(fn ->
        batcher = Batcher.Registry.get(proj.id)

        # The batcher registers itself, once, without a warning.
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
end
