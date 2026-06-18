defmodule BorsNG.ApplicationTest do
  use ExUnit.Case, async: true

  alias BorsNG.Application

  # The child id of a spec, whether it's a map spec (%{id: ...}) or a
  # tuple/module spec like {Phoenix.PubSub, opts}.
  defp child_id(%{id: id}), do: id
  defp child_id({mod, _opts}), do: mod
  defp child_id(mod) when is_atom(mod), do: mod

  defp child_ids do
    Application.fetch_repo()
    |> Application.child_specs()
    |> Enum.map(&child_id/1)
  end

  test "PubSub and the Endpoint are supervised before the workers (rest_for_one)" do
    ids = child_ids()

    index = fn id ->
      case Enum.find_index(ids, &(&1 == id)) do
        nil -> flunk("child #{inspect(id)} not found in supervision tree: #{inspect(ids)}")
        i -> i
      end
    end

    # PubSub is the Endpoint's pubsub_server, so it must start first.
    assert index.(Phoenix.PubSub) < index.(BorsNG.Endpoint),
           "PubSub must be supervised before the Endpoint"

    # Regression test for the "table identifier does not refer to an existing
    # ETS table" flake: under rest_for_one a child's crash restarts every child
    # started *after* it. If a worker were ordered before the Endpoint, a
    # transient worker crash would bounce the Endpoint and momentarily wipe its
    # config ETS table, 500-ing in-flight webhook requests. So the Endpoint must
    # precede every worker that can crash.
    workers = [
      BorsNG.Worker.Batcher.Supervisor,
      BorsNG.Worker.Batcher.Registry,
      BorsNG.Worker.Attemptor.Supervisor,
      BorsNG.Worker.Attemptor.Registry,
      BorsNG.Worker.BranchDeleter,
      BorsNG.Worker.DelegationTimer,
      BorsNG.Worker.LabelBackstopTimer,
      BorsNG.Worker.Batcher.GetBorsToml.Cache
    ]

    endpoint_index = index.(BorsNG.Endpoint)

    for worker <- workers do
      assert endpoint_index < index.(worker),
             "Endpoint must be supervised before #{inspect(worker)} under rest_for_one"
    end
  end
end
