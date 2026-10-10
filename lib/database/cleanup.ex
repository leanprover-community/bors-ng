defmodule BorsNG.Database.Cleanup do
  @moduledoc """
  Prunes old data: closed batches, closed patches, and crash reports last
  updated more than N months ago, then patch bundles that no patch belongs to.

  It needs only the repo, not Mix, so it runs in a release. In the running
  node:

      bin/bors rpc "BorsNG.Database.Cleanup.run(6)"

  From a source checkout, `mix bors.cleanup --months 6` does the same.
  """

  import Ecto.Query

  require Logger

  alias BorsNG.Database.Batch
  alias BorsNG.Database.Crash
  alias BorsNG.Database.Patch
  alias BorsNG.Database.PatchBundle
  alias BorsNG.Database.Repo

  @type counts :: %{
          batches: non_neg_integer,
          patches: non_neg_integer,
          crashes: non_neg_integer,
          bundles: non_neg_integer
        }

  @doc """
  Deletes data older than `months` months, logs what it deleted, and returns
  the number of rows deleted of each kind.

  `months` must be a positive integer. Anything else raises `ArgumentError`,
  since zero or less would delete every closed batch and patch.
  """
  @spec run(pos_integer) :: counts
  def run(months) when is_integer(months) and months > 0 do
    now = NaiveDateTime.utc_now()
    negative_months = 0 - months

    {batches, _} =
      Repo.delete_all(
        from(b in Batch,
          where:
            b.state in [^:ok, ^:error, ^:canceled] and
              b.updated_at < datetime_add(^now, ^negative_months, "month")
        )
      )

    {patches, _} =
      Repo.delete_all(
        from(p in Patch,
          where:
            not p.open and
              p.updated_at < datetime_add(^now, ^negative_months, "month")
        )
      )

    {crashes, _} =
      Repo.delete_all(
        from(c in Crash,
          where: c.updated_at < datetime_add(^now, ^negative_months, "month")
        )
      )

    # Deleting patches leaves their bundles behind (the membership FK lives
    # on the patch and nilifies): sweep bundles no patch points at anymore.
    {bundles, _} =
      Repo.delete_all(
        from(b in PatchBundle,
          where:
            b.id not in subquery(
              from(p in Patch,
                where: not is_nil(p.bundle_id),
                select: p.bundle_id
              )
            )
        )
      )

    # Under `bin/bors rpc`, this process's group leader is on the calling node,
    # and Logger sends the line there instead of to bors's own log. Log with
    # this node's standard I/O so the line stays here.
    Logger.info(
      "Cleanup of data older than #{months} months deleted batches: #{batches}, " <>
        "patches: #{patches}, crash reports: #{crashes}, " <>
        "patch bundles without patches: #{bundles}",
      gl: Process.whereis(:user) || Process.group_leader()
    )

    %{batches: batches, patches: patches, crashes: crashes, bundles: bundles}
  end

  def run(months) do
    raise ArgumentError, "months must be a positive integer, got: #{inspect(months)}"
  end
end
