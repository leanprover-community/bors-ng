defmodule BorsNG.Worker.Batcher.GetBorsTomlCacheTest do
  use ExUnit.Case

  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.GetBorsToml
  alias BorsNG.Worker.Batcher.GetBorsToml.Cache

  @conn {{:installation, 93}, 31}

  setup do
    # The global test config disables the cache (ttl 0). Start each test from a
    # clean table and restore the configured ttl afterwards; the get_cached/2
    # tests opt back into a real ttl as needed.
    :ets.delete_all_objects(Cache.table())
    prev = Application.get_env(:bors, :bors_toml_cache_ttl_ms)
    on_exit(fn -> Application.put_env(:bors, :bors_toml_cache_ttl_ms, prev) end)
    :ok
  end

  defp put_toml(contents) do
    GitHub.ServerMock.put_state(%{
      @conn => %{files: %{"master" => %{"bors.toml" => contents}}}
    })
  end

  describe "Cache (ETS)" do
    test "put then fetch returns the value while fresh" do
      key = {:fresh, make_ref()}
      assert {:ok, :sentinel} = Cache.put(key, {:ok, :sentinel}, 60_000)
      assert {:ok, {:ok, :sentinel}} = Cache.fetch(key)
    end

    test "fetch misses an expired entry" do
      key = {:expired, make_ref()}
      Cache.put(key, {:ok, :sentinel}, 0)
      assert :miss = Cache.fetch(key)
    end

    test "fetch misses an absent key" do
      assert :miss = Cache.fetch({:absent, make_ref()})
    end
  end

  describe "get_cached/2" do
    test "serves the cached toml even after the source changes (within ttl)" do
      Application.put_env(:bors, :bors_toml_cache_ttl_ms, 60_000)
      put_toml(~s/status = ["ci"]\n/)

      assert {:ok, first} = GetBorsToml.get_cached(@conn, "master")
      assert first.status == ["ci"]

      # The source changes, but the cached value is still within its ttl.
      put_toml(~s/status = ["changed"]\n/)
      assert {:ok, cached} = GetBorsToml.get_cached(@conn, "master")
      assert cached.status == ["ci"]
    end

    test "a non-positive ttl bypasses the cache and always reads fresh" do
      Application.put_env(:bors, :bors_toml_cache_ttl_ms, 0)
      put_toml(~s/status = ["ci"]\n/)
      assert {:ok, first} = GetBorsToml.get_cached(@conn, "master")
      assert first.status == ["ci"]

      put_toml(~s/status = ["fresh"]\n/)
      assert {:ok, second} = GetBorsToml.get_cached(@conn, "master")
      assert second.status == ["fresh"]
    end

    test "caches errors too" do
      Application.put_env(:bors, :bors_toml_cache_ttl_ms, 60_000)
      # No bors.toml and no CI config files => fetch_failed.
      GitHub.ServerMock.put_state(%{@conn => %{files: %{"master" => %{}}}})

      assert {:error, _} = GetBorsToml.get_cached(@conn, "master")

      # A valid toml now exists, but the cached error is still served.
      put_toml(~s/status = ["ci"]\n/)
      assert {:error, _} = GetBorsToml.get_cached(@conn, "master")
    end
  end
end
