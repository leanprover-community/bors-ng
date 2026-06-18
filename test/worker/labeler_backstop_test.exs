defmodule BorsNG.Worker.LabelerBackstopTest do
  use ExUnit.Case

  alias BorsNG.Database.Batch
  alias BorsNG.Database.Installation
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
  alias BorsNG.Database.UserPatchDelegation
  alias BorsNG.GitHub
  alias BorsNG.Worker.Labeler

  @conn {{:installation, 92}, 21}

  @all_labels ~s"""
  status = ["ci"]
  [labels]
  on_queue = "ready-to-merge"
  building = "bors-staging"
  delegated = "delegated"
  failed = "awaiting-requeue"
  """

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    inst = Repo.insert!(%Installation{installation_xref: 92})

    proj =
      Repo.insert!(%Project{
        installation_id: inst.id,
        repo_xref: 21,
        staging_branch: "staging",
        name: "example/labels"
      })

    user = Repo.insert!(%User{user_xref: 41, login: "alice"})

    patch =
      Repo.insert!(%Patch{
        project_id: proj.id,
        pr_xref: 7,
        commit: "abc",
        into_branch: "master",
        open: true
      })

    {:ok, proj: proj, user: user, patch: patch}
  end

  # Seed the repo's bors.toml (on master) and per-PR labels.
  defp seed(bors_toml, labels) do
    GitHub.ServerMock.put_state(%{
      @conn => %{
        branches: %{},
        comments: %{},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => bors_toml}},
        labels: labels
      }
    })
  end

  defp labels_for(pr) do
    GitHub.ServerMock.get_state() |> get_in([@conn, :labels, pr]) || []
  end

  defp delegate(user, patch) do
    future =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(3600, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.insert!(%UserPatchDelegation{
      user_id: user.id,
      patch_id: patch.id,
      expires_at: future,
      delegated_at_commit: "abc"
    })
  end

  defp link_to_batch(patch, state) do
    batch = Repo.insert!(%{Batch.new(patch.project_id, "master") | state: state})
    Repo.insert!(%LinkPatchBatch{patch_id: patch.id, batch_id: batch.id, reviewer: "alice"})
    batch
  end

  test "removes a stranded delegated label when no delegation is active", %{patch: _patch} do
    seed(@all_labels, %{7 => ["delegated"]})

    Labeler.backstop_sweep()

    refute "delegated" in labels_for(7)
  end

  test "removes a stranded on_queue label when the PR is not queued" do
    seed(@all_labels, %{7 => ["ready-to-merge"]})

    Labeler.backstop_sweep()

    refute "ready-to-merge" in labels_for(7)
  end

  test "adds a missing delegated label (add-gap) when a delegation is active", %{
    user: user,
    patch: patch
  } do
    delegate(user, patch)
    seed(@all_labels, %{7 => []})

    Labeler.backstop_sweep()

    assert "delegated" in labels_for(7)
  end

  test "adds missing queue labels (add-gap) for a running batch", %{patch: patch} do
    link_to_batch(patch, :running)
    seed(@all_labels, %{7 => []})

    Labeler.backstop_sweep()

    labels = labels_for(7)
    assert "ready-to-merge" in labels
    assert "bors-staging" in labels
  end

  test "leaves a stale failed label alone when the PR is not on the queue", %{patch: _patch} do
    # PR carries only awaiting-requeue and is neither queued nor delegated: the
    # undecidable case (genuine limbo vs a missed r-/close clear), left alone.
    seed(@all_labels, %{7 => ["awaiting-requeue"]})

    Labeler.backstop_sweep()

    assert "awaiting-requeue" in labels_for(7)
  end

  test "clears a stale failed label once the PR is back on the queue", %{patch: patch} do
    # A dropped requeue-clear: the PR was re-queued (now on a live batch) but
    # still carries awaiting-requeue. This is the one decidable direction.
    link_to_batch(patch, :waiting)
    seed(@all_labels, %{7 => ["ready-to-merge", "awaiting-requeue"]})

    Labeler.backstop_sweep()

    labels = labels_for(7)
    refute "awaiting-requeue" in labels
    assert "ready-to-merge" in labels
  end

  test "is a no-op when [labels] is unset" do
    seed(~s/status = ["ci"]\n/, %{7 => ["delegated"]})

    Labeler.backstop_sweep()

    # No managed names, so the project is skipped and the label is left alone.
    assert "delegated" in labels_for(7)
  end

  test "never touches a closed/merged PR", %{patch: patch} do
    Repo.update!(Ecto.Changeset.change(patch, open: false))
    seed(@all_labels, %{7 => ["delegated"]})

    Labeler.backstop_sweep()

    # The discovery listing surfaces it (the mock doesn't filter by state), but
    # the open-patch gate means a merged PR's labels stay frozen.
    assert "delegated" in labels_for(7)
  end

  test "writes nothing when labels already match state (diff-based)", %{
    user: user,
    patch: patch
  } do
    delegate(user, patch)
    seed(@all_labels, %{7 => ["delegated"]})

    Labeler.backstop_sweep()

    # Still present exactly once: no spurious add or remove.
    assert labels_for(7) == ["delegated"]
  end
end
