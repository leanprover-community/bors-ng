defmodule BorsNG.Worker.Batcher.GetBorsToml.Cache do
  @moduledoc """
  Owns the ETS table backing `BorsNG.Worker.Batcher.GetBorsToml.get_cached/2`.

  The cache is a short-TTL projection of `bors.toml` per `(repo_xref, branch)`,
  used only by the *reconcile* paths (the lifecycle `Labeler` and the delegation
  sweep) to collapse the repeated base-branch config reads those paths would
  otherwise make — most acutely the label backstop sweep, which resolves the
  same handful of base branches for every PR it touches.

  It is deliberately **not** used on the batcher's merge-decision reads, where a
  stale config could drive an actual merge; those keep calling
  `GetBorsToml.get/2` directly.

  Entries expire by TTL — checked lazily on read, plus a periodic prune so a
  multi-tenant keyspace can't grow without bound. The table is public with read
  concurrency so the batcher casts, the sweep, and the backstop all read without
  serializing through this process.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "The ETS table name (also the owning process name)."
  def table, do: @table

  @doc """
  Look up a fresh (non-expired) entry. Returns `{:ok, value}` on a hit or
  `:miss` otherwise (absent, expired, or table not yet created).
  """
  @spec fetch(term) :: {:ok, term} | :miss
  def fetch(key) do
    now = now_ms()

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Store `value` under `key`, expiring `ttl_ms` from now. Returns `value`."
  @spec put(term, term, non_neg_integer) :: term
  def put(key, value, ttl_ms) do
    :ets.insert(@table, {key, value, now_ms() + ttl_ms})
    value
  rescue
    ArgumentError -> value
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_prune()
    {:ok, :ok}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    prune()
    schedule_prune()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Drop every entry whose `expires_at` (the 3rd tuple element) is at or before
  # now. Keys and values are arbitrary terms, so the match spec only constrains
  # the timestamp.
  defp prune do
    now = now_ms()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, prune_period_ms())
  end

  defp prune_period_ms do
    Confex.get_env(:bors, :bors_toml_cache_prune_period_ms, 600_000)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
