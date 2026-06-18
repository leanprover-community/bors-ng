defmodule BorsNG.Worker.LabelBackstopTimer do
  @moduledoc """
  Periodically runs `BorsNG.Worker.Labeler.backstop_sweep/0`, the self-healing
  reconcile of the state-derived lifecycle labels (LIFECYCLE_LABELS.md).

  The live per-event reconciles — in the batcher transitions and the delegation
  sweep — keep labels accurate in the normal case. This timer is the backstop
  for drift they can't catch: a best-effort label write that was dropped at
  event time, a restart mid-transition, or a human editing a managed label. It
  runs on its own (longer) period rather than piggybacking the delegation sweep,
  so repo-wide label listing stays decoupled from delegation expiry.

  Like the other workers it assumes a single instance (see
  `BorsNG.Worker.Batcher.Registry`); running multiple nodes would duplicate the
  reconcile work.

  In the test environment the timer starts but does not schedule itself, so
  tests drive `Labeler.backstop_sweep/0` directly.
  """

  use GenServer

  alias BorsNG.Worker.Labeler

  require Logger

  @name BorsNG.Worker.LabelBackstopTimer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  def init(:ok) do
    unless Application.get_env(:bors, :is_test, false) do
      schedule_tick()
    end

    {:ok, :ok}
  end

  def handle_info(:tick, state) do
    try do
      Labeler.backstop_sweep()
    rescue
      e ->
        Logger.error("LabelBackstopTimer sweep failed: #{Exception.message(e)}")
    end

    schedule_tick()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, Confex.fetch_env!(:bors, :label_backstop_period))
  end
end
