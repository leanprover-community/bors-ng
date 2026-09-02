defmodule BorsNG.Worker.BatcherInterruptedStartTest do
  @moduledoc """
  Regression test for a batch interrupted between `setup_statuses/2` and the
  `:running` commit.

  `start_waiting_batch/1` writes the batch's `Status` rows and only then, after
  deleting `staging.tmp` and posting a commit status per patch, updates the
  batch to `:running`. A batcher that dies in that window (a dyno restart, or
  `delete_branch!` giving up) leaves a `:waiting` batch whose statuses are
  already written.

  That state used to be terminal: every later poll retried the same inserts and
  raised `Ecto.ConstraintError` on `statuses_identifier_batch_id_index`, which
  crashed the batcher, and the registry's crash handler then deleted every
  waiting batch for the project — silently dropping the queue. Starting a batch
  must instead reclaim the leftover rows.
  """
  use BorsNG.Worker.TestCase

  alias BorsNG.Worker.Batcher
  alias BorsNG.Database.Batch
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.Status
  alias BorsNG.GitHub
  alias BorsNG.GitHub.Pr

  setup do
    inst = Repo.insert!(%Installation{installation_xref: 91})

    proj =
      Repo.insert!(%Project{
        name: "project_name",
        installation_id: inst.id,
        repo_xref: 14,
        staging_branch: "staging"
      })

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "staging" => "", "staging.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        statuses: %{"iniN" => %{}},
        files: %{"staging.tmp" => %{"bors.toml" => ~s/status = [ "ci", "cd" ]/}},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Mess",
            state: :open,
            base_ref: "master",
            head_sha: "N",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: false
          }
        },
        pr_commits: %{1 => [%GitHub.Commit{sha: "1234", author_name: "a", author_email: "e"}]}
      }
    })

    patch =
      Repo.insert!(%Patch{project_id: proj.id, pr_xref: 1, commit: "N", into_branch: "master"})

    Batcher.handle_cast({:reviewed, patch.id, "rvr"}, proj.id)
    batch = Repo.get_by!(Batch, project_id: proj.id)
    assert batch.state == :waiting

    {:ok, proj: proj, batch: batch}
  end

  defp identifiers(batch_id) do
    batch_id
    |> Status.all_for_batch()
    |> Repo.all()
    |> Enum.map(& &1.identifier)
    |> Enum.sort()
  end

  defp poll_now(batch, proj) do
    batch
    |> Batch.changeset(%{last_polled: 0})
    |> Repo.update!()

    Batcher.handle_info({:poll, :once}, proj.id)
  end

  test "a waiting batch whose statuses were already written still starts",
       %{proj: proj, batch: batch} do
    # Stand in for the interrupted attempt: the rows are in place, but the
    # batch never reached :running.
    Repo.insert!(%Status{batch_id: batch.id, identifier: "ci", url: nil, state: :running})
    Repo.insert!(%Status{batch_id: batch.id, identifier: "cd", url: nil, state: :error})

    poll_now(batch, proj)

    batch = Repo.get!(Batch, batch.id)
    assert batch.state == :running

    # The stale rows were reclaimed, not duplicated, and the carried-over
    # :error state is gone -- it described a staging commit that no longer
    # exists, and would otherwise fail this batch on its first poll.
    assert identifiers(batch.id) == ["cd", "ci"]

    assert batch.id
           |> Status.all_for_batch()
           |> Repo.all()
           |> Enum.all?(&(&1.state == :running))
  end

  test "a partially written status set still starts", %{proj: proj, batch: batch} do
    # setup_statuses/2 inserted the rows one at a time, so an interruption
    # could also land mid-list.
    Repo.insert!(%Status{batch_id: batch.id, identifier: "ci", url: nil, state: :running})

    poll_now(batch, proj)

    assert Repo.get!(Batch, batch.id).state == :running
    assert identifiers(batch.id) == ["cd", "ci"]
  end

  test "the timeout is armed even when the statuses were already written",
       %{proj: proj, batch: batch} do
    Repo.insert!(%Status{batch_id: batch.id, identifier: "ci", url: nil, state: :running})

    poll_now(batch, proj)

    assert Repo.get!(Batch, batch.id).timeout_at != nil
  end
end
