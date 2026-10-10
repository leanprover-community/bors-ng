defmodule Mix.Tasks.Bors.Cleanup do
  use Mix.Task
  import Mix.Ecto

  @requirements ["app.start"]

  @shortdoc "Prune old batches, patches, and crash reports"

  @moduledoc """
  Maintenance task: deletes closed batches, patches, and crash reports older
  than N months, and patch bundles left without patches.

  This is a wrapper around `BorsNG.Database.Cleanup.run/1`. A release has no
  Mix, so there, call that in the running node instead:

      bin/bors rpc "BorsNG.Database.Cleanup.run(6)"

  Delegation lifecycle (expiry, warnings, and default backfill) is no longer
  handled here. Expiry and warning notifications run continuously in
  `BorsNG.Worker.DelegationTimer`, and default-expiry backfill happens when
  bors reads a project's `bors.toml`.

  ## Examples
      mix bors.cleanup --months 6

  ## Command line options
    * `--months` - positive integer; delete batches/patches/crashes older than this
  """

  @doc false
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [months: :integer])

    Enum.each(repos(), fn repo ->
      ensure_repo(repo, args)

      case opts do
        [months: months] when is_integer(months) and months > 0 ->
          Mix.shell().info("Cleaning data older than #{inspect(months)} months")
          BorsNG.Database.Cleanup.run(months)

        [months: months] when is_integer(months) ->
          Mix.raise("--months must be a positive integer, got: #{months}")

        _ ->
          Mix.shell().info("Nothing to do; pass --months N to prune old data")
      end
    end)
  end

  def repos, do: [BorsNG.Application.fetch_repo()]
end
