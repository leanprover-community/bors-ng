require Logger

defmodule BorsNG.Worker.Batcher do
  @moduledoc """
  A "Batcher" manages the backlog of batches a project has.
  It implements this set of rules:

    * When a patch is reviewed ("r+'ed"),
      it gets added to the project's non-running batch.
      If no such batch exists, it creates it.
    * After a short delay, if there is no currently running batch,
      the project's non-running batch is started.
    * The project's CI is occasionally polled,
      if a batch is currently running.
      After polling, the completion logic is run.
    * If a notification related to the underlying CI is received,
      the completion logic is run.
    * When the completion logic is run, the batch is either
      bisected (if it failed and there are two or more patches in it),
      blocked (if it failed and there is only one patch in it),
      pushed to master (if it passed),
      or (if there are still CI jobs with no results) it is left alone.
  """

  use GenServer
  alias BorsNG.Database.Context.Delegation
  alias BorsNG.Worker.Batcher
  alias BorsNG.Worker.Batcher.Bundles
  alias BorsNG.Worker.Batcher.Divider
  alias BorsNG.Worker.Labeler
  alias BorsNG.Worker.Zulip
  alias BorsNG.Database.Repo
  alias BorsNG.Database.Batch
  alias BorsNG.Database.BatchState
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Status
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.GitHub
  alias BorsNG.Endpoint
  import BorsNG.Router.Helpers
  import Ecto.Query

  @prerun_poll_period 1 * 60 * 1000

  @type batch_state :: :waiting | :running | :ok | :error | :conflict | :canceled

  # Public API

  def start_link(project_id) do
    GenServer.start_link(__MODULE__, project_id)
  end

  def reviewed(pid, patch_id, reviewer) when is_integer(patch_id) do
    GenServer.cast(pid, {:reviewed, patch_id, reviewer})
  end

  def set_is_single(pid, patch_id, is_single) when is_integer(patch_id) do
    GenServer.call(pid, {:set_is_single, patch_id, is_single})
  end

  def set_priority(pid, patch_id, priority) when is_integer(patch_id) do
    GenServer.call(pid, {:set_priority, patch_id, priority})
  end

  def status(pid, stat) do
    GenServer.cast(pid, {:status, stat})
  end

  def poll(pid) do
    send(pid, {:poll, :once})
  end

  def cancel(pid, patch_id, reason \\ :requested) when is_integer(patch_id) do
    GenServer.cast(pid, {:cancel, patch_id, reason})
  end

  def cancel_all(pid) do
    GenServer.cast(pid, {:cancel_all})
  end

  def link(pid, patch_id, pr_xrefs) when is_integer(patch_id) do
    GenServer.cast(pid, {:link, patch_id, pr_xrefs})
  end

  def stack(pid, patch_id, pr_xrefs) when is_integer(patch_id) do
    GenServer.cast(pid, {:stack, patch_id, pr_xrefs})
  end

  def unlink(pid, patch_id) when is_integer(patch_id) do
    GenServer.cast(pid, {:unlink, patch_id})
  end

  # Server callbacks

  def init(project_id) do
    BorsNG.Worker.Batcher.Registry.monitor(self(), project_id)

    Process.send_after(
      self(),
      {:poll, :repeat},
      trunc(Confex.fetch_env!(:bors, :poll_period) * :rand.uniform(2) * 0.5)
    )

    {:ok, project_id}
  end

  def handle_cast(args, project_id) do
    check_self(project_id)
    do_handle_cast(args, project_id)
    {:noreply, project_id}
  end

  def handle_call({:set_is_single, patch_id, is_single}, _from, project_id) do
    case Repo.get(Patch, patch_id) do
      nil ->
        nil

      %{is_single: ^is_single} ->
        nil

      patch ->
        # Linked patches batch as one unit, so `single` only means something
        # applied to the whole bundle.
        patch
        |> Bundles.members_or_self()
        |> Enum.each(fn p ->
          p
          |> Patch.changeset(%{is_single: is_single})
          |> Repo.update!()
        end)
    end

    {:reply, :ok, project_id}
  end

  def handle_call({:set_priority, patch_id, priority}, _from, project_id) do
    check_self(project_id)

    case Repo.get(Patch, patch_id) do
      nil ->
        nil

      %{priority: ^priority} ->
        nil

      patch ->
        patch.id
        |> Batch.all_for_patch(:incomplete)
        |> Repo.one()
        |> raise_batch_priority(priority)

        # Linked patches enter the queue at one priority, so a change to one
        # member applies to the whole bundle.
        patch
        |> Bundles.members_or_self()
        |> Enum.each(fn p ->
          p
          |> Patch.changeset(%{priority: priority})
          |> Repo.update!()
        end)

        Project.ping!(project_id)
    end

    {:reply, :ok, project_id}
  end

  def do_handle_cast({:reviewed, patch_id, reviewer}, _project_id) do
    case Repo.get(Patch.all(:awaiting_review), patch_id) do
      nil ->
        # Patch exists (otherwise, no ID), but is not awaiting review
        patch = Repo.get!(Patch, patch_id)
        project = Repo.get!(Project, patch.project_id)

        project
        |> get_repo_conn()
        |> send_message([patch], :already_running_review)

      patch ->
        # Patch exists and is awaiting review
        # This will cause the PR to run after the patch's scheduled delay
        # if all other conditions are met. It will poll if all conditions
        # except CI are met and those CI are :waiting.
        project = Repo.get!(Project, patch.project_id)
        repo_conn = get_repo_conn(project)

        case patch_preflight(repo_conn, patch) do
          {:ok, max_batch_size} ->
            activate(reviewer, patch, max_batch_size)

          {:waiting, toml} ->
            handle_waiting_preflight(repo_conn, reviewer, patch, 0, toml)

          :waiting ->
            handle_waiting_preflight(repo_conn, reviewer, patch, 0)

          {:error, message} ->
            send_message(repo_conn, [patch], {:preflight, message})
        end
    end
  end

  def do_handle_cast({:status, {commit, identifier, state, url}}, project_id) do
    project_id
    |> Batch.get_assoc_by_commit(commit)
    |> Repo.all()
    |> case do
      [batch] ->
        batch.id
        |> Status.get_for_batch(identifier)
        |> Repo.update_all(set: [state: state, url: url, identifier: identifier])

        if batch.state == :running do
          maybe_complete_batch(batch)
        end

      [] ->
        :ok
    end
  end

  def do_handle_cast({:cancel, patch_id, reason}, _project_id) do
    # A bundled patch may hold an approval while waiting for its siblings;
    # canceling (r-, close, or a new push) revokes it, so re-queueing the
    # bundle needs a fresh r+ on this member.
    Bundles.drop_held_approval(patch_id)

    patch_id
    |> Batch.all_for_patch(:incomplete)
    |> Repo.one()
    |> cancel_patch(patch_id, reason)
  end

  # Backwards compatibility for any in-flight 2-tuple casts (e.g. across a deploy).
  def do_handle_cast({:cancel, patch_id}, project_id) do
    do_handle_cast({:cancel, patch_id, :requested}, project_id)
  end

  def do_handle_cast({:cancel_all}, project_id) do
    waiting =
      project_id
      |> Batch.all_for_project(:waiting)
      |> Repo.all()

    running =
      project_id
      |> Batch.all_for_project(:running)
      |> Repo.all()

    # Capture each batch's patches (with its base branch) before mutating —
    # deleting a waiting batch removes its patch links — so the labels can be
    # reconciled off the queue at the end.
    affected =
      Enum.map(waiting ++ running, fn b ->
        {b.into_branch, b.id |> Patch.all_for_batch() |> Repo.all()}
      end)

    Enum.each(waiting, &Repo.delete!/1)

    Enum.map(running, &Batch.changeset(&1, %{state: :canceled}))
    |> Enum.each(&Repo.update!/1)

    Enum.each(running, &send_zulip(&1, :canceled))

    repo_conn =
      Project
      |> Repo.get!(project_id)
      |> get_repo_conn()

    Enum.each(running, &send_status(repo_conn, &1, :canceled))
    Enum.each(waiting, &send_status(repo_conn, &1, :canceled))

    Enum.each(affected, fn {branch, patches} ->
      Labeler.reconcile_queue(repo_conn, branch, patches)
    end)
  end

  def do_handle_cast({:link, patch_id, pr_xrefs}, project_id) do
    patch = Repo.get!(Patch, patch_id)
    project = Repo.get!(Project, project_id)
    repo_conn = get_repo_conn(project)

    case Bundles.validate_link(patch, pr_xrefs, project_id) do
      {:error, reason} ->
        send_message(repo_conn, [patch], {:link_error, reason})

      {:ok, members} ->
        members = Bundles.form(members, project_id)
        xrefs = members |> Enum.map(& &1.pr_xref) |> Enum.sort()
        send_message(repo_conn, members, {:linked, xrefs})
    end
  end

  def do_handle_cast({:stack, patch_id, pr_xrefs}, project_id) do
    patch = Repo.get!(Patch, patch_id)
    project = Repo.get!(Project, project_id)
    repo_conn = get_repo_conn(project)

    target_xrefs =
      pr_xrefs
      |> Enum.uniq()
      |> Enum.reject(&(&1 == patch.pr_xref))

    case {pr_xrefs, target_xrefs} do
      {[], []} ->
        # Bare `bors stack`: infer the parent from the base-branch chain
        # (gh-stack convention: a stacked PR's base is its parent's branch).
        case Bundles.infer_stack_parent(patch, project_id) do
          {:ok, parent} ->
            do_stack(repo_conn, patch, parent.pr_xref, project)

          :error ->
            send_message(repo_conn, [patch], {:link_error, :cannot_infer})
        end

      {_, []} ->
        # Only this pull request's own number was given: refuse, so a typo
        # is not read as the bare, inferring form.
        send_message(repo_conn, [patch], {:link_error, :self_stack})

      {_, [target_xref]} ->
        do_stack(repo_conn, patch, target_xref, project)

      _ ->
        send_message(repo_conn, [patch], {:link_error, :stack_usage})
    end
  end

  def do_handle_cast({:unlink, patch_id}, project_id) do
    patch = Repo.get!(Patch, patch_id)

    case patch.bundle_id do
      nil ->
        :ok

      bundle_id ->
        project = Repo.get!(Project, project_id)
        repo_conn = get_repo_conn(project)

        # Read the members before dissolving: dissolve clears the
        # retargeted_from bookkeeping the base restore needs.
        members = Bundles.members(bundle_id)

        case Bundles.dissolve(bundle_id) do
          {:error, :in_batch} ->
            send_message(repo_conn, [patch], {:link_error, :in_batch})

          {:ok, _} ->
            # A member that held an approval for the bundle lost it in the
            # dissolve; unlike its siblings, it will not merge without a
            # fresh r+, so it gets told.
            {held, rest} = Enum.split_with(members, &(&1.bundle_reviewer != nil))
            send_message(repo_conn, rest, :unlinked)
            send_message(repo_conn, held, {:unlinked, :fresh_approval_needed})
            restore_retargeted_bases(repo_conn, members)
        end
    end
  end

  def handle_info({:poll, repetition}, project_id) do
    check_self(project_id)

    if repetition != :once do
      Process.send_after(self(), {:poll, repetition}, Confex.fetch_env!(:bors, :poll_period))
    end

    case poll_(project_id) do
      :stop ->
        {:stop, :normal, project_id}

      :again ->
        {:noreply, project_id}
    end
  end

  def handle_info({:prerun_poll, try_num, args}, proj_id) do
    check_self(proj_id)
    {reviewer, patch} = args

    Logger.info("Continue Poll Patch #{patch.id} prerun")

    project = Repo.get(Project, patch.project_id)
    repo_conn = get_repo_conn(project)

    case Repo.get(Patch.all(:awaiting_review), patch.id) do
      nil ->
        send_message(repo_conn, [patch], {:preflight, :duplicate})
        Logger.info("Patch #{patch.id} already left prerun, exiting prerun poll loop")

      # The struct captured when the poll was scheduled is stale: the patch
      # may have been bundled, retargeted, or pushed to since. Activate with
      # the current row, not the snapshot.
      patch ->
        case patch_preflight(repo_conn, patch) do
          {:ok, max_batch_size} ->
            case resolve_prerun_reviewer(reviewer, patch) do
              nil ->
                Logger.info("Patch #{patch.id} no longer holds an approval, exiting prerun poll")

              resolved ->
                activate(resolved, patch, max_batch_size)
            end

          {:waiting, toml} ->
            handle_waiting_preflight(repo_conn, reviewer, patch, try_num, toml)

          :waiting ->
            handle_waiting_preflight(repo_conn, reviewer, patch, try_num)

          {:error, message} ->
            send_message(repo_conn, [patch], {:preflight, message})
        end
    end

    {:noreply, proj_id}
  end

  # Private implementation details

  defp poll_(project_id) do
    project = Repo.get(Project, project_id)

    incomplete =
      project_id
      |> Batch.all_for_project(:incomplete)
      |> Repo.all()

    incomplete
    |> Enum.map(&%Batch{&1 | project: project})
    |> sort_batches()
    |> poll_batches()

    if Enum.empty?(incomplete) do
      :stop
    else
      :again
    end
  end

  defp run(reviewer, patch, max_batch_size) do
    project = Repo.get!(Project, patch.project_id)
    repo_conn = get_repo_conn(project)

    {batch, is_new_batch} =
      get_new_batch(
        max_batch_size,
        patch.project_id,
        patch.into_branch,
        patch.priority,
        patch.is_single
      )

    %LinkPatchBatch{}
    |> LinkPatchBatch.changeset(%{
      batch_id: batch.id,
      patch_id: patch.id,
      reviewer: reviewer
    })
    |> Repo.insert!()

    # The patch is now on the queue (a :waiting batch); reflect that in the
    # labels. This also clears any lingering `awaiting-requeue` from a previous
    # failed build, since the PR has been put back on the queue.
    Labeler.reconcile_queue(repo_conn, patch.into_branch, [patch])

    Project.ping!(project.id)

    if is_new_batch do
      put_incomplete_on_hold(repo_conn, batch)
    end

    poll_after_delay(project)
    # Maybe not needed because bors adds a commit referencing this.
    # send_message(repo_conn, [patch], {:preflight, :ok})
    send_status(repo_conn, batch.id, [patch], :waiting)
  end

  # A reviewed patch that passed its own preflight enters the queue here. An
  # unbundled patch is queued directly (run/3, the upstream path); a bundled
  # one holds its approval on the patch row until every member of the bundle
  # is approved, then all members enter the same batch together (run_bundle/3).
  defp activate(reviewer, patch, max_batch_size) do
    case patch.bundle_id do
      nil ->
        run(reviewer, patch, max_batch_size)

      bundle_id ->
        patch = Bundles.hold_approval(patch, reviewer)
        activate_bundle(patch, bundle_id, max_batch_size)
    end
  end

  defp activate_bundle(patch, bundle_id, max_batch_size) do
    project = Repo.get!(Project, patch.project_id)
    repo_conn = get_repo_conn(project)

    members = Bundles.members(bundle_id)
    pending = Bundles.unapproved(members)

    cond do
      pending != [] ->
        announce_bundle_waiting(repo_conn, patch, pending)

      (stale = Bundles.stale_stack_pair(repo_conn, members)) != nil ->
        # A stacked branch went stale (its parent was amended after it was
        # stacked, or a webhook was missed): hold the bundle rather than
        # merge stale content. Held approvals survive; rebasing the child
        # clears its approval via the push webhook, and a fresh r+ re-runs
        # this check.
        {child, parent} = stale
        send_message(repo_conn, members, {:stack_stale, child.pr_xref, parent.pr_xref})

      true ->
        # Everything is approved and fresh: normalize gh-stack-shaped bases
        # onto the final branch, then preflight the rest of the bundle (the
        # current patch already passed its own preflight).
        case normalize_bundle_bases(repo_conn, members) do
          {:error, :branch_mismatch} ->
            send_message(repo_conn, members, {:link_error, :branch_mismatch})

          {:error, xref} when is_integer(xref) ->
            send_message(repo_conn, members, {:stack_retarget_failed, xref})

          {:ok, members} ->
            activate_bundle_preflight(repo_conn, project, patch, members, max_batch_size)
        end
    end
  end

  # Tell the approver what the bundle still waits on, and — when exactly
  # one member is left — tell that member it alone holds the bundle, with
  # what to do about it.
  defp announce_bundle_waiting(repo_conn, patch, pending) do
    others = Enum.reject(pending, &(&1.id == patch.id))

    if others != [] do
      send_message(repo_conn, [patch], {:bundle_waiting, Enum.map(others, & &1.pr_xref)})
    end

    case pending do
      [last] ->
        send_message(repo_conn, [last], {:bundle_last_unapproved, approval_blocker(last)})

      _ ->
        :ok
    end
  end

  defp approval_blocker(%Patch{open: false}), do: :closed
  defp approval_blocker(%Patch{is_draft: true}), do: :draft
  defp approval_blocker(_), do: :awaiting_review

  defp activate_bundle_preflight(repo_conn, project, patch, members, max_batch_size) do
    others = Enum.reject(members, &(&1.id == patch.id))

    case bundle_preflight(repo_conn, others) do
      :ok ->
        run_bundle(project, members, max_batch_size)

      {:waiting, failed, toml} ->
        # That member's statuses are still pending; its prerun poll loop
        # re-enters activate/3 once they settle, and the held approvals
        # make this whole check idempotent. The poll carries a marker, not
        # the reviewer's name, so it picks up the approval as it stands
        # when it fires (see resolve_prerun_reviewer/2).
        handle_waiting_preflight(repo_conn, :held_approval, failed, 0, toml)

        repo_conn
        |> send_message(
          Enum.reject(members, &(&1.id == failed.id)),
          {:bundle_held, failed.pr_xref}
        )

      {:error, message, failed} ->
        send_message(repo_conn, [failed], {:preflight, message})

        repo_conn
        |> send_message(
          Enum.reject(members, &(&1.id == failed.id)),
          {:bundle_held, failed.pr_xref}
        )
    end
  end

  # Bring every member's base branch onto the bundle's final target before
  # queueing; members still in gh-stack shape (base = parent's branch) are
  # retargeted via the GitHub API. Fails closed: any API failure holds the
  # bundle. While the bundle exists the move is not undone — the stored
  # stack edges still order any future merge — but the original base is
  # recorded so that dissolving the bundle can restore it
  # (restore_retargeted_bases/2).
  defp normalize_bundle_bases(repo_conn, members) do
    case Bundles.final_target(members) do
      {:ok, final} ->
        members
        |> Enum.reduce_while({:ok, []}, fn p, {:ok, acc} ->
          case retarget_patch(repo_conn, p, final) do
            {:ok, p} -> {:cont, {:ok, [p | acc]}}
            :error -> {:halt, {:error, p.pr_xref}}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          error -> error
        end

      {:error, :branch_mismatch} = error ->
        error
    end
  end

  defp retarget_patch(_repo_conn, %Patch{into_branch: final} = patch, final), do: {:ok, patch}

  defp retarget_patch(repo_conn, patch, final) do
    with {:ok, pr} <- GitHub.get_pr(repo_conn, patch.pr_xref),
         {:ok, _} <- GitHub.update_pr_base(repo_conn, %{pr | base_ref: final}) do
      # The "edited" webhook will echo this update; writing it now keeps the
      # rest of activation working with the normalized base. The old base is
      # kept so dissolving the bundle can restore it. Should the echo outrun
      # this write, the syncer treats it as a base bors didn't record and
      # clears the bookkeeping — the retarget stands, and a later unlink
      # simply leaves the base in place.
      patch =
        patch
        |> Patch.changeset(%{into_branch: final, retargeted_from: patch.into_branch})
        |> Repo.update!()

      send_message(repo_conn, [patch], {:retargeted, final})
      {:ok, patch}
    else
      _ -> :error
    end
  end

  # Undo queue-time retargeting when a bundle dissolves without merging:
  # a member whose base bors moved — and which still points where bors
  # left it — is retargeted back, so an unlinked gh-stack child does not
  # keep showing (and squash-merging) its parent's changes. A base a human
  # has moved since, or a closed pull request, is left alone.
  defp restore_retargeted_bases(repo_conn, members) do
    Enum.each(members, fn patch ->
      cond do
        is_nil(patch.retargeted_from) or patch.retargeted_from == patch.into_branch ->
          :ok

        patch.open ->
          restore_base(repo_conn, patch)

        true ->
          # A closed pull request's base cannot be edited; if it is ever
          # reopened, its base is still where the bundle left it, so warn.
          send_message(repo_conn, [patch], {:base_restore_failed, patch.retargeted_from})
      end
    end)
  end

  defp restore_base(repo_conn, patch) do
    with {:ok, pr} <- GitHub.get_pr(repo_conn, patch.pr_xref),
         %{base_ref: current} when current == patch.into_branch <- pr,
         {:ok, _} <- GitHub.update_pr_base(repo_conn, %{pr | base_ref: patch.retargeted_from}) do
      patch
      |> Patch.changeset(%{into_branch: patch.retargeted_from})
      |> Repo.update!()

      send_message(repo_conn, [patch], {:base_restored, patch.retargeted_from})
    else
      %GitHub.Pr{} ->
        # The base was moved by hand after bors retargeted it; respect that.
        :ok

      _ ->
        send_message(repo_conn, [patch], {:base_restore_failed, patch.retargeted_from})
    end
  end

  defp bundle_preflight(_repo_conn, []), do: :ok

  defp bundle_preflight(repo_conn, [patch | rest]) do
    case patch_preflight(repo_conn, patch) do
      {:ok, _} -> bundle_preflight(repo_conn, rest)
      :waiting -> {:waiting, patch, nil}
      {:waiting, toml} -> {:waiting, patch, toml}
      {:error, message} -> {:error, message, patch}
    end
  end

  # The bundle analogue of run/3: the same queueing sequence, N patches at
  # once, with each member's reviewer taken from its held approval. Kept
  # separate so the upstream single-patch path stays untouched — a change to
  # the sequence in either function must be mirrored in the other.
  defp run_bundle(project, members, max_batch_size) do
    repo_conn = get_repo_conn(project)
    members = Bundles.stack_order(members)
    into_branch = hd(members).into_branch

    priority = members |> Enum.map(& &1.priority) |> Enum.max()
    is_single = Enum.any?(members, & &1.is_single)

    {batch, is_new_batch} =
      get_new_batch(
        max_batch_size,
        project.id,
        into_branch,
        priority,
        is_single,
        Enum.count(members)
      )

    # All members join the batch or none do: a crash after a partial insert
    # would otherwise leave a batch that merges only part of the bundle.
    {:ok, _} =
      Repo.transaction(fn ->
        Enum.each(members, fn p ->
          %LinkPatchBatch{}
          |> LinkPatchBatch.changeset(%{
            batch_id: batch.id,
            patch_id: p.id,
            reviewer: p.bundle_reviewer
          })
          |> Repo.insert!()
        end)
      end)

    Labeler.reconcile_queue(repo_conn, into_branch, members)

    Project.ping!(project.id)

    if is_new_batch do
      put_incomplete_on_hold(repo_conn, batch)
    end

    poll_after_delay(project)
    send_status(repo_conn, batch.id, members, :waiting)
  end

  defp do_stack(repo_conn, patch, target_xref, project) do
    case Bundles.validate_link(patch, [target_xref], project.id, :stack) do
      {:error, reason} ->
        send_message(repo_conn, [patch], {:link_error, reason})

      {:ok, members} ->
        target = Enum.find(members, &(&1.pr_xref == target_xref))

        cond do
          Bundles.creates_stack_cycle?(target, patch) ->
            send_message(repo_conn, [patch], {:link_error, :cycle})

          not Bundles.contains_head?(repo_conn, target, patch) ->
            # If the target contains this patch's head instead, the user
            # most likely commented on the parent: name the fix.
            message =
              if Bundles.contains_head?(repo_conn, patch, target) do
                {:link_error, {:stack_reversed, target_xref, patch.pr_xref}}
              else
                {:link_error, {:not_rebased, target_xref}}
              end

            send_message(repo_conn, [patch], message)

          true ->
            members = Bundles.form_stacked(members, patch, target, project.id)
            compare_url = compare_url(project, target, patch)
            send_message(repo_conn, members, {:stacked, patch.pr_xref, target_xref, compare_url})
        end
    end
  end

  # A point-in-time compare view of the child's own changes: exactly the
  # delta contains_head?/3 verified. Built from SHAs, so it also works when
  # the branches live in a fork.
  defp compare_url(project, parent, child) do
    root = Confex.fetch_env!(:bors, :html_github_root)
    "#{root}/#{project.name}/compare/#{parent.commit}...#{child.commit}"
  end

  def sort_batches(batches) do
    sorted_batches =
      Enum.sort_by(
        batches,
        &{
          -BatchState.numberize(&1.state),
          -&1.priority,
          &1.last_polled
        }
      )

    new_batches = Enum.dedup_by(sorted_batches, & &1.id)

    state =
      if new_batches != [] and hd(new_batches).state == :running do
        :running
      else
        Enum.each(new_batches, fn batch -> :waiting = batch.state end)
        :waiting
      end

    {state, new_batches}
  end

  defp poll_batches({:waiting, batches}) do
    case Enum.filter(batches, &Batch.next_poll_is_past/1) do
      [] -> :ok
      [batch | _] -> start_waiting_batch(batch)
    end
  end

  defp poll_batches({:running, batches}) do
    batch = hd(batches)

    cond do
      Batch.timeout_is_past(batch) ->
        timeout_batch(batch)

      Batch.next_poll_is_past(batch) ->
        poll_running_batch(batch)

      true ->
        :ok
    end
  end

  defp start_waiting_batch(batch) do
    project = batch.project
    repo_conn = get_repo_conn(project)

    {closed_links, patch_links} =
      Repo.all(LinkPatchBatch.from_batch(batch.id))
      |> Enum.sort_by(& &1.patch.pr_xref)
      |> Enum.split_with(&(&1.patch.open == false))

    # A closed patch takes its whole bundle with it: linked patches merge
    # together or not at all.
    {pulled_links, patch_links} = Bundles.split_pulled_by_closed(closed_links, patch_links)

    Enum.each(closed_links ++ pulled_links, &Repo.delete!/1)

    Enum.each(pulled_links, fn link ->
      closed_xref =
        Enum.find_value(closed_links, fn closed ->
          closed.patch.bundle_id == link.patch.bundle_id && closed.patch.pr_xref
        end)

      send_message(repo_conn, [link.patch], {:bundle_pulled, closed_xref, :closed})
    end)

    # A PR closed while queued has just left the queue; reconcile its labels off.
    # The closed links are gone now and these patches are dropped from the
    # reconcile below, so they wouldn't be touched otherwise.
    Labeler.reconcile_queue(
      repo_conn,
      batch.into_branch,
      Enum.map(closed_links ++ pulled_links, & &1.patch)
    )

    # Stacked patches must merge after the patch they stack on, and bundles
    # merge contiguously.
    patch_links = Bundles.sort_links_for_merge(patch_links)

    # If all patches were closed and removed, cancel the batch early
    if Enum.empty?(patch_links) do
      now = DateTime.to_unix(DateTime.utc_now(), :second)
      send_status(repo_conn, batch, :canceled)

      batch
      |> Batch.changeset(%{state: :canceled, commit: nil, last_polled: now})
      |> Repo.update!()

      send_zulip(batch, :canceled)
      Project.ping!(project.id)
      :canceled
    else
      stmp = "#{project.staging_branch}.tmp"

      base = get_base(repo_conn, batch.into_branch)

      tbase = %{
        tree: base.tree,
        commit:
          GitHub.synthesize_commit!(
            repo_conn,
            %{
              branch: stmp,
              tree: base.tree,
              parents: [base.commit],
              commit_message: "[ci skip][skip ci][skip netlify]",
              committer: nil
            }
          )
      }

      do_merge_patch = fn %{patch: patch}, branch ->
        pr = GitHub.get_pr!(repo_conn, patch.pr_xref)

        case branch do
          :conflict ->
            :conflict

          :canceled ->
            :canceled

          :race ->
            :race

          # Integrity invariant: never merge a head that differs from the
          # patch.commit everything upstream was authorized against. This live
          # head-vs-stored check is also the backstop the delegation merge-time
          # gate relies on: that gate verifies the *stored* patch.commit and
          # does not re-fetch, so if a `synchronize` was never processed it can
          # bless a stale-but-safe commit while the real head has moved on. This
          # comparison is what refuses that head. Weakening it (e.g. merging
          # without this live get_pr! check) would turn the gate's reliance on a
          # possibly-stale patch.commit into a real bypass. See
          # DELEGATION_INVALIDATION.md, "Known limitations — Missed-push window".
          _ when pr.head_sha != patch.commit ->
            :race

          _ ->
            GitHub.merge_branch!(
              repo_conn,
              %{
                from: patch.commit,
                to: stmp,
                commit_message:
                  "[ci skip][skip ci][skip netlify] -bors-staging-tmp-#{patch.pr_xref}"
              }
            )
        end
      end

      merge = Enum.reduce(patch_links, tbase, do_merge_patch)

      {status, commit} =
        start_waiting_merged_batch(
          batch,
          patch_links,
          base,
          merge
        )

      now = DateTime.to_unix(DateTime.utc_now(), :second)

      GitHub.delete_branch!(repo_conn, stmp)
      send_status(repo_conn, batch, status)

      case status do
        :running ->
          # when a batch starts set priority to 100
          # so that we can move patches to the "front of the line" without interrupting running batches
          raise_batch_priority(batch, 100)

        _ ->
          :ok
      end

      batch
      |> Batch.changeset(%{state: status, commit: commit, last_polled: now})
      |> Repo.update!()

      send_zulip(batch, status)

      # Now that the batch state is committed, reflect it in the queue labels:
      # a `:running` batch is "building", while a failed merge (:conflict /
      # :error) takes its patches off the queue.
      Labeler.reconcile_queue(repo_conn, batch.into_branch, Enum.map(patch_links, & &1.patch))

      Project.ping!(batch.project_id)
      status
    end
  end

  # Private function to handle retry logic with exponential backoff
  defp get_base(repo_conn, into_branch) do
    do_get_base(repo_conn, into_branch, 1_000, 5_000)
  end

  defp do_get_base(repo_conn, into_branch, current_delay, max_delay) do
    # Non fast forward errors sometimes occur because GitHub returns a stale commit
    # when we fetch the target branch. Usually, this is because the last batch succeeded,
    # but GitHub has not propagated that info to all its APIs yet,
    # so the stale commit is the one the last successful batch was pushed on top of.
    # Therefore we cache the last commit we received from GitHub in the process dictionary below,
    # and then if the next time we call the GitHub branch API we receive the same commit,
    # we retry the API call with an exponentially increasing delay, until max_delay is exceeded.
    last_commit = Process.get(:last_commit)

    result =
      GitHub.get_branch!(
        repo_conn,
        into_branch
      )

    if Application.get_env(:bors, :is_test) do
      Process.put(:last_commit, result.commit)
      result
    else
      case result do
        %{commit: ^last_commit} when current_delay <= max_delay ->
          Process.sleep(current_delay)
          do_get_base(repo_conn, into_branch, current_delay * 2, max_delay)

        %{commit: ^last_commit} ->
          # Exceeded max delay but commit unchanged
          Logger.warning(
            "get_base: exceeded max delay but commit unchanged: #{inspect(last_commit)}"
          )

          result

        res ->
          # Commit changed or first call
          # Note that we reset the last_commit to :nil if the batch fails;
          # see the :error case of complete_batch/3
          Process.put(:last_commit, res.commit)

          Logger.info(
            "get_base: commit changed: #{inspect(last_commit)}. current_delay was #{current_delay}."
          )

          res
      end
    end
  end

  defp start_waiting_merged_batch(_batch, [], _, _) do
    {:canceled, nil}
  end

  defp start_waiting_merged_batch(batch, patch_links, base, %{tree: tree}) do
    repo_conn = get_repo_conn(batch.project)
    patches = Enum.map(patch_links, & &1.patch)

    repo_conn
    |> Batcher.GetBorsToml.get("#{batch.project.staging_branch}.tmp")
    |> case do
      {:ok, toml} ->
        parents =
          if toml.use_squash_merge do
            stmp = "#{batch.project.staging_branch}-squash-merge.tmp"
            GitHub.force_push!(repo_conn, base.commit, stmp)

            new_head =
              Enum.reduce_while(patch_links, base.commit, fn patch_link, prev_head ->
                Logger.debug("Patch Link #{inspect(patch_link)}")
                Logger.debug("Patch #{inspect(patch_link.patch)}")

                cpt =
                  case get_squash_pr_data(repo_conn, patch_link.patch, toml) do
                    {:ok,
                     %{
                       commit_message: commit_message,
                       source_sha: source_sha,
                       committer: committer
                     }} ->
                      Logger.info("Staging branch #{stmp}")
                      Logger.info("Commit sha #{source_sha}")

                      # Create a merge commit for each PR
                      # because each PR is merged on top of each other in stmp, we can verify against any merge conflicts
                      merge_commit =
                        GitHub.merge_branch!(
                          repo_conn,
                          %{
                            from: source_sha,
                            to: stmp,
                            commit_message:
                              "[ci skip][skip ci][skip netlify] -bors-staging-tmp-#{source_sha}"
                          }
                        )

                      Logger.info("Merge Commit #{inspect(merge_commit)}")

                      Logger.info("Previous Head #{inspect(prev_head)}")

                      # Then compress the merge commit into tree into a single commit
                      # append it to the previous commit
                      # Because the merges are iterative the contain *only* the changes from the PR vs the previous PR(or head)
                      case merge_commit do
                        :conflict ->
                          :conflict

                        _ ->
                          case GitHub.create_commit(
                                 repo_conn,
                                 %{
                                   tree: merge_commit.tree,
                                   parents: [prev_head],
                                   commit_message: commit_message,
                                   committer: committer
                                 }
                               ) do
                            {:ok, commit_sha} ->
                              commit_sha

                            {:error, :create_commit, status, _body, request_id} = error ->
                              Logger.warning(
                                "start_waiting_merged_batch: create_commit failed with status #{status}, request_id=#{inspect(request_id)}"
                              )

                              error

                            {:error, :create_commit} = error ->
                              Logger.warning("start_waiting_merged_batch: create_commit failed")
                              error
                          end
                      end

                    {:error, reason} = error ->
                      Logger.warning(
                        "start_waiting_merged_batch: unable to build squash commit metadata for PR #{patch_link.patch.pr_xref}: #{inspect(reason)}"
                      )

                      error
                  end

                Logger.info("Commit Sha #{inspect(cpt)}")

                case cpt do
                  :conflict ->
                    {:halt, :conflict}

                  {:error, _, _, _, _} = error ->
                    {:halt, error}

                  {:error, _} = error ->
                    {:halt, error}

                  commit_sha ->
                    {:cont, commit_sha}
                end
              end)

            GitHub.delete_branch!(repo_conn, stmp)

            case new_head do
              {:error, _, _, _, _} = error ->
                error

              {:error, _} = error ->
                error

              head ->
                [head]
            end
          else
            parents = [base.commit | Enum.map(patch_links, & &1.patch.commit)]
            parents
          end

        if toml.use_squash_merge do
          case parents do
            {:error, _, _, _, _} ->
              {:error, nil}

            {:error, _} ->
              {:error, nil}

            _ ->
              # This will avoid creating a merge commit, which is important since it will prevent
              # bors from polluting th git blame history with it's own name
              head = Enum.at(parents, 0)

              if head == :conflict do
                {:conflict, nil}
              else
                GitHub.force_push!(repo_conn, head, batch.project.staging_branch)
                setup_statuses(batch, toml)
                {:running, head}
              end
          end
        else
          commit_message =
            Batcher.Message.generate_commit_message(
              patch_links,
              toml.cut_body_after,
              gather_co_authors(batch, patch_links),
              toml.commit_title
            )

          head =
            GitHub.synthesize_commit!(
              repo_conn,
              %{
                branch: batch.project.staging_branch,
                tree: tree,
                parents: parents,
                commit_message: commit_message,
                committer: toml.committer
              }
            )

          setup_statuses(batch, toml)
          {:running, head}
        end

      {:error, message} ->
        message = Batcher.Message.generate_bors_toml_error(message)
        send_message(repo_conn, patches, {:config, message})
        {:error, nil}
    end
  end

  defp start_waiting_merged_batch(batch, patch_links, _base, :conflict) do
    project = batch.project
    repo_conn = get_repo_conn(project)
    patches = Enum.map(patch_links, & &1.patch)
    state = Divider.split_batch_with_conflicts(patch_links, batch)
    poll_after_delay(project)

    if state == :failed do
      # A single unmergeable PR is dropped terminally, so flag it for a
      # maintainer to re-queue. The queue labels (`ready-to-merge` /
      # `bors-staging`) come off in start_waiting_batch's reconcile once the
      # batch is committed to :conflict.
      Labeler.mark_awaiting_requeue(repo_conn, batch.into_branch, patches)

      # A terminally-failed conflict batch is one unit: a lone patch, or one
      # bundle whose members conflict with each other. A bundle can't be
      # bisected, and rebasing the base won't resolve a member-vs-member
      # clash, so tell the members together instead of the solo per-PR text.
      {bundled, solo} = Enum.split_with(patches, &(&1.bundle_id != nil))
      send_message(repo_conn, solo, {:conflict, :failed, batch.into_branch})

      if bundled != [] do
        xrefs = bundled |> Enum.map(& &1.pr_xref) |> Enum.sort()
        send_message(repo_conn, bundled, {:bundle_conflict, xrefs})
      end
    else
      send_message(repo_conn, patches, {:conflict, state})
    end

    {:conflict, nil}
  end

  defp start_waiting_merged_batch(batch, patch_links, _base, :race) do
    project = batch.project
    repo_conn = get_repo_conn(project)
    patches = Enum.map(patch_links, & &1.patch)
    poll_after_delay(project)

    send_message(repo_conn, patches, :race)
    send_status(repo_conn, batch, :race)

    {:error, nil}
  end

  defp get_squash_pr_data(repo_conn, patch, toml) do
    with {:ok, commits} <- GitHub.get_pr_commits(repo_conn, patch.pr_xref),
         {:ok, pr} <- GitHub.get_pr(repo_conn, patch.pr_xref),
         {:ok, user_email, user_name} <- get_squash_author(repo_conn, pr) do
      commit_message =
        Batcher.Message.generate_squash_commit_message(
          pr,
          commits,
          user_email,
          user_name,
          toml.cut_body_after
        )

      {:ok,
       %{
         commit_message: commit_message,
         source_sha: pr.head_sha,
         committer: %{name: user_name, email: user_email}
       }}
    end
  end

  defp get_squash_author({token, _repo_xref}, pr) when not is_nil(pr.user) do
    case GitHub.get_user_by_login(token, pr.user.login) do
      {:ok, nil} ->
        {:ok, "#{pr.user.id}+#{pr.user.login}@users.noreply.github.com", pr.user.login}

      {:ok, user} ->
        user_email =
          if user.email != nil do
            user.email
          else
            "#{user.id}+#{user.login}@users.noreply.github.com"
          end

        user_name = user.name || user.login
        {:ok, user_email, user_name}

      {:error, _} = error ->
        error
    end
  end

  defp get_squash_author(_, _), do: {:error, :missing_pr_user}

  def gather_co_authors(batch, patch_links) do
    repo_conn = get_repo_conn(batch.project)

    patch_links
    |> Enum.map(& &1.patch.pr_xref)
    |> Enum.flat_map(&GitHub.get_pr_commits!(repo_conn, &1))
    |> Enum.map(&"#{&1.author_name} <#{&1.author_email}>")
    |> Enum.uniq()
  end

  defp setup_statuses(batch, toml) do
    toml.status
    |> Enum.map(
      &%Status{
        batch_id: batch.id,
        identifier: &1,
        url: nil,
        state: :running
      }
    )
    |> Enum.each(&Repo.insert!/1)

    now = DateTime.to_unix(DateTime.utc_now(), :second)

    batch
    |> Batch.changeset(%{timeout_at: now + toml.timeout_sec})
    |> Repo.update!()
  end

  defp poll_running_batch(batch) do
    repo_conn = get_repo_conn(batch.project)

    case GitHub.get_commit_status(repo_conn, batch.commit) do
      {:ok, statuses} ->
        statuses
        |> Enum.each(fn {identifier, state} ->
          batch.id
          |> Status.get_for_batch(identifier)
          |> Repo.update_all(set: [state: state, identifier: identifier])
        end)

        maybe_complete_batch(batch)

      error when is_tuple(error) and tuple_size(error) >= 2 and elem(error, 0) == :error ->
        Logger.warning(
          "poll_running_batch: get_commit_status failed for batch #{batch.id} commit #{batch.commit}: #{inspect(error)}"
        )

        now = DateTime.to_unix(DateTime.utc_now(), :second)

        batch
        |> Batch.changeset(%{last_polled: now})
        |> Repo.update!()
    end
  end

  defp maybe_complete_batch(batch) do
    statuses = Repo.all(Status.all_for_batch(batch.id))
    initial_status = Batcher.State.summary_database_statuses(statuses)
    now = DateTime.to_unix(DateTime.utc_now(), :second)
    repo_conn = get_repo_conn(batch.project)

    next_status =
      if initial_status != :running do
        # some repositories require an OK status to push
        send_status(repo_conn, batch, :ok)
        # need to change status (could go from :ok to :error if non-ff push)
        maybe_completed_status = complete_batch(initial_status, batch, statuses)
        # status can change so send_status should come after complete_batch
        send_status(repo_conn, batch, maybe_completed_status)
        Project.ping!(batch.project_id)
        maybe_completed_status
      else
        initial_status
      end

    batch
    |> Batch.changeset(%{state: next_status, last_polled: now})
    |> Repo.update!()

    send_zulip(batch, next_status)

    if next_status != :running do
      # A successful merge deliberately leaves the PR's labels untouched: the PR
      # closes, so `ready-to-merge` / `bors-staging` (and `delegated`) freeze as a
      # best-effort historical record of how it merged. Only a failure — which
      # leaves the PR open — reconciles its queue labels off (`awaiting-requeue`
      # for a terminal build failure is set separately in complete_batch(:error)).
      if next_status != :ok do
        patches = batch.id |> Patch.all_for_batch() |> Repo.all()
        Labeler.reconcile_queue(repo_conn, batch.into_branch, patches)
      end

      poll_(batch.project_id)
    end
  end

  @spec complete_batch(Status.state(), Batch.t(), [Status.t()]) :: Status.state()
  defp complete_batch(:ok, batch, statuses) do
    project = batch.project
    repo_conn = get_repo_conn(project)

    {_, toml} =
      case Batcher.GetBorsToml.get(repo_conn, "#{batch.project.staging_branch}") do
        {:error, :fetch_failed} ->
          Batcher.GetBorsToml.get(repo_conn, "#{batch.project.staging_branch}.tmp")

        {:ok, x} ->
          {:ok, x}
      end

    push_result =
      push_with_retry(
        repo_conn,
        batch.commit,
        batch.into_branch
      )

    push_status =
      case push_result do
        {:error, :push, 422, raw_error_content} ->
          cond do
            String.contains?(raw_error_content, "Update is not a fast forward") ->
              {:non_ff}

            true ->
              {:unknown_failure, 422, raw_error_content}
          end

        {:error, _, status_code, raw_error_content} ->
          {:unknown_failure, status_code, raw_error_content}

        {:ok, _} ->
          {:success}
      end

    patches =
      batch.id
      |> Patch.all_for_batch()
      |> Repo.all()

    case push_status do
      {:success} ->
        # The bundle (if any) has merged: drop the held approvals so a future
        # run needs fresh r+'s, and forget the retargeting record so a later
        # unlink won't try to restore a base whose changes are now merged.
        Bundles.drop_held_approvals(patches)
        Bundles.forget_retargeting(patches)

        if toml.use_squash_merge do
          Enum.each(patches, fn patch ->
            send_message(repo_conn, [patch], {:merged, :squashed, batch.into_branch, statuses})
            pr = GitHub.get_pr!(repo_conn, patch.pr_xref)
            pr = %BorsNG.GitHub.Pr{pr | state: :closed, title: "[Merged by Bors] - #{pr.title}"}
            GitHub.update_pr!(repo_conn, pr)
          end)
        else
          send_message(repo_conn, patches, {:succeeded, statuses})
        end

        :ok

      {:non_ff} ->
        # retry the complete batch (no bisect required as build passed all statuses)
        patch_links =
          batch.id
          |> LinkPatchBatch.from_batch()
          |> Repo.all()

        Divider.clone_batch(patch_links, project.id, batch.into_branch)
        poll_after_delay(project)

        # send appropriate message to failed patches
        send_message(repo_conn, patches, {:push_failed_non_ff, batch.into_branch})

        :error

      {:unknown_failure, status_code, raw_error_content} ->
        # Don't retry the batch. Something is preventing this batch from merging
        # and it's unlikely us retrying would change that.

        # send appropriate message to failed patches
        send_message(
          repo_conn,
          patches,
          {:push_failed_unknown_failure, batch.into_branch, status_code, raw_error_content}
        )

        # The build passed but the push to the base branch failed unrecoverably
        # and we don't re-queue, so the PR is dropped and needs a maintainer to
        # put it back on. `ready-to-merge` / `bors-staging` come off in
        # maybe_complete_batch once the batch state is committed to :error.
        Labeler.mark_awaiting_requeue(repo_conn, batch.into_branch, patches)

        :error
    end
  end

  defp complete_batch(:error, batch, statuses) do
    project = batch.project
    repo_conn = get_repo_conn(project)
    erred = Enum.filter(statuses, &(&1.state == :error))

    patch_links =
      batch.id
      |> LinkPatchBatch.from_batch()
      |> Repo.all()

    patches = Enum.map(patch_links, & &1.patch)
    state = Divider.split_batch(patch_links, batch)

    # The batch failed, so it's OK to push the next batch on top of the same commit we saw
    # see do_get_base/4
    Process.put(:last_commit, nil)

    if state == :retrying do
      poll_after_delay(project)
      send_message(repo_conn, patches, {state, erred})
    else
      # Terminal failure (a single-patch batch): the PR is dropped and needs a
      # maintainer to put it back on the queue, so flag it. `ready-to-merge` /
      # `bors-staging` are taken off by maybe_complete_batch once the batch
      # state is committed to :error.
      Labeler.mark_awaiting_requeue(repo_conn, batch.into_branch, patches)

      # A terminally-failed batch is one unit: a lone patch, or one bundle.
      # A bundle can't be bisected to a culprit, so drop the whole set's held
      # approvals (like a solo PR loses its r+ on failure) and tell the members
      # together, instead of the stock per-PR text. Every member then needs a
      # fresh r+, so re-running requires re-reviewing the fixed pull request.
      # The bundle is not dissolved and its bases stay retargeted, so the
      # retargeting record is left intact for a later unlink to restore.
      {bundled, solo} = Enum.split_with(patches, &(&1.bundle_id != nil))
      send_message(repo_conn, solo, {state, erred})

      if bundled != [] do
        Bundles.drop_held_approvals(bundled)
        xrefs = bundled |> Enum.map(& &1.pr_xref) |> Enum.sort()
        send_message(repo_conn, bundled, {:bundle_failed, xrefs, erred})
      end
    end

    :error
  end

  # A delay has been observed between Bors sending the Status change
  # and GitHub allowing a Status-bearing commit to be pushed to master.
  # As a workaround, retry with exponential backoff.
  # This should retry *nine times*, by the way.
  defp push_with_retry(repo_conn, commit, into_branch, timeout \\ 40) do
    result =
      GitHub.push(
        repo_conn,
        commit,
        into_branch
      )

    if Application.get_env(:bors, :is_test) do
      result
    else
      case result do
        {:ok, _} ->
          Logger.info("push_with_retry: succeeded when timeout was #{timeout}")
          result

        _ when timeout >= 20_480 ->
          Logger.warning("push_with_retry: failed when timeout was #{timeout}")
          result

        _ ->
          Process.sleep(timeout)
          push_with_retry(repo_conn, commit, into_branch, timeout * 2)
      end
    end
  end

  defp timeout_batch(batch) do
    project = batch.project
    repo_conn = get_repo_conn(project)

    patch_links =
      batch.id
      |> LinkPatchBatch.from_batch()
      |> Repo.all()

    patches = Enum.map(patch_links, & &1.patch)
    state = Divider.split_batch(patch_links, batch)

    if state == :retrying do
      poll_after_delay(project)
    else
      # Terminal failure (a single-patch batch): the PR is dropped and needs a
      # maintainer to put it back on the queue, so flag it before the queue
      # reconcile below takes `ready-to-merge` / `bors-staging` off.
      Labeler.mark_awaiting_requeue(repo_conn, batch.into_branch, patches)
    end

    send_message(repo_conn, patches, {:timeout, state})

    batch
    |> Batch.changeset(%{state: :error})
    |> Repo.update!()

    send_zulip(batch, :error)

    Project.ping!(project.id)

    send_status(repo_conn, batch, :timeout)

    # The batch is no longer :running, so its patches are off the queue. A
    # :retrying bisect re-queued its halves into fresh :waiting batches, which
    # this reconcile sees and keeps labeled. Mirrors maybe_complete_batch.
    Labeler.reconcile_queue(repo_conn, batch.into_branch, patches)
  end

  defp cancel_patch(nil, _, _), do: :ok

  defp cancel_patch(batch, patch_id, reason) do
    cancel_patch(batch, patch_id, batch.state, reason)
    Project.ping!(batch.project_id)
  end

  defp cancel_patch(batch, patch_id, :running, reason) do
    project = batch.project

    patch_links =
      batch.id
      |> LinkPatchBatch.from_batch()
      |> Repo.all()

    patches = Enum.map(patch_links, & &1.patch)

    # Canceling a bundled patch cancels its whole bundle: linked patches
    # merge together or not at all.
    canceled_ids = Bundles.member_ids(patch_links, patch_id)

    uncanceled_patch_links =
      Enum.reject(patch_links, &(&1.patch_id in canceled_ids))

    state =
      case uncanceled_patch_links do
        [] -> :failed
        _ -> :retrying
      end

    batch
    |> Batch.changeset(%{state: :canceled})
    |> Repo.update!()

    send_zulip(batch, :canceled)

    repo_conn = get_repo_conn(project)

    if state == :retrying do
      Divider.clone_batch(uncanceled_patch_links, project.id, batch.into_branch)

      uncanceled_patches =
        Enum.reject(
          patches,
          &(&1.id in canceled_ids)
        )

      send_message(repo_conn, uncanceled_patches, {:canceled, :retrying})
    end

    canceled_patch = Enum.find(patches, &(&1.id == patch_id))
    siblings = Enum.filter(patches, &(&1.id in canceled_ids and &1.id != patch_id))

    send_message(repo_conn, [canceled_patch], {:canceled, :failed, reason})
    send_message(repo_conn, siblings, {:bundle_pulled, canceled_patch.pr_xref, reason})

    send_status(repo_conn, batch, :canceled)

    # The canceled patch (and its bundle) leaves the queue; any uncanceled
    # patches were re-queued into a fresh batch above, so reconcile reflects both.
    Labeler.reconcile_queue(repo_conn, batch.into_branch, patches)
  end

  defp cancel_patch(batch, patch_id, _state, reason) do
    project = batch.project

    patch_links =
      batch.id
      |> LinkPatchBatch.from_batch()
      |> Repo.all()

    # Canceling a bundled patch pulls its whole bundle from the waiting batch.
    canceled_ids = Bundles.member_ids(patch_links, patch_id)

    canceled_links = Enum.filter(patch_links, &(&1.patch_id in canceled_ids))
    Enum.each(canceled_links, &Repo.delete!/1)

    if Batch.is_empty(batch.id, Repo) do
      Repo.delete!(batch)
    end

    canceled_patches = Enum.map(canceled_links, & &1.patch)
    patch = Repo.get!(Patch, patch_id)
    siblings = Enum.reject(canceled_patches, &(&1.id == patch_id))
    repo_conn = get_repo_conn(project)
    send_status(repo_conn, batch.id, canceled_patches, :canceled)
    send_message(repo_conn, [patch], {:canceled, :failed, reason})
    send_message(repo_conn, siblings, {:bundle_pulled, patch.pr_xref, reason})

    # The patches have been removed from their (waiting) batch, so they're off
    # the queue.
    Labeler.reconcile_queue(repo_conn, batch.into_branch, canceled_patches)
  end

  defp patch_preflight(repo_conn, patch) do
    if Patch.ci_skip?(patch) do
      {:error, :ci_skip}
    else
      toml =
        Batcher.GetBorsToml.get(
          repo_conn,
          patch.commit
        )

      patch_preflight(repo_conn, patch, toml)
    end
  end

  defp patch_preflight(_repo_conn, _patch, {:error, _}) do
    {:ok, nil}
  end

  defp patch_preflight(repo_conn, patch, {:ok, toml}) do
    Delegation.reconcile_default_expiry(patch, toml.delegation_default_expiry_sec)

    with {:ok, labels} <- GitHub.get_labels(repo_conn, patch.pr_xref),
         {:ok, github_commit_statuses} <- GitHub.get_commit_status(repo_conn, patch.commit),
         {:ok, reviews} <- GitHub.get_reviews(repo_conn, patch.pr_xref),
         {:ok, commit_reviews} <- maybe_get_commit_reviews(repo_conn, patch, toml) do
      passed_label =
        labels
        |> MapSet.new()
        |> MapSet.disjoint?(MapSet.new(toml.block_labels))

      pr_status_mapset = MapSet.new(toml.pr_status)

      no_error_status =
        github_commit_statuses
        |> Enum.filter(fn {_, status} -> status == :error end)
        |> Enum.map(fn {context, _} -> context end)
        |> MapSet.new()
        |> MapSet.disjoint?(pr_status_mapset)

      no_waiting_status =
        github_commit_statuses
        |> Enum.filter(fn {_, status} -> status == :running end)
        |> Enum.map(fn {context, _} -> context end)
        |> MapSet.new()
        |> MapSet.disjoint?(pr_status_mapset)

      # We wait to have all required pr statuses set.
      no_unset_status =
        github_commit_statuses
        |> Enum.filter(fn {context, _} -> MapSet.member?(pr_status_mapset, context) end)
        |> Enum.count() == Enum.count(pr_status_mapset)

      code_owners_approved = check_code_owner(repo_conn, patch, toml)

      # fetching all reviews even when up_to_date_approvals is on to catch cases of rejected reviews.
      passed_review = reviews |> reviews_status(toml)

      passed_up_to_date_review =
        if toml.required_approvals && toml.up_to_date_approvals do
          commit_reviews |> reviews_status(toml)
        else
          :sufficient
        end

      Logger.info(
        "Code review status: Label Check #{passed_label} Passed Status: #{no_error_status and no_waiting_status and no_unset_status} Passed Review: #{passed_review} CODEOWNERS: #{code_owners_approved} Passed Up-To-Date Review: #{passed_up_to_date_review}"
      )

      case {passed_label, no_error_status, no_waiting_status, no_unset_status, passed_review,
            code_owners_approved, passed_up_to_date_review} do
        {true, true, true, true, :sufficient, true, :sufficient} -> {:ok, toml.max_batch_size}
        {false, _, _, _, _, _, _} -> {:error, :blocked_labels}
        {_, _, _, _, :insufficient, _, _} -> {:error, :insufficient_approvals}
        {_, _, _, _, :failed, _, _} -> {:error, :blocked_review}
        {_, _, _, _, _, false, _} -> {:error, :missing_code_owner_approval}
        {_, false, _, _, _, _, _} -> {:error, :pr_status}
        {_, _, false, _, _, _, _} -> {:waiting, toml}
        {_, _, _, false, _, _, _} -> {:waiting, toml}
        {_, _, _, _, _, _, :insufficient} -> {:error, :insufficient_up_to_date_approvals}
      end
    else
      error when is_tuple(error) and tuple_size(error) >= 2 and elem(error, 0) == :error ->
        Logger.warning(
          "patch_preflight: transient GitHub read failure for patch #{patch.id}: #{inspect(error)}"
        )

        {:waiting, toml}
    end
  end

  defp maybe_get_commit_reviews(repo_conn, patch, toml) do
    if toml.required_approvals && toml.up_to_date_approvals do
      GitHub.get_commit_reviews(repo_conn, patch.pr_xref, patch.commit)
    else
      {:ok, nil}
    end
  end

  # A poll armed for a member with a held approval (:held_approval) reads
  # the approval back from the row when it fires, so an r- during the wait
  # simply ends the loop.
  defp resolve_prerun_reviewer(:held_approval, patch), do: patch.bundle_reviewer
  defp resolve_prerun_reviewer(reviewer, _patch), do: reviewer

  defp handle_waiting_preflight(repo_conn, reviewer, patch, try_num, toml \\ nil) do
    prerun_timeout_sec =
      case toml do
        nil -> 30 * 60
        x -> x.prerun_timeout_sec
      end

    prerun_timeout_ms = prerun_timeout_sec * 1000
    elapsed = try_num * @prerun_poll_period

    cond do
      prerun_timeout_sec == 0 ->
        send_message(repo_conn, [patch], {:preflight, :timeout})

      elapsed > prerun_timeout_ms ->
        send_message(repo_conn, [patch], {:preflight, :timeout})

      true ->
        send_message(repo_conn, [patch], {:preflight, :waiting})
        Logger.info("Start Poll Patch #{patch.id} prerun")

        Process.send_after(
          self(),
          {:prerun_poll, try_num + 1, {reviewer, patch}},
          @prerun_poll_period
        )
    end
  end

  defp check_code_owner(repo_conn, patch, toml) do
    if !toml.use_codeowners do
      true
    else
      Logger.info("Checking code owners")

      code_owner_result =
        try do
          Batcher.GetCodeOwners.get(repo_conn, patch.into_branch)
        rescue
          error ->
            {:error, {:codeowners_exception, error}}
        catch
          kind, reason ->
            {:error, {:codeowners_catch, kind, reason}}
        end

      case code_owner_result do
        {:ok, code_owner} ->
          Logger.info("CODEOWNERS file #{inspect(code_owner)}")

          case GitHub.get_pr_files(repo_conn, patch.pr_xref) do
            {:ok, files} ->
              Logger.info("Files found: #{inspect(files)}")

              required_reviews = BorsNG.CodeOwnerParser.list_required_reviews(code_owner, files)

              passed_review =
                repo_conn
                |> GitHub.get_reviews!(patch.pr_xref)

              Logger.info("Passed reviews: #{inspect(passed_review)}")

              # Convert the list of required reviewers into a list of true/false
              # true indicates that the reviewers requirement was satisfied,
              # false if it is open
              approved_reviews =
                Enum.map(required_reviews, fn x ->
                  # Convert a list of OR reviewers into a true or false
                  Enum.any?(x, fn required ->
                    if String.contains?(required, "/") do
                      # Remove leading @ for team name
                      # Split into org name and team name
                      [org_name, team_name | _] =
                        String.slice(required, 1, String.length(required) - 1)
                        |> String.split("/")

                      # Loop through reviewers, if they on the team accept their approval
                      team_approved =
                        Enum.any?(passed_review["approvers"], fn username ->
                          GitHub.belongs_to_team?(repo_conn, org_name, team_name, username)
                        end)

                      Logger.info("Approved: #{inspect(team_approved)}")
                      team_approved
                    else
                      Enum.any?(passed_review["approvers"], fn username ->
                        String.slice(required, 1, String.length(required) - 1) == username
                      end)
                    end
                  end)
                end)

              code_owner_approval = Enum.reduce(approved_reviews, true, fn x, acc -> x && acc end)

              Logger.info("Approved reviews: #{inspect(approved_reviews)}")
              Logger.info("Code Owner approval: #{inspect(code_owner_approval)}")

              code_owner_approval

            {:error, :get_pr_files, status, _} ->
              Logger.warning(
                "check_code_owner: get_pr_files failed for PR #{patch.pr_xref} with status #{status}"
              )

              false

            {:error, :get_pr_files} ->
              Logger.warning("check_code_owner: get_pr_files failed for PR #{patch.pr_xref}")
              false
          end

        {:error, reason} ->
          Logger.warning(
            "check_code_owner: failed to fetch/parse CODEOWNERS for branch #{patch.into_branch}: #{inspect(reason)}"
          )

          false
      end
    end
  end

  @spec reviews_status(map, Batcher.BorsToml.t()) :: :sufficient | :failed | :insufficient
  defp reviews_status(reviews, toml) do
    failed = Map.fetch!(reviews, "CHANGES_REQUESTED")
    approvals = Map.fetch!(reviews, "APPROVED")

    review_required? = is_integer(toml.required_approvals)
    approvals_needed = (review_required? && toml.required_approvals) || 0
    approved? = approvals >= approvals_needed
    failed? = failed > 0

    cond do
      # NOTE: A way to disable the code reviewing behaviour was requested on #587.
      #   As such, we only apply the reviewing rules if, on bors, the config
      #   `required_approvals` is present and an integer.
      not review_required? ->
        :sufficient

      failed? ->
        :failed

      approved? ->
        :sufficient

      review_required? ->
        :insufficient
    end
  end

  @doc """
  Find a waiting batch to add patches to, or create one. `capacity` is the
  number of patches about to be inserted (1 for a solo patch, the member
  count for a bundle): a batch is only reused if all of them fit within
  max_batch_size.
  """
  def get_new_batch(max_batch_size, project_id, into_branch, priority, force) do
    get_new_batch(max_batch_size, project_id, into_branch, priority, force, 1)
  end

  def get_new_batch(_max_batch_size, project_id, into_branch, priority, true, _capacity) do
    {Repo.insert!(Batch.new(project_id, into_branch, priority)), true}
  end

  # A bundle that fills or exceeds max_batch_size can't share a batch with
  # anything else (and can't be split), so it gets one of its own.
  def get_new_batch(max_batch_size, project_id, into_branch, priority, _force, capacity)
      when is_integer(max_batch_size) and capacity >= max_batch_size do
    {Repo.insert!(Batch.new(project_id, into_branch, priority)), true}
  end

  def get_new_batch(max_batch_size, project_id, into_branch, priority, _force, capacity) do
    Batch
    |> where([b], b.project_id == ^project_id)
    |> where([b], b.state == ^:waiting)
    |> where([b], b.into_branch == ^into_branch)
    |> where([b], b.priority == ^priority)
    |> apply_max_batch_size(max_batch_size, capacity)
    |> order_by([b], desc: b.updated_at)
    |> Repo.all()
    |> Enum.reject(fn b ->
      Repo.all(LinkPatchBatch.from_batch(b.id))
      |> Enum.any?(fn l ->
        Repo.get!(Patch, l.patch_id).is_single
      end)
    end)
    |> Enum.take(1)
    |> case do
      [batch] -> {batch, false}
      _ -> get_new_batch(max_batch_size, project_id, into_branch, priority, true, capacity)
    end
  end

  defp apply_max_batch_size(query, nil, _capacity) do
    query
  end

  defp apply_max_batch_size(query, n, capacity) do
    # The batch may take `capacity` more patches without exceeding `n`.
    room = n - capacity

    query
    |> join(:inner, [b], p in assoc(b, :patches))
    |> having([b, p], count(p.id) <= ^room)
    |> group_by([b], b.id)
  end

  defp raise_batch_priority(%Batch{priority: old_priority} = batch, priority)
       when old_priority < priority do
    project = Repo.get!(Project, batch.project_id)

    batch =
      batch
      |> Batch.changeset_raise_priority(%{priority: priority})
      |> Repo.update!()

    put_incomplete_on_hold(get_repo_conn(project), batch)
  end

  defp raise_batch_priority(_, _) do
    :ok
  end

  defp send_message(repo_conn, patches, message) do
    body = Batcher.Message.generate_message(message)

    case body do
      nil ->
        :ok

      _ ->
        Enum.each(patches, fn patch ->
          case GitHub.post_comment(repo_conn, patch.pr_xref, body) do
            :ok ->
              :ok

            err ->
              Logger.warning(
                "send_message: failed to post comment for patch #{patch.id}: #{inspect(err)}"
              )
          end
        end)
    end
  end

  defp send_status(
         repo_conn,
         %Batch{id: id, commit: commit},
         message
       ) do
    patches =
      id
      |> Patch.all_for_batch()
      |> Repo.all()

    send_status(repo_conn, id, patches, message)

    unless is_nil(commit) do
      {msg, status} = Batcher.Message.generate_status(message)

      case GitHub.post_commit_status(
             repo_conn,
             {commit, status, msg, batch_url(Endpoint, :show, id)}
           ) do
        :ok ->
          :ok

        err ->
          Logger.warning(
            "send_status: failed to post commit status for batch #{id}: #{inspect(err)}"
          )
      end
    end
  end

  defp send_status(repo_conn, batch_id, patches, message) do
    {msg, status} = Batcher.Message.generate_status(message)

    Enum.each(patches, fn patch ->
      case GitHub.post_commit_status(
             repo_conn,
             {patch.commit, status, msg, batch_url(Endpoint, :show, batch_id)}
           ) do
        :ok ->
          :ok

        err ->
          Logger.warning(
            "send_status: failed to post commit status for patch #{patch.id}: #{inspect(err)}"
          )
      end
    end)
  end

  # this should be called whenever the state of a Batch is changed using Batch.changeset
  @spec send_zulip(%Batch{}, batch_state) :: :ok | :error
  # :waiting | :running | :ok -> do nothing
  defp send_zulip(_, :waiting), do: :ok
  defp send_zulip(_, :running), do: :ok
  defp send_zulip(_, :ok), do: :ok
  # :error | :conflict | :canceled -> send notification
  defp send_zulip(batch, state) do
    {fail_message, pr_messages} =
      try do
        build_message(batch, state)
      rescue
        e ->
          e_message = "Failed to build message:\n#{inspect(e, pretty: true, width: 60)}"
          Logger.error(e_message)
          {"⚠️ bors batch failed!\n\nBatch #{batch.id}: #{state}\n\n#{e_message}", []}
      end

    Zulip.send_message(fail_message)

    pr_messages
    |> Enum.each(&Zulip.send_message/1)
  end

  # see also lib/web/templates/project/show.html.eex
  defp build_message(batch, state) do
    project = Repo.get(Project, batch.project_id)

    project_pr_url =
      Confex.fetch_env!(:bors, :html_github_root) <> "/" <> project.name <> "/pull/"

    statuses = Repo.all(Status.all_for_batch(batch.id))

    statuses_message =
      if Enum.empty?(statuses) do
        ""
      else
        "Status check(s):\n" <>
          (statuses
           |> Enum.map(&format_status/1)
           |> Enum.join("\n"))
      end

    patch_links_pr_xrefs =
      Repo.all(LinkPatchBatch.from_batch(batch.id))
      |> Enum.map(& &1.patch.pr_xref)
      |> Enum.sort()

    num_prs = length(patch_links_pr_xrefs)

    message = """
    ⚠️ `#{project.name}` bors batch [#{batch.id}](#{batch_url(Endpoint, :show, batch.id)}) failed with state: "**#{state}**"!

    #{statuses_message}

    The batch contained the following #{num_prs} PR(s):
    """

    patch_links_pr_xrefs_messages =
      patch_links_pr_xrefs
      |> Enum.with_index(1)
      |> Enum.map(fn {pr_xref, index} ->
        "(#{index}/#{num_prs}) of Batch #{batch.id}: [#{project.name}##{pr_xref}](#{project_pr_url}#{pr_xref})"
      end)

    {message, patch_links_pr_xrefs_messages}
  end

  def format_status(status) do
    if status.url do
      "- [#{status.identifier} (#{BorsNG.BatchView.stringify_state(status.state)})](#{status.url})"
    else
      "- #{status.identifier} (#{BorsNG.BatchView.stringify_state(status.state)})"
    end
  end

  @spec get_repo_conn(%Project{}) :: {{:installation, number}, number}
  defp get_repo_conn(project) do
    Project.installation_connection(project.repo_xref, Repo)
  end

  defp put_incomplete_on_hold(repo_conn, batch) do
    batches =
      batch.project_id
      |> Batch.all_for_project(:running)
      |> where([b], b.id != ^batch.id and b.priority < ^batch.priority)
      |> Repo.all()

    ids = Enum.map(batches, & &1.id)

    Status
    |> where([s], s.batch_id in ^ids)
    |> Repo.delete_all()

    Enum.each(batches, &send_status(repo_conn, &1, :delayed))

    Batch
    |> where([b], b.id in ^ids)
    |> Repo.update_all(set: [state: :waiting])
  end

  defp poll_after_delay(project) do
    poll_at = (project.batch_delay_sec + 1) * 1000
    Process.send_after(self(), {:poll, :once}, poll_at)
  end

  # Validate that there are no duplicate running batchers for the same project
  defp check_self(project_id) do
    if Application.get_env(:bors, :is_test) do
      :ok
    else
      self = self()
      ^self = BorsNG.Worker.Batcher.Registry.get(project_id)
    end
  end
end
