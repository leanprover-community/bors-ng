defmodule BorsNG.Worker.BatcherBundleTest do
  use BorsNG.Worker.TestCase

  alias BorsNG.Worker.Batcher
  alias BorsNG.Database.Batch
  alias BorsNG.Database.Installation
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.Database.Patch
  alias BorsNG.Database.PatchBundle
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.GitHub
  alias BorsNG.GitHub.Pr

  import Ecto.Query

  setup do
    inst =
      %Installation{installation_xref: 91}
      |> Repo.insert!()

    proj =
      %Project{
        name: "project_name",
        installation_id: inst.id,
        repo_xref: 14,
        staging_branch: "staging"
      }
      |> Repo.insert!()

    {:ok, inst: inst, proj: proj}
  end

  defp put_plain_state(comments, extra \\ %{}) do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} =>
        Map.merge(
          %{
            branches: %{},
            commits: %{},
            comments: comments,
            statuses: %{},
            files: %{}
          },
          extra
        )
    })
  end

  defp comments_for(pr) do
    GitHub.ServerMock.get_state()
    |> get_in([{{:installation, 91}, 14}, :comments, pr]) || []
  end

  defp insert_patch(proj, xref, params \\ %{}) do
    %Patch{
      project_id: proj.id,
      pr_xref: xref,
      commit: "commit-#{xref}",
      into_branch: "master"
    }
    |> Map.merge(params)
    |> Repo.insert!()
  end

  defp insert_bundle(proj, patches) do
    bundle = Repo.insert!(PatchBundle.new(proj.id))

    patches =
      Enum.map(patches, fn p ->
        p |> Patch.changeset(%{bundle_id: bundle.id}) |> Repo.update!()
      end)

    {bundle, patches}
  end

  describe "bors link / unlink" do
    test "link creates a bundle and comments on every member", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      patch = insert_patch(proj, 1)
      patch2 = insert_patch(proj, 2)

      Batcher.handle_cast({:link, patch.id, [2]}, proj.id)

      patch = Repo.get!(Patch, patch.id)
      patch2 = Repo.get!(Patch, patch2.id)
      assert patch.bundle_id != nil
      assert patch.bundle_id == patch2.bundle_id

      assert [comment] = comments_for(1)
      assert comment =~ "linked bundle: #1, #2"
      assert [_comment] = comments_for(2)
    end

    test "linking an already-bundled patch unions the bundles", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => [], 3 => [], 4 => []})
      [p1, p2, p3, p4] = Enum.map(1..4, &insert_patch(proj, &1))

      Batcher.handle_cast({:link, p1.id, [2]}, proj.id)
      Batcher.handle_cast({:link, p3.id, [4]}, proj.id)
      Batcher.handle_cast({:link, p1.id, [3]}, proj.id)

      bundle_ids =
        [p1, p2, p3, p4]
        |> Enum.map(&Repo.get!(Patch, &1.id).bundle_id)
        |> Enum.uniq()

      assert [bundle_id] = bundle_ids
      assert bundle_id != nil
      assert [%PatchBundle{id: ^bundle_id}] = Repo.all(PatchBundle)

      assert Enum.any?(comments_for(4), &(&1 =~ "#1, #2, #3, #4"))
    end

    test "link is refused for unknown targets", %{proj: proj} do
      put_plain_state(%{1 => []})
      patch = insert_patch(proj, 1)

      Batcher.handle_cast({:link, patch.id, [99]}, proj.id)

      assert Repo.get!(Patch, patch.id).bundle_id == nil
      assert [comment] = comments_for(1)
      assert comment =~ "unknown to bors"
    end

    test "link is refused without another pull request", %{proj: proj} do
      put_plain_state(%{1 => []})
      patch = insert_patch(proj, 1)

      Batcher.handle_cast({:link, patch.id, [1]}, proj.id)

      assert Repo.get!(Patch, patch.id).bundle_id == nil
      assert [comment] = comments_for(1)
      assert comment =~ "Nothing to link"
    end

    test "link is refused across base branches", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      patch = insert_patch(proj, 1)
      _patch2 = insert_patch(proj, 2, %{into_branch: "develop"})

      Batcher.handle_cast({:link, patch.id, [2]}, proj.id)

      assert Repo.get!(Patch, patch.id).bundle_id == nil
      assert [comment] = comments_for(1)
      assert comment =~ "same base branch"
    end

    test "link is refused while a target is queued", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      patch = insert_patch(proj, 1)
      patch2 = insert_patch(proj, 2)

      batch =
        %Batch{project_id: proj.id, state: :waiting, into_branch: "master"}
        |> Repo.insert!()

      %LinkPatchBatch{patch_id: patch2.id, batch_id: batch.id, reviewer: "r"}
      |> Repo.insert!()

      Batcher.handle_cast({:link, patch.id, [2]}, proj.id)

      assert Repo.get!(Patch, patch.id).bundle_id == nil
      assert [comment] = comments_for(1)
      assert comment =~ "queued or running"
    end

    test "unlink dissolves the bundle and clears held approvals", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)
      {bundle, [p1, _p2]} = insert_bundle(proj, [p1, p2])

      p1 |> Patch.changeset(%{bundle_reviewer: "r1"}) |> Repo.update!()

      Batcher.handle_cast({:unlink, p1.id}, proj.id)

      assert Repo.get(PatchBundle, bundle.id) == nil
      p1 = Repo.get!(Patch, p1.id)
      p2 = Repo.get!(Patch, p2.id)
      assert p1.bundle_id == nil and p2.bundle_id == nil
      assert p1.bundle_reviewer == nil
      assert Enum.any?(comments_for(1), &(&1 =~ "no longer linked"))
      assert Enum.any?(comments_for(2), &(&1 =~ "no longer linked"))
    end

    test "unlink is refused while a member is queued", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)
      {bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])

      batch =
        %Batch{project_id: proj.id, state: :waiting, into_branch: "master"}
        |> Repo.insert!()

      Enum.each([p1, p2], fn p ->
        %LinkPatchBatch{patch_id: p.id, batch_id: batch.id, reviewer: "r"}
        |> Repo.insert!()
      end)

      Batcher.handle_cast({:unlink, p1.id}, proj.id)

      assert Repo.get(PatchBundle, bundle.id) != nil
      assert Repo.get!(Patch, p1.id).bundle_id == bundle.id
      assert [comment] = comments_for(1)
      assert comment =~ "queued or running"
    end
  end

  describe "bors stack" do
    test "stack bundles the pair and records the order", %{proj: proj} do
      put_plain_state(
        %{1 => [], 2 => []},
        %{compare_status: %{{"commit-2", "commit-1"} => :ahead}}
      )

      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)

      Batcher.handle_cast({:stack, p1.id, [2]}, proj.id)

      p1 = Repo.get!(Patch, p1.id)
      p2 = Repo.get!(Patch, p2.id)
      assert p1.bundle_id != nil
      assert p1.bundle_id == p2.bundle_id
      assert p1.stacked_on_id == p2.id
      assert p2.stacked_on_id == nil
      assert Enum.any?(comments_for(1), &(&1 =~ "stacked on #2"))
      assert Enum.any?(comments_for(2), &(&1 =~ "stacked on #2"))
      assert Enum.any?(comments_for(1), &(&1 =~ "/compare/commit-2...commit-1"))
    end

    test "stack requires exactly one target", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => [], 3 => []})
      p1 = insert_patch(proj, 1)
      _p2 = insert_patch(proj, 2)
      _p3 = insert_patch(proj, 3)

      Batcher.handle_cast({:stack, p1.id, [2, 3]}, proj.id)

      assert Repo.get!(Patch, p1.id).bundle_id == nil
      assert Enum.any?(comments_for(1), &(&1 =~ "exactly one"))

      # Bare stack with no inferable parent (nothing has head_ref "master").
      Batcher.handle_cast({:stack, p1.id, []}, proj.id)
      assert Enum.any?(comments_for(1), &(&1 =~ "Could not infer"))
    end

    test "bare stack infers the parent from the base-branch chain", %{proj: proj} do
      put_plain_state(
        %{1 => [], 2 => []},
        %{compare_status: %{{"commit-2", "commit-1"} => :ahead}}
      )

      # gh-stack shape: the child's base branch is the parent's head branch.
      p2 = insert_patch(proj, 2, %{head_ref: "feature-a"})
      p1 = insert_patch(proj, 1, %{into_branch: "feature-a", head_ref: "feature-b"})

      Batcher.handle_cast({:stack, p1.id, []}, proj.id)

      p1 = Repo.get!(Patch, p1.id)
      assert p1.stacked_on_id == p2.id
      assert p1.bundle_id != nil
      assert Enum.any?(comments_for(1), &(&1 =~ "stacked on #2"))
    end

    test "bare stack is refused when the chain is ambiguous", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => [], 3 => []})
      _p2 = insert_patch(proj, 2, %{head_ref: "feature-a"})
      _p3 = insert_patch(proj, 3, %{head_ref: "feature-a"})
      p1 = insert_patch(proj, 1, %{into_branch: "feature-a"})

      Batcher.handle_cast({:stack, p1.id, []}, proj.id)

      assert Repo.get!(Patch, p1.id).bundle_id == nil
      assert Enum.any?(comments_for(1), &(&1 =~ "Could not infer"))
    end

    test "explicit stack accepts the gh-stack base shape", %{proj: proj} do
      put_plain_state(
        %{1 => [], 2 => []},
        %{compare_status: %{{"commit-2", "commit-1"} => :ahead}}
      )

      p2 = insert_patch(proj, 2, %{head_ref: "feature-a"})
      p1 = insert_patch(proj, 1, %{into_branch: "feature-a"})

      Batcher.handle_cast({:stack, p1.id, [2]}, proj.id)

      assert Repo.get!(Patch, p1.id).stacked_on_id == p2.id
    end

    test "queueing a gh-stack-shaped bundle retargets the child's base", %{proj: proj} do
      GitHub.ServerMock.put_state(%{
        {{:installation, 91}, 14} => %{
          branches: %{},
          commits: %{},
          comments: %{1 => [], 2 => []},
          statuses: %{},
          files: %{},
          compare_status: %{{"commit-2", "commit-1"} => :ahead},
          pulls: %{
            1 => %Pr{
              number: 1,
              title: "Child",
              body: "Mess",
              state: :open,
              base_ref: "feature-a",
              head_sha: "commit-1",
              head_ref: "feature-b",
              base_repo_id: 14,
              head_repo_id: 14,
              merged: false,
              mergeable: true
            }
          }
        }
      })

      p2 = insert_patch(proj, 2, %{head_ref: "feature-a", bundle_reviewer: "r2"})
      p1 = insert_patch(proj, 1, %{into_branch: "feature-a", head_ref: "feature-b"})
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])
      p1 |> Patch.changeset(%{stacked_on_id: p2.id}) |> Repo.update!()

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)

      assert [batch] = proj.id |> Batch.all_for_project() |> Repo.all()
      assert batch.into_branch == "master"
      assert Repo.get!(Patch, p1.id).into_branch == "master"
      assert Enum.any?(comments_for(1), &(&1 =~ "base branch to `master`"))

      links =
        batch.id
        |> LinkPatchBatch.from_batch()
        |> Repo.all()
        |> Enum.sort_by(& &1.patch.pr_xref)

      assert Enum.map(links, & &1.patch_id) == [p1.id, p2.id]
    end

    test "a failed retarget holds the bundle", %{proj: proj} do
      # No :pulls entry, so the get_pr behind the retarget fails.
      put_plain_state(
        %{1 => [], 2 => []},
        %{compare_status: %{{"commit-2", "commit-1"} => :ahead}}
      )

      p2 = insert_patch(proj, 2, %{head_ref: "feature-a", bundle_reviewer: "r2"})
      p1 = insert_patch(proj, 1, %{into_branch: "feature-a", head_ref: "feature-b"})
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])
      p1 |> Patch.changeset(%{stacked_on_id: p2.id}) |> Repo.update!()

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)

      assert [] == proj.id |> Batch.all_for_project() |> Repo.all()
      assert Repo.get!(Patch, p1.id).bundle_reviewer == "r1"
      assert Enum.any?(comments_for(1), &(&1 =~ "could not change the base branch"))
    end

    test "stack refuses direct and transitive cycles", %{proj: proj} do
      put_plain_state(
        %{1 => [], 2 => [], 3 => []},
        %{
          compare_status: %{
            {"commit-1", "commit-2"} => :ahead,
            {"commit-2", "commit-3"} => :ahead
          }
        }
      )

      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)
      p3 = insert_patch(proj, 3)

      # Chain: p2 on p1, p3 on p2.
      Batcher.handle_cast({:stack, p2.id, [1]}, proj.id)
      Batcher.handle_cast({:stack, p3.id, [2]}, proj.id)

      # Direct cycle: p1 on p2 (but p2 is stacked on p1).
      Batcher.handle_cast({:stack, p1.id, [2]}, proj.id)
      assert Repo.get!(Patch, p1.id).stacked_on_id == nil
      assert Enum.any?(comments_for(1), &(&1 =~ "cycle"))

      # Transitive cycle: p1 on p3 (p3 -> p2 -> p1).
      Batcher.handle_cast({:stack, p1.id, [3]}, proj.id)
      assert Repo.get!(Patch, p1.id).stacked_on_id == nil
    end

    test "stack is refused when the branch is not rebased on the target", %{proj: proj} do
      put_plain_state(
        %{1 => [], 2 => []},
        %{compare_status: %{{"commit-2", "commit-1"} => :diverged}}
      )

      p1 = insert_patch(proj, 1)
      _p2 = insert_patch(proj, 2)

      Batcher.handle_cast({:stack, p1.id, [2]}, proj.id)

      p1 = Repo.get!(Patch, p1.id)
      assert p1.bundle_id == nil
      assert p1.stacked_on_id == nil
      assert Enum.any?(comments_for(1), &(&1 =~ "Rebase it onto #2"))
    end

    test "stack fails closed when ancestry cannot be verified", %{proj: proj} do
      # No :compare_status entry at all: the comparison errors, and the
      # command must refuse rather than assume the stack is fresh.
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1)
      _p2 = insert_patch(proj, 2)

      Batcher.handle_cast({:stack, p1.id, [2]}, proj.id)

      assert Repo.get!(Patch, p1.id).stacked_on_id == nil
      assert Enum.any?(comments_for(1), &(&1 =~ "Rebase it onto #2"))
    end

    test "a stack gone stale holds the bundle at approval time", %{proj: proj} do
      put_plain_state(
        %{1 => [], 2 => []},
        %{compare_status: %{{"commit-2", "commit-1"} => :behind}}
      )

      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2, %{bundle_reviewer: "r2"})
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])
      p1 |> Patch.changeset(%{stacked_on_id: p2.id}) |> Repo.update!()

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)

      assert [] == proj.id |> Batch.all_for_project() |> Repo.all()
      # The approval is held, so a rebase + fresh r+ re-runs the check.
      assert Repo.get!(Patch, p1.id).bundle_reviewer == "r1"
      assert Enum.any?(comments_for(1), &(&1 =~ "was not queued"))
      assert Enum.any?(comments_for(2), &(&1 =~ "was not queued"))
    end

    test "a fresh stack queues normally at approval time", %{proj: proj} do
      put_plain_state(
        %{1 => [], 2 => []},
        %{compare_status: %{{"commit-2", "commit-1"} => :ahead}}
      )

      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2, %{bundle_reviewer: "r2"})
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])
      p1 |> Patch.changeset(%{stacked_on_id: p2.id}) |> Repo.update!()

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)

      assert [batch] = proj.id |> Batch.all_for_project() |> Repo.all()

      links =
        batch.id
        |> LinkPatchBatch.from_batch()
        |> Repo.all()
        |> Enum.sort_by(& &1.patch.pr_xref)

      assert Enum.map(links, & &1.patch_id) == [p1.id, p2.id]
    end

    test "unlink clears the stack edge", %{proj: proj} do
      put_plain_state(
        %{1 => [], 2 => []},
        %{compare_status: %{{"commit-2", "commit-1"} => :ahead}}
      )

      p1 = insert_patch(proj, 1)
      _p2 = insert_patch(proj, 2)

      Batcher.handle_cast({:stack, p1.id, [2]}, proj.id)
      assert Repo.get!(Patch, p1.id).stacked_on_id != nil

      Batcher.handle_cast({:unlink, p1.id}, proj.id)

      p1 = Repo.get!(Patch, p1.id)
      assert p1.bundle_id == nil
      assert p1.stacked_on_id == nil
    end

    test "a stacked bundle merges the parent first despite PR numbers", %{proj: proj} do
      GitHub.ServerMock.put_state(%{
        {{:installation, 91}, 14} => %{
          branches: %{"master" => "ini", "staging" => "", "staging.tmp" => ""},
          commits: %{},
          comments: %{1 => [], 2 => []},
          statuses: %{"iniON" => %{}},
          files: %{"staging.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}},
          pulls: %{
            1 => %Pr{
              number: 1,
              title: "Child",
              body: "Mess",
              state: :open,
              base_ref: "master",
              head_sha: "N",
              head_ref: "update",
              base_repo_id: 14,
              head_repo_id: 14,
              merged: false,
              mergeable: true
            },
            2 => %Pr{
              number: 2,
              title: "Parent",
              body: "Mess",
              state: :open,
              base_ref: "master",
              head_sha: "O",
              head_ref: "update2",
              base_repo_id: 14,
              head_repo_id: 14,
              merged: false,
              mergeable: true
            }
          },
          pr_commits: %{
            1 => [%GitHub.Commit{sha: "1234", author_name: "a", author_email: "e"}],
            2 => [%GitHub.Commit{sha: "5678", author_name: "a", author_email: "e"}]
          }
        }
      })

      # The child PR has the lower number but is stacked on the parent PR,
      # so the parent must merge first.
      p1 = insert_patch(proj, 1, %{commit: "N"})
      p2 = insert_patch(proj, 2, %{commit: "O"})
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])
      p1 |> Patch.changeset(%{stacked_on_id: p2.id}) |> Repo.update!()

      batch =
        %Batch{
          project_id: proj.id,
          state: :waiting,
          into_branch: "master",
          last_polled: 0
        }
        |> Repo.insert!()

      Enum.each([p1, p2], fn p ->
        %LinkPatchBatch{patch_id: p.id, batch_id: batch.id, reviewer: "r"}
        |> Repo.insert!()
      end)

      Batcher.handle_info({:poll, :once}, proj.id)

      assert Repo.get!(Batch, batch.id).state == :running

      state =
        GitHub.ServerMock.get_state()
        |> Map.get({{:installation, 91}, 14})

      staging_sha = state.branches["staging"]
      %{commit_message: message} = state.commits[staging_sha]
      assert message =~ ~r/\AMerge #2 #1/
    end
  end

  describe "bundle approval flow" do
    test "r+ holds until every member is approved, then queues one batch", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)

      assert [] == proj.id |> Batch.all_for_project() |> Repo.all()
      assert Repo.get!(Patch, p1.id).bundle_reviewer == "r1"
      assert [comment] = comments_for(1)
      assert comment =~ "Waiting for approval"
      assert comment =~ "#2"

      Batcher.handle_cast({:reviewed, p2.id, "r2"}, proj.id)

      assert [batch] = proj.id |> Batch.all_for_project() |> Repo.all()
      assert batch.state == :waiting

      links =
        batch.id
        |> LinkPatchBatch.from_batch()
        |> Repo.all()
        |> Enum.sort_by(& &1.patch.pr_xref)

      assert Enum.map(links, & &1.patch_id) == [p1.id, p2.id]
      assert Enum.map(links, & &1.reviewer) == ["r1", "r2"]
    end

    test "the bundle batch takes the highest member priority", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1, %{priority: 5})
      p2 = insert_patch(proj, 2)
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)
      Batcher.handle_cast({:reviewed, p2.id, "r2"}, proj.id)

      assert [batch] = proj.id |> Batch.all_for_project() |> Repo.all()
      assert batch.priority == 5
    end

    test "held approvals persist, so one r+ requeues the whole bundle", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1, %{bundle_reviewer: "r1"})
      p2 = insert_patch(proj, 2, %{bundle_reviewer: "r2"})
      {_bundle, [p1, _p2]} = insert_bundle(proj, [p1, p2])

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)

      assert [batch] = proj.id |> Batch.all_for_project() |> Repo.all()

      links =
        batch.id
        |> LinkPatchBatch.from_batch()
        |> Repo.all()
        |> Enum.sort_by(& &1.patch.pr_xref)

      assert Enum.map(links, & &1.reviewer) == ["r1", "r2"]
    end

    test "a fully-approved bundle holds while a sibling's CI is pending, after retargeting",
         %{proj: proj} do
      toml = ~s/status = [ "ci" ]\npr_status = [ "cn" ]/

      put_plain_state(
        %{1 => [], 2 => []},
        %{
          compare_status: %{{"commit-2", "commit-1"} => :ahead},
          statuses: %{"commit-2" => %{"cn" => :running}},
          files: %{"commit-2" => %{"bors.toml" => toml}},
          pulls: %{
            1 => %Pr{
              number: 1,
              title: "Child",
              body: "Mess",
              state: :open,
              base_ref: "feature-a",
              head_sha: "commit-1",
              head_ref: "feature-b",
              base_repo_id: 14,
              head_repo_id: 14,
              merged: false,
              mergeable: true
            }
          }
        }
      )

      p2 = insert_patch(proj, 2, %{head_ref: "feature-a", bundle_reviewer: "r2"})
      p1 = insert_patch(proj, 1, %{into_branch: "feature-a", head_ref: "feature-b"})
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])
      p1 |> Patch.changeset(%{stacked_on_id: p2.id}) |> Repo.update!()

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)

      # The bundle does not queue, but the retarget has already happened
      # (one-way: it is not undone by the hold).
      assert [] == proj.id |> Batch.all_for_project() |> Repo.all()
      assert Repo.get!(Patch, p1.id).into_branch == "master"

      state = GitHub.ServerMock.get_state()
      assert get_in(state, [{{:installation, 91}, 14}, :pulls, 1]).base_ref == "master"

      assert Enum.any?(comments_for(1), &(&1 =~ "base branch to `master`"))
      assert Enum.any?(comments_for(1), &(&1 =~ "Waiting on #2 before the bundle can queue"))
    end

    test "a fully-approved bundle holds when a sibling fails preflight", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1)

      p2 =
        insert_patch(proj, 2, %{
          bundle_reviewer: "r2",
          title: "[ci skip][skip ci][skip netlify]"
        })

      {_bundle, [p1, _p2]} = insert_bundle(proj, [p1, p2])

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)

      assert [] == proj.id |> Batch.all_for_project() |> Repo.all()
      assert Enum.any?(comments_for(2), &(&1 =~ "CI-skip marker"))
      assert Enum.any?(comments_for(1), &(&1 =~ "Waiting on #2 before the bundle can queue"))
    end

    test "disagreeing root base branches refuse the bundle at activation", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2, %{into_branch: "develop", bundle_reviewer: "r2"})
      {_bundle, [p1, _p2]} = insert_bundle(proj, [p1, p2])

      Batcher.handle_cast({:reviewed, p1.id, "r1"}, proj.id)

      assert [] == proj.id |> Batch.all_for_project() |> Repo.all()
      assert Enum.any?(comments_for(1), &(&1 =~ "must target the same base branch"))
      assert Enum.any?(comments_for(2), &(&1 =~ "must target the same base branch"))
    end

    test "r- clears this member's held approval", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1, %{bundle_reviewer: "r1"})
      p2 = insert_patch(proj, 2)
      {_bundle, [p1, _p2]} = insert_bundle(proj, [p1, p2])

      Batcher.handle_cast({:cancel, p1.id, :requested}, proj.id)

      assert Repo.get!(Patch, p1.id).bundle_reviewer == nil

      # The other member approving still holds the bundle.
      Batcher.handle_cast({:reviewed, p2.id, "r2"}, proj.id)
      assert [] == proj.id |> Batch.all_for_project() |> Repo.all()
    end
  end

  describe "bundle cancellation" do
    test "canceling one member pulls the bundle from a waiting batch", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => [], 3 => []})
      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)
      p3 = insert_patch(proj, 3)
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])

      batch =
        %Batch{project_id: proj.id, state: :waiting, into_branch: "master"}
        |> Repo.insert!()

      [link1, link2, link3] =
        Enum.map([p1, p2, p3], fn p ->
          %LinkPatchBatch{patch_id: p.id, batch_id: batch.id, reviewer: "r"}
          |> Repo.insert!()
        end)

      Batcher.handle_cast({:cancel, p1.id, :requested}, proj.id)

      assert Repo.get(LinkPatchBatch, link1.id) == nil
      assert Repo.get(LinkPatchBatch, link2.id) == nil
      assert Repo.get(LinkPatchBatch, link3.id) != nil
      assert Repo.get!(Batch, batch.id).state == :waiting

      assert Enum.any?(comments_for(1), &(&1 =~ "Bors build canceled"))
      assert Enum.any?(comments_for(2), &(&1 =~ "linked with #1"))
      assert comments_for(3) == []
    end

    test "canceling one member of a running batch fails the bundle and retries the rest",
         %{proj: proj} do
      put_plain_state(%{1 => [], 2 => [], 3 => []})
      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)
      p3 = insert_patch(proj, 3)
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])

      batch =
        %Batch{project_id: proj.id, state: :running, into_branch: "master"}
        |> Repo.insert!()

      Enum.each([p1, p2, p3], fn p ->
        %LinkPatchBatch{patch_id: p.id, batch_id: batch.id, reviewer: "r"}
        |> Repo.insert!()
      end)

      Batcher.handle_cast({:cancel, p1.id, :push}, proj.id)

      assert Repo.get!(Batch, batch.id).state == :canceled

      new_links =
        Repo.all(from(l in LinkPatchBatch, where: l.batch_id != ^batch.id))

      assert Enum.map(new_links, & &1.patch_id) == [p3.id]

      assert Enum.any?(comments_for(1), &(&1 =~ "canceled because the PR branch was pushed to"))
      assert Enum.any?(comments_for(2), &(&1 =~ "linked with #1, which was pushed to"))
      assert Enum.any?(comments_for(3), &(&1 =~ "will be automatically retried"))
    end

    test "canceling a member of a bundle-only running batch fails everything", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])

      batch =
        %Batch{project_id: proj.id, state: :running, into_branch: "master"}
        |> Repo.insert!()

      Enum.each([p1, p2], fn p ->
        %LinkPatchBatch{patch_id: p.id, batch_id: batch.id, reviewer: "r"}
        |> Repo.insert!()
      end)

      Batcher.handle_cast({:cancel, p1.id, :requested}, proj.id)

      assert Repo.get!(Batch, batch.id).state == :canceled
      assert [] == Repo.all(from(l in LinkPatchBatch, where: l.batch_id != ^batch.id))
      assert Enum.any?(comments_for(1), &(&1 =~ "Bors build canceled"))
      assert Enum.any?(comments_for(2), &(&1 =~ "linked with #1"))
    end
  end

  describe "bundle batch start" do
    test "a closed member pulls its whole bundle when the batch starts", %{proj: proj} do
      GitHub.ServerMock.put_state(%{
        {{:installation, 91}, 14} => %{
          branches: %{"master" => "ini", "staging" => "", "staging.tmp" => ""},
          commits: %{},
          comments: %{1 => [], 2 => [], 3 => []},
          statuses: %{"inicommit-3" => %{}},
          files: %{"staging.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}},
          pulls: %{
            3 => %Pr{
              number: 3,
              title: "Test",
              body: "Mess",
              state: :open,
              base_ref: "master",
              head_sha: "commit-3",
              head_ref: "update",
              base_repo_id: 14,
              head_repo_id: 14,
              merged: false,
              mergeable: true
            }
          },
          pr_commits: %{
            3 => [
              %GitHub.Commit{sha: "1234", author_name: "a", author_email: "e"}
            ]
          }
        }
      })

      p1 = insert_patch(proj, 1, %{open: false})
      p2 = insert_patch(proj, 2)
      p3 = insert_patch(proj, 3)
      {_bundle, [p1, p2]} = insert_bundle(proj, [p1, p2])

      batch =
        %Batch{
          project_id: proj.id,
          state: :waiting,
          into_branch: "master",
          last_polled: 0
        }
        |> Repo.insert!()

      [link1, link2, link3] =
        Enum.map([p1, p2, p3], fn p ->
          %LinkPatchBatch{patch_id: p.id, batch_id: batch.id, reviewer: "r"}
          |> Repo.insert!()
        end)

      Batcher.handle_info({:poll, :once}, proj.id)

      assert Repo.get(LinkPatchBatch, link1.id) == nil
      assert Repo.get(LinkPatchBatch, link2.id) == nil
      assert Repo.get(LinkPatchBatch, link3.id) != nil
      assert Repo.get!(Batch, batch.id).state == :running

      assert Enum.any?(comments_for(2), &(&1 =~ "linked with #1, which was closed"))
    end
  end

  describe "bundle-wide settings" do
    test "set_priority propagates to the whole bundle", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)
      {_bundle, [p1, _p2]} = insert_bundle(proj, [p1, p2])

      Batcher.handle_call({:set_priority, p1.id, 7}, nil, proj.id)

      assert Repo.get!(Patch, p1.id).priority == 7
      assert Repo.get!(Patch, p2.id).priority == 7
    end

    test "set_is_single propagates to the whole bundle", %{proj: proj} do
      put_plain_state(%{1 => [], 2 => []})
      p1 = insert_patch(proj, 1)
      p2 = insert_patch(proj, 2)
      {_bundle, [p1, _p2]} = insert_bundle(proj, [p1, p2])

      Batcher.handle_call({:set_is_single, p1.id, true}, nil, proj.id)

      assert Repo.get!(Patch, p1.id).is_single == true
      assert Repo.get!(Patch, p2.id).is_single == true
    end
  end

  describe "get_new_batch capacity" do
    test "a bundle only joins a batch it entirely fits into", %{proj: proj} do
      patch = insert_patch(proj, 1)

      batch =
        %Batch{project_id: proj.id, state: :waiting, into_branch: "master", priority: 0}
        |> Repo.insert!()

      %LinkPatchBatch{patch_id: patch.id, batch_id: batch.id, reviewer: "r"}
      |> Repo.insert!()

      # One slot left (max 2): a solo patch fits...
      {found, false} = Batcher.get_new_batch(2, proj.id, "master", 0, false, 1)
      assert found.id == batch.id

      # ...but a bundle of two does not; it gets a fresh batch.
      {fresh, true} = Batcher.get_new_batch(2, proj.id, "master", 0, false, 2)
      assert fresh.id != batch.id
    end
  end
end
