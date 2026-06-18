defmodule BorsNG.Worker.Batcher.GetBorsToml do
  @moduledoc """
  Get the bors configuration from a repository.
  This will use `bors.toml`, if available,
  or it will attempt to infer it from other files in the repo.
  """

  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.BorsToml
  alias BorsNG.Worker.Batcher.GetBorsToml.Cache

  # Beyond :fetch_failed, get/2 delegates to BorsToml.new and passes through any
  # of its validation errors, so the domain is BorsToml.err() | :fetch_failed.
  @type terror :: BorsToml.err() | :fetch_failed

  @doc """
  Like `get/2`, but memoized per `(repo_xref, branch)` in a short-TTL ETS cache
  (`Cache`).

  Intended for the *reconcile* paths only — the lifecycle `Labeler` and the
  delegation sweep, which re-read the same base-branch config many times. The
  batcher's merge-decision reads must stay on `get/2`: a stale config must never
  drive a merge.

  Both `{:ok, toml}` and `{:error, _}` are cached, errors with a shorter TTL so
  a freshly-added `bors.toml` is picked up promptly. A non-positive
  `:bors_toml_cache_ttl_ms` (the test default) bypasses the cache entirely.
  """
  @spec get_cached(GitHub.tconn(), binary) :: {:ok, BorsToml.t()} | {:error, terror}
  def get_cached({_token, repo_xref} = repo_conn, branch) do
    ttl = Confex.get_env(:bors, :bors_toml_cache_ttl_ms, 120_000)

    if ttl <= 0 do
      get(repo_conn, branch)
    else
      key = {repo_xref, branch}

      case Cache.fetch(key) do
        {:ok, value} ->
          value

        :miss ->
          value = get(repo_conn, branch)
          Cache.put(key, value, entry_ttl(value, ttl))
      end
    end
  end

  # Errors get a shorter TTL than successes so a repo that just gained a
  # `bors.toml` (or fixed a broken one) isn't pinned to the failure for the full
  # success window.
  defp entry_ttl({:ok, _}, ttl), do: ttl
  defp entry_ttl({:error, _}, ttl), do: min(ttl, error_ttl())
  defp error_ttl, do: Confex.get_env(:bors, :bors_toml_cache_error_ttl_ms, 15_000)

  @spec get(GitHub.tconn(), binary) :: {:ok, BorsToml.t()} | {:error, terror}
  def get(repo_conn, branch) do
    toml =
      case GitHub.get_file!(repo_conn, branch, "bors.toml") do
        nil ->
          GitHub.get_file!(repo_conn, branch, ".github/bors.toml")

        toml ->
          toml
      end

    case toml do
      nil ->
        [
          {".travis.yml", "continuous-integration/travis-ci/push"},
          {".appveyor.yml", "continuous-integration/appveyor/branch"},
          {"appveyor.yml", "continuous-integration/appveyor/branch"},
          {"circle.yml", "ci/circleci"},
          {".circleci/config.yml", "ci/circleci%"},
          {"jet-steps.yml", "continuous-integration/codeship"},
          {"jet-steps.json", "continuous-integration/codeship"},
          {"codeship-steps.yml", "continuous-integration/codeship"},
          {"codeship-steps.json", "continuous-integration/codeship"},
          {".semaphore/semaphore.yml", "continuous-integration/semaphoreci"}
        ]
        |> Enum.filter(fn {file, _} ->
          not is_nil(GitHub.get_file!(repo_conn, branch, file))
        end)
        |> Enum.map(fn {_, status} -> status end)
        |> case do
          [] -> {:error, :fetch_failed}
          statuses -> {:ok, %BorsToml{status: statuses}}
        end

      toml ->
        BorsToml.new(toml)
    end
  end
end
