defmodule Mix.Tasks.Bors.Cleanup do
  use Mix.Task
  import Mix.Ecto
  import Ecto.Query

  require Logger

  @requirements ["app.start"]

  @shortdoc "Prune old batches, patches, and crash reports"

  @moduledoc """
  Maintenance task: deletes closed batches, patches, and crash reports older
  than N months.

  Delegation lifecycle (expiry, warnings, and default backfill) is no longer
  handled here. Expiry and warning notifications run continuously in
  `BorsNG.Worker.DelegationTimer`, and default-expiry backfill happens when
  bors reads a project's `bors.toml`.

  ## Examples
      mix bors.cleanup --months 6

  ## Command line options
    * `--months` - integer; delete batches/patches/crashes older than this
  """

  @doc false
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [months: :integer])

    Enum.each(repos(), fn repo ->
      ensure_repo(repo, args)

      case opts do
        [months: months] when is_integer(months) ->
          Mix.shell().info("Cleaning data older than #{inspect(months)} months")
          run_age_pass(months)

        _ ->
          Mix.shell().info("Nothing to do; pass --months N to prune old data")
      end
    end)
  end

  def repos, do: [BorsNG.Application.fetch_repo()]

  defp run_age_pass(months) do
    negative_months = 0 - months

    BorsNG.Database.Repo.delete_all(
      from(p in BorsNG.Database.Batch,
        where:
          p.state in [^:ok, ^:error, ^:canceled] and
            p.updated_at < datetime_add(^NaiveDateTime.utc_now(), ^negative_months, "month")
      )
    )

    BorsNG.Database.Repo.delete_all(
      from(p in BorsNG.Database.Patch,
        where:
          not p.open and
            p.updated_at < datetime_add(^NaiveDateTime.utc_now(), ^negative_months, "month")
      )
    )

    BorsNG.Database.Repo.delete_all(
      from(p in BorsNG.Database.Crash,
        where: p.updated_at < datetime_add(^NaiveDateTime.utc_now(), ^negative_months, "month")
      )
    )
  end
end
