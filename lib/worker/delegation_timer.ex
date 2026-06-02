defmodule BorsNG.Worker.DelegationTimer do
  @moduledoc """
  Periodically runs the time-driven delegation pass
  (`BorsNG.Database.Context.Delegation.sweep/0`): expiring past-due
  delegations, warning about ones expiring within 24 hours, and backfilling a
  `default_expiry_sec` onto forever-delegations whose PR hasn't been touched
  since the default was configured.

  These actions are keyed to the passage of time — there is no GitHub event
  that fires "this delegation expired", "expires in 24h", or "this PR's
  bors.toml gained a default expiry" — so something has to poll. Like the rest
  of bors's workers, this assumes a single instance (see
  `BorsNG.Worker.Batcher.Registry`); running multiple nodes would double up the
  comments.

  In the test environment the timer starts but does not schedule itself, so
  tests drive `Delegation.sweep/0` directly.
  """

  use GenServer

  alias BorsNG.Database.Context.Delegation

  require Logger

  @name BorsNG.Worker.DelegationTimer

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
      Delegation.sweep()
    rescue
      e ->
        Logger.error("DelegationTimer sweep failed: #{Exception.message(e)}")
    end

    schedule_tick()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, Confex.fetch_env!(:bors, :delegation_sweep_period))
  end
end
