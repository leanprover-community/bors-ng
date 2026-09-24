defmodule BorsNG.Worker.Batcher.Message do
  @moduledoc """
  User-readable strings that go in commit messages and comments.
  """

  alias BorsNG.Worker.Batcher.BorsToml

  def generate_status(:waiting) do
    {"Waiting in queue", :running}
  end

  def generate_status(:canceled) do
    {"Canceled", :error}
  end

  def generate_status(:running) do
    {"Running", :running}
  end

  def generate_status(:ok) do
    {"Build succeeded", :ok}
  end

  def generate_status(:error) do
    {"Build failed", :error}
  end

  def generate_status(:timeout) do
    {"Timed out", :error}
  end

  def generate_status(:conflict) do
    {"Merge conflict", :error}
  end

  def generate_status(:race) do
    {"Synchronization error: PR head changed", :error}
  end

  def generate_status(:delayed) do
    {"Delayed for higher-priority pull requests", :running}
  end

  def generate_message(:race) do
    "Synchronization error: the pull request's head commit changed after it was approved (most likely a new push), so the built batch no longer matches the current code and bors did not merge it. Re-run `bors r+` once the PR is ready."
  end

  def generate_message({:preflight, :waiting}) do
    ":clock1: Waiting for PR status (GitHub check) to be set, probably by CI. Bors will automatically try to run when all required PR statuses are set."
  end

  def generate_message({:preflight, :ok}) do
    "All preflight checks passed. Batching this PR into the staging branch."
  end

  def generate_message({:preflight, :duplicate}) do
    "Stopped waiting for PR status (GitHub check) without running due to duplicate requests to run. You may check Bors to see that this PR is included in a batch by one of the other requests."
  end

  def generate_message({:preflight, :timeout}) do
    "GitHub status checks took too long to complete, so bors is giving up. You can adjust bors configuration to have it wait longer if you like."
  end

  def generate_message({:preflight, :blocked_labels}) do
    ":-1: Rejected by label"
  end

  def generate_message({:preflight, :pr_status}) do
    ":-1: Rejected by PR status"
  end

  def generate_message({:preflight, :insufficient_approvals}) do
    ":-1: Rejected by too few approved reviews"
  end

  def generate_message({:preflight, :insufficient_up_to_date_approvals}) do
    ":-1: Rejected by too few up-to-date approved reviews (some of the PR reviews are stale)"
  end

  def generate_message({:preflight, :missing_code_owner_approval}) do
    ":-1: Rejected because of missing code owner approval"
  end

  def generate_message({:preflight, :blocked_review}) do
    ":-1: Rejected by code reviews"
  end

  def generate_message({:preflight, :ci_skip}) do
    "This PR's title or body contains the CI-skip marker `[ci skip][skip ci][skip netlify]`, so CI won't run and the bors build would time out. Remove the marker before running bors."
  end

  def generate_message(:already_running_review) do
    "Already running a review"
  end

  def generate_message({:config, message}) do
    "Configuration problem:\n#{message}"
  end

  def generate_message({:conflict, :failed, branch}) do
    "Merge conflict.\n\nMerge or rebase `#{branch}` into this PR and resolve the conflict, then someone with permission can run `bors r+` or `bors retry`."
  end

  def generate_message({:conflict, :retrying}) do
    nil
  end

  def generate_message({:bundle_conflict, xrefs}) do
    prs = Enum.map_join(xrefs, ", ", &"##{&1}")

    "Merge conflict.\n\nThe linked bundle (#{prs}) can't be merged: its pull requests conflict with each other, and bors merges them as one unit. The whole set left the queue. Rebase one onto the other to resolve the clash, or `bors unlink` to split the bundle, then run `bors r+` on each member to re-queue."
  end

  def generate_message({:bundle_timeout, xrefs}) do
    prs = Enum.map_join(xrefs, ", ", &"##{&1}")

    "Timed out.\n\nThe linked bundle (#{prs}) merges as one unit, so the whole set left the queue. Fix what is needed, then run `bors r+` on each member; the bundle re-queues once they are all approved again."
  end

  def generate_message({:timeout, :failed}) do
    "Timed out.\n\nFix if necessary, and then someone with permission can run `bors r+` or `bors retry`."
  end

  def generate_message({:timeout, :retrying}) do
    "This PR was included in a batch that timed out, it will be automatically retried"
  end

  # `bors try` is a trial build, not a merge attempt, so its failure/timeout
  # messages must not suggest `bors r+` (which would queue a merge of code that
  # just failed). The right next step is to fix and run `bors try` again.
  def generate_message({:timeout, :try}) do
    "Timed out.\n\nFix if necessary, and then run `bors try` again."
  end

  def generate_message({:canceled, :failed, :push}) do
    "Bors build canceled because the PR branch was pushed to.\n\nThis cancels the in-progress bors run; if the push also touched a delegation-restricted path, any affected delegation is revoked in a separate comment. Address comments or fix if necessary, and then someone with permission can re-run `bors r+` once the PR is ready."
  end

  # A closed or draft PR has already been told what happened (the PR is closed,
  # or the draft-mode notice lists what was cleaned up), so an extra "canceled"
  # comment telling the author to run `bors r+` would be noise or contradictory.
  def generate_message({:canceled, :failed, :closed}) do
    nil
  end

  def generate_message({:canceled, :failed, :draft}) do
    nil
  end

  def generate_message({:canceled, :failed, _reason}) do
    "Bors build canceled.\n\nAddress comments or fix if necessary, and then someone with permission can run `bors r+`."
  end

  def generate_message({:canceled, :retrying}) do
    "This PR was included in a batch that was canceled, it will be automatically retried"
  end

  def generate_message({:push_failed_non_ff, target_branch}) do
    "This PR was included in a batch that successfully built, but then failed to merge into #{target_branch} (it was a non-fast-forward update). It will be automatically retried."
  end

  def generate_message(
        {:push_failed_unknown_failure, target_branch, status_code, raw_error_content}
      ) do
    """
    This PR was included in a batch that successfully built, but then failed to merge into #{target_branch}. It will not be retried.

    Additional information:

    ```json
    Response status code: #{status_code}
    #{raw_error_content}
    ```
    """
  end

  def generate_message({:linked, xrefs}) do
    prs = Enum.map_join(xrefs, ", ", &"##{&1}")

    "This pull request is part of a linked bundle: #{prs}.\n\nLinked pull requests merge in the same batch, or not at all. Each one still needs its own `bors r+`; `bors unlink` removes the link."
  end

  def generate_message(:unlinked) do
    "This pull request is no longer linked; it will merge on its own."
  end

  def generate_message({:unlinked, :fresh_approval_needed}) do
    "This pull request is no longer linked. The approval it held for the bundle was discarded, so it needs a fresh `bors r+` to merge on its own."
  end

  def generate_message(:try_ignores_bundle) do
    "Note: `bors try` builds this pull request without the rest of its bundle, so its result may differ from the bundle's batch."
  end

  def generate_message({:stacked, child_xref, parent_xref, compare_url}) do
    "##{child_xref} is now stacked on ##{parent_xref}: both are in a linked bundle and merge in the same batch, or not at all. The batch applies ##{parent_xref}'s changes first ([##{child_xref}'s own changes](#{compare_url})). Each pull request still needs its own `bors r+`; `bors unlink` removes the link."
  end

  def generate_message({:bundle_base_edit_mismatch, xref}) do
    "The base branch of ##{xref} changed, so its linked bundle no longer resolves to a single target branch. Bors can't queue the bundle until its members share one base again. Restore ##{xref}'s base, or `bors unlink` to split the bundle."
  end

  def generate_message({:bundle_waiting, xrefs}) do
    prs = Enum.map_join(xrefs, ", ", &"##{&1}")

    ":clock1: Waiting for approval (`bors r+`) of: #{prs}. The bundle enters the queue once every linked pull request is approved."
  end

  def generate_message({:bundle_held, xref}) do
    ":clock1: Waiting on ##{xref} before the bundle can queue; see that pull request for details."
  end

  def generate_message({:bundle_last_unapproved, :awaiting_review}) do
    "The rest of the bundle is approved; it enters the queue once this pull request gets `bors r+`."
  end

  def generate_message({:bundle_last_unapproved, :draft}) do
    "The rest of the bundle is approved; it enters the queue once this pull request leaves draft and gets a fresh `bors r+`."
  end

  def generate_message({:bundle_last_unapproved, :closed}) do
    "The rest of the bundle is approved, but this pull request is closed. Reopen it and run `bors r+`, or `bors unlink` from any linked pull request to let the others merge without it."
  end

  def generate_message({:bundle_pulled, xref, reason}) do
    what =
      case reason do
        :closed -> "was closed"
        :push -> "was pushed to"
        :draft -> "was converted to draft"
        _ -> "was canceled"
      end

    "This pull request left the queue because it is linked with ##{xref}, which #{what}.\n\nOnce ##{xref} is ready again (or after `bors unlink`), someone with permission can run `bors r+`."
  end

  def generate_message({:bundle_failed, xrefs, statuses}) do
    prs = Enum.map_join(xrefs, ", ", &"##{&1}")
    body = Enum.join(["Build failed:" | Enum.map(statuses, &"  * #{gen_status_link(&1)}")], "\n")

    body <>
      "\n\nThe linked bundle (#{prs}) failed to build, and bors can't tell which pull request is at fault. The whole set left the queue. Fix what is needed, then run `bors r+` on each member; the bundle re-queues once they are all approved again."
  end

  def generate_message(:draft_dropped_before_batch) do
    "This pull request left the queue without building because it is a draft.\n\nDrafts are never merged. Mark it ready for review, then someone with permission can run `bors r+` again."
  end

  def generate_message(:draft_dropped_from_batch) do
    "This pull request left the queue without merging because it is a draft. The rest of its batch was re-queued without it.\n\nDrafts are never merged. Mark it ready for review, then someone with permission can run `bors r+` again."
  end

  # No line may begin with the command trigger: bors parses its own comments,
  # so a draft would answer itself forever. `message_test.exs` holds that line.
  def generate_message({:draft_refused, blocked, also_dropped}) do
    rest =
      case Enum.reject(also_dropped, &pseudo_command?/1) do
        [] ->
          ""

        cmds ->
          " #{draft_refused_names(cmds)} did not run either: one blocked command stops the whole comment."
      end

    """
    :construction: This pull request is a draft, so bors took no action on #{draft_refused_names(blocked)}.#{rest}

    Mark it ready for review, then run the command again. Commands that cannot lead to a merge do still work on a draft: `try`, `try-`, `r-`, `unlink`, `delegate-` and `ping`.
    """
  end

  def generate_message({:malformed_args, :priority}) do
    ":-1: `p=` takes an integer, e.g. `bors p=10`."
  end

  def generate_message({:malformed_args, :priority_range}) do
    {min, max} = BorsNG.Command.priority_range()
    ":-1: `p=` takes an integer from #{min} to #{max}, e.g. `bors p=10`."
  end

  def generate_message({:malformed_args, :single}) do
    ":-1: `single` takes `on` or `off`, e.g. `bors single on`."
  end

  def generate_message({:malformed_args, {:delegate, typed, logins, for_tokens}}) do
    # `delegate`, `delegate+`, `d` or `d+`, as typed.
    [cmd] = Regex.run(~r/^(?:delegate|d)\+?/, typed)
    named = if String.starts_with?(cmd, "delegate"), do: "delegate=", else: "d="

    for_suffix = Enum.map_join(for_tokens, &" #{&1}")

    suggestion =
      case logins do
        [] ->
          "To delegate someone else, reply with `bors #{named}alice,bob#{for_suffix}`."

        _ ->
          "If you meant to delegate #{Enum.map_join(logins, ", ", &"`#{&1}`")}, reply with `bors #{named}#{Enum.join(logins, ",")}#{for_suffix}`."
      end

    ":-1: `bors #{cmd}` delegates the PR author and takes no names, so bors did not delegate anyone. #{suggestion} To delegate the PR author, reply with just `bors #{cmd}#{for_suffix}`."
  end

  def generate_message({:malformed_args, {:undelegate, typed, logins}}) do
    cmd = if String.starts_with?(typed, "delegate"), do: "delegate-", else: "d-"

    suggestion =
      case logins do
        [] ->
          "To remove only some, reply with `bors #{cmd}=alice,bob`."

        _ ->
          "If you meant to remove only #{Enum.map_join(logins, ", ", &"`#{&1}`")}, reply with `bors #{cmd}=#{Enum.join(logins, ",")}`."
      end

    ":-1: `bors #{cmd}` takes no arguments, so bors did not remove any delegations. #{suggestion} To remove every delegation, reply with just `bors #{cmd}`."
  end

  def generate_message({:malformed_args, {:no_names, typed}}) when typed in ["r=", "merge="] do
    self_cmd = if typed == "r=", do: "r+", else: "merge"

    ":-1: `bors #{typed}` needs the reviewers to approve on behalf of, e.g. `bors #{typed}alice`. To approve as yourself, reply with `bors #{self_cmd}`."
  end

  def generate_message({:malformed_args, {:no_names, typed}})
      when typed in ["d-=", "delegate-="] do
    ":-1: `bors #{typed}` needs the users whose delegation to remove, e.g. `bors #{typed}alice`. To remove every delegation, reply with `bors #{String.trim_trailing(typed, "=")}`."
  end

  def generate_message({:malformed_args, {:no_names, typed}}) do
    self_cmd = if String.starts_with?(typed, "delegate"), do: "delegate+", else: "d+"

    ":-1: `bors #{typed}` needs the users to delegate, e.g. `bors #{typed}alice,bob`. To delegate the PR author, reply with `bors #{self_cmd}`."
  end

  def generate_message({:malformed_args, {:leftover, typed, understood, rest}}) do
    # `r=alice bob` most likely meant two reviewers.
    commas =
      case String.split(understood, "=", parts: 2) do
        [cmd, names] when cmd in ["r", "merge"] ->
          if String.contains?(names, " "),
            do: "",
            else:
              " To name several reviewers, separate them with commas, e.g. `bors #{cmd}=alice,bob`."

        _ ->
          ""
      end

    ":-1: bors did not run `bors #{typed}`: `bors #{understood}` takes nothing after it, but `#{rest}` followed. Reply with just `bors #{understood}`, and put any other command on a line of its own.#{commas}"
  end

  def generate_message({:malformed_args, {:bad_names, typed, bad}}) do
    what =
      if match?([_], bad), do: "cannot be a GitHub username", else: "cannot be GitHub usernames"

    ":-1: bors did not run `bors #{typed}`: #{Enum.map_join(bad, ", ", &"`#{&1}`")} #{what}. Put any other command on a line of its own."
  end

  def generate_message({:delegation_refused, :unknown_users, [login]}) do
    ":-1: There is no GitHub user named `#{login}`, so bors made no delegation changes. Check the spelling and try again."
  end

  def generate_message({:delegation_refused, :unknown_users, logins}) do
    ":-1: There are no GitHub users named #{Enum.map_join(logins, ", ", &"`#{&1}`")}, so bors made no delegation changes. Check the spelling and try again."
  end

  def generate_message({:delegation_refused, :lookup_failed, logins}) do
    ":-1: bors could not look up #{Enum.map_join(logins, ", ", &"`#{&1}`")} on GitHub, so it made no delegation changes. Try again in a few minutes."
  end

  def generate_message({:link_error, :nothing_to_link}) do
    ":-1: Nothing to link: give at least one other pull request number, e.g. `bors link #123`."
  end

  def generate_message({:link_error, :not_found}) do
    ":-1: Cannot link: some of those pull request numbers are unknown to bors for this repository."
  end

  def generate_message({:link_error, :closed}) do
    ":-1: Cannot link: all linked pull requests must be open."
  end

  def generate_message({:link_error, :already_merged}) do
    ":-1: Cannot link: bors has already merged one of these pull requests. A merged pull request cannot be approved again, so its bundle would wait forever."
  end

  def generate_message({:link_error, :branch_mismatch}) do
    ":-1: Cannot link: all linked pull requests must target the same base branch."
  end

  def generate_message({:link_error, :in_batch}) do
    ":-1: Cannot change links while an affected pull request is queued or running. Cancel it first with `bors r-`."
  end

  def generate_message({:link_error, :stack_usage}) do
    ":-1: `bors stack` takes exactly one pull request number, e.g. `bors stack #123`."
  end

  def generate_message({:link_error, :self_stack}) do
    ":-1: Cannot stack this pull request on itself. Name the pull request it builds on, e.g. `bors stack #123`."
  end

  def generate_message({:link_error, :cycle}) do
    ":-1: Cannot stack: that would create a cycle in the stacking order."
  end

  def generate_message({:link_error, {:not_rebased, parent_xref}}) do
    ":-1: Cannot stack: this pull request's branch does not contain the current head of ##{parent_xref}. Rebase it onto ##{parent_xref} and run `bors stack` again."
  end

  def generate_message({:link_error, {:stack_reversed, target_xref, child_xref}}) do
    ":-1: Cannot stack: ##{target_xref} contains this pull request's head, so the stack appears to go the other way. Comment `bors stack ##{child_xref}` on ##{target_xref} instead."
  end

  def generate_message({:link_error, {:malformed_refs, cmd, tokens}}) do
    list = Enum.map_join(tokens, ", ", &"`#{&1}`")

    ":-1: Could not read #{list} in `bors #{cmd}`. Give pull request numbers, like `bors #{cmd} #123`; any other bors command goes on its own line."
  end

  def generate_message({:link_error, :unlink_args}) do
    ":-1: `bors unlink` takes nothing after it: it dissolves this pull request's whole bundle. To drop one member, `bors unlink` and then `bors link` the ones that still belong together."
  end

  def generate_message({:stack_stale, child_xref, parent_xref}) do
    "The bundle was not queued: bors could not verify that ##{child_xref} contains the current head of ##{parent_xref}. Rebase ##{child_xref} onto ##{parent_xref} if needed, then run `bors r+` on it again."
  end

  def generate_message({:link_error, :cannot_infer}) do
    ":-1: Could not infer which open pull request this one stacks on: the base branch must match the head branch of exactly one open pull request. Pass the number, e.g. `bors stack #123`."
  end

  def generate_message({:retargeted, branch}) do
    "bors changed this pull request's base branch to `#{branch}`, the target branch of its bundle."
  end

  def generate_message({:stack_retarget_failed, xref}) do
    "The bundle was not queued: bors could not change the base branch of ##{xref} to the bundle's target branch. Run `bors r+` again to retry."
  end

  def generate_message({:base_restored, branch}) do
    "bors restored this pull request's base branch to `#{branch}`, undoing the change made when its bundle was queued."
  end

  def generate_message({:base_restore_failed, branch}) do
    "bors could not restore this pull request's base branch to `#{branch}` (it was changed when its bundle was queued). Please check the base branch."
  end

  def generate_message({state, statuses}) do
    is_new_year = get_is_new_year()
    is_public = get_is_public()

    msg =
      case state do
        :succeeded when is_public ->
          """
            Build succeeded!

            The publicly hosted instance of bors-ng is deprecated and will go away soon.

            If you want to self-host your own instance, [instructions are here][instructions].
            For more help, visit [the forum].

            If you want to switch to GitHub's built-in merge queue, visit [their help page][gh].

            [instructions]: https://github.com/bors-ng/bors-ng#how-to-set-up-your-own-real-instance
            [the forum]: https://forum.bors.tech
            [gh]: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue\n\n
          """

        :succeeded when is_new_year ->
          "Build succeeded!\n\n*And happy new year! 🎉*\n\n"

        :succeeded ->
          "Build succeeded:"

        :failed ->
          "Build failed:"

        :try_failed ->
          "Build failed:"

        :retrying ->
          "Build failed (retrying...):"
      end

    body =
      ([msg] ++ Enum.map(statuses, &"  * #{gen_status_link(&1)}"))
      |> Enum.join("\n")

    case state do
      :failed ->
        body <>
          "\n\nFix if necessary, and then someone with permission can run `bors r+` or `bors retry`."

      :try_failed ->
        body <> "\n\nFix if necessary, and then run `bors try` again."

      _ ->
        body
    end
  end

  def generate_message({:merged, :squashed, target_branch, statuses}) do
    status_msg = generate_message({:succeeded, statuses})
    "Pull request successfully merged into #{target_branch}.\n\n#{status_msg}"
  end

  # Bundle comments carry a trailing link to the bundle's page in the bors
  # dashboard, so a reader can jump from any member's pull request to the whole
  # bundle: its members, approval state, and batches. The URL is built by the
  # caller (which has the router helpers); this module only owns the wording.
  @bundle_page_messages [
    :bundle_conflict,
    :bundle_timeout,
    :linked,
    :stacked,
    :try_ignores_bundle,
    :bundle_waiting,
    :bundle_held,
    :bundle_last_unapproved,
    :bundle_pulled,
    :bundle_failed,
    :stack_stale,
    :stack_retarget_failed,
    :retargeted
  ]

  @doc """
  Whether a comment for `message` should link to its bundle's page. True for
  messages that describe a bundle that still exists. False for link-rejection
  (`:link_error`), unlink, and base-restore messages, where there is no live
  bundle to point at.
  """
  def links_to_bundle?(message) when is_tuple(message),
    do: elem(message, 0) in @bundle_page_messages

  def links_to_bundle?(message) when is_atom(message),
    do: message in @bundle_page_messages

  def links_to_bundle?(_), do: false

  @doc """
  The trailing "view this bundle" link appended to bundle comments. `url` is
  built by the caller. A nil url yields an empty string so callers can append
  it unconditionally.

  The note about signing in is deliberate: the bundle page sits behind the bors
  dashboard's login, so any signed-in GitHub user can open it, but a signed-out
  reader following the link is bounced to a GitHub OAuth prompt rather than the
  page they expected.
  """
  def bundle_link_footer(nil), do: ""

  def bundle_link_footer(url),
    do: "\n\n[View this bundle in bors](#{url}) (sign in with GitHub to view)."

  @doc """
  Like `generate_message/1`, but appends the bundle-page link footer when
  `message` is one that links to its bundle (see `links_to_bundle?/1`).
  `bundle_url` is built by the caller (which has the router helpers); pass
  nil when there is no bundle page to point at.
  """
  def generate_message(message, bundle_url) do
    case generate_message(message) do
      nil ->
        nil

      body ->
        if links_to_bundle?(message),
          do: body <> bundle_link_footer(bundle_url),
          else: body
    end
  end

  def gen_status_link(status) do
    case status.url do
      nil -> status.identifier
      url -> "[#{status.identifier}](#{url})"
    end
  end

  def generate_squash_commit_message(pr, commits, user_email, user_name, cut_body_after) do
    message_body = cut_body(pr.body, cut_body_after)

    commit_co_authors =
      commits
      |> Enum.filter(&(&1.author_email != user_email && &1.author_name != user_name))
      |> Enum.map(&"Co-authored-by: #{&1.author_name} <#{&1.author_email}>")
      |> Enum.join("\n")

    # possible TODO: get Co-authored-by lines from each commit message?
    # cf. https://github.com/bors-ng/bors-ng/issues/987

    # filter out Co-authored-by lines from message_body and attach to co_authors
    # possible TODO: transform @login to username <email>
    # cf. https://github.com/bors-ng/bors-ng/issues/1041
    {body_co_authors, message_body} = filter_lines(message_body, ~r/^Co-authored-by: /)
    # join body_co_authors to commit_co_authors and then remove all empty lines
    co_authors =
      (body_co_authors <> "\n" <> commit_co_authors)
      |> String.split("\n")
      |> Enum.uniq()
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    "#{pr.title} (##{pr.number})\n\n#{String.trim(message_body)}\n\n#{co_authors}\n"
  end

  defp draft_refused_names(cmds) do
    cmds
    |> Enum.map(&draft_refused_name/1)
    |> Enum.uniq()
    |> Enum.map_join(", ", &"`bors #{&1}`")
  end

  defp draft_refused_name(:activate), do: "r+"
  defp draft_refused_name({:activate_by, username}), do: "r=#{username}"
  defp draft_refused_name({:set_priority, priority}), do: "p=#{priority}"
  defp draft_refused_name({:set_is_single, true}), do: "single on"
  defp draft_refused_name({:set_is_single, false}), do: "single off"
  defp draft_refused_name(:delegate), do: "delegate+"
  defp draft_refused_name({:delegate, _duration}), do: "delegate+"
  defp draft_refused_name({:delegate_to, login}), do: "delegate=#{login}"
  defp draft_refused_name({:delegate_to, login, _duration}), do: "delegate=#{login}"
  defp draft_refused_name({:link, _}), do: "link"
  defp draft_refused_name({:stack, _}), do: "stack"
  defp draft_refused_name({:link_malformed, cmd, _}), do: to_string(cmd)
  defp draft_refused_name({:malformed_args, :priority}), do: "p="
  defp draft_refused_name({:malformed_args, :priority_range}), do: "p="
  defp draft_refused_name({:malformed_args, {:delegate, typed, _, _}}), do: typed
  defp draft_refused_name({:malformed_args, {:no_names, typed}}), do: typed
  defp draft_refused_name({:malformed_args, {:leftover, typed, _, _}}), do: typed
  defp draft_refused_name({:malformed_args, {:bad_names, typed, _}}), do: typed
  defp draft_refused_name({:malformed_args, :single}), do: "single"
  defp draft_refused_name(:retry), do: "retry"

  # The tags below do not spell their own command. Every one of them is a
  # command `draft_blocked?/1` *allows* on a draft, so they reach this module
  # only through `also_dropped` — which is exactly the list the message tells
  # the reader to run again. Naming them after the tag hands back text that
  # parses to nothing (`bors deactivate`, `bors try_cancel`).
  defp draft_refused_name(:deactivate), do: "r-"
  defp draft_refused_name(:try_cancel), do: "try-"
  defp draft_refused_name(:undelegate), do: "delegate-"
  defp draft_refused_name({:undelegate_to, login}), do: "delegate-=#{login}"
  # Named as typed: run again, it gets the hint rather than removing them all.
  defp draft_refused_name({:malformed_args, {:undelegate, typed, _}}), do: typed
  defp draft_refused_name(:unlink_with_args), do: "unlink"

  defp draft_refused_name(cmd) when is_atom(cmd), do: to_string(cmd)

  # `draft_blocked?/1` blocks every command it does not recognize, so a newly
  # added one arrives here with no clause of its own. Name it after its tag
  # rather than raising inside the webhook.
  defp draft_refused_name(cmd) when is_tuple(cmd), do: cmd |> elem(0) |> to_string()

  # Neither of these is a command anyone typed, so neither belongs in a list
  # headed "did not run either". `:autocorrect` is bors guessing at a typo —
  # naming it would print the suggestion, which for `bors +r` is the very
  # `bors r+` the sentence before it already refused — and `:bros` is the
  # alternate trigger, not a command, so there is no `bors bros` to re-run.
  defp pseudo_command?({:autocorrect, _}), do: true
  defp pseudo_command?(:bros), do: true
  defp pseudo_command?(_), do: false

  defp filter_lines(text, regex) do
    {matching, remaining} =
      text
      |> String.split("\n")
      |> Enum.split_with(&Regex.match?(regex, &1))

    {Enum.join(matching, "\n"), Enum.join(remaining, "\n")}
  end

  def generate_commit_message(
        patch_links,
        cut_body_after,
        co_authors,
        template \\ "Merge ${PR_REFS}"
      ) do
    pr_refs =
      patch_links
      |> Enum.map(&"\##{&1.patch.pr_xref}")
      |> Enum.join(" ")

    commit_title = String.replace(template, "${PR_REFS}", pr_refs)

    commit_body =
      Enum.reduce(patch_links, "", fn link, acc ->
        body =
          link.patch.body
          |> cut_body(cut_body_after)
          |> suppress_pings()

        author =
          case link.patch.author do
            nil -> "[unknown]"
            author -> author.login
          end

        reviewer = link.reviewer
        title = link.patch.title
        number = link.patch.pr_xref

        """
        #{acc}
        #{number}: #{title} r=#{reviewer} a=#{author}

        #{body}
        """
      end)

    co_author_trailers =
      co_authors
      |> Enum.map(&"Co-authored-by: #{&1}")
      |> Enum.join("\n")

    "#{commit_title}\n#{commit_body}\n#{co_author_trailers}\n"
  end

  def cut_body(nil, _), do: ""
  def cut_body(body, nil), do: body

  def cut_body(body, cut) do
    # HACK: we put a newline at the start of the string so that, e.g.
    # cut = "\n---" will cut even if "---" is at the start of body
    ("\n" <> body)
    |> String.splitter(cut)
    |> Enum.at(0)
    |> String.trim()
  end

  def suppress_pings(nil), do: nil

  def suppress_pings(body) do
    Regex.replace(~r/\B(@\S+)/, body, ~S/`\g{1}`/, global: true)
  end

  # Must render every key BorsToml/GetBorsToml can emit. The catch-all below
  # guarantees no crash; the message_test introspection guarantees every key in
  # the spec domain has an explicit, friendly clause rather than the fallback.
  @spec generate_bors_toml_error(BorsToml.err() | :fetch_failed) :: binary
  def generate_bors_toml_error(:parse_failed) do
    "bors.toml: syntax error"
  end

  def generate_bors_toml_error(:empty_config) do
    "bors.toml: does not specify anything to gate on"
  end

  def generate_bors_toml_error(:fetch_failed) do
    "bors.toml: not found"
  end

  def generate_bors_toml_error(:timeout_sec) do
    "bors.toml: expected timeout_sec to be an integer"
  end

  def generate_bors_toml_error(:required_approvals) do
    "bors.toml: expected required_approvals to be an integer"
  end

  def generate_bors_toml_error(:status) do
    "bors.toml: expected status to be a list"
  end

  # NB: the validator emits :block_labels (see BorsToml), not :blocked_labels.
  def generate_bors_toml_error(:block_labels) do
    "bors.toml: expected block_labels to be a list"
  end

  def generate_bors_toml_error(:pr_status) do
    "bors.toml: expected pr_status to be a list"
  end

  def generate_bors_toml_error(:prerun_timeout_sec) do
    "bors.toml: expected prerun_timeout_sec to be an integer"
  end

  def generate_bors_toml_error(:cut_body_after) do
    "bors.toml: expected cut_body_after to be a string"
  end

  def generate_bors_toml_error(:commit_title) do
    "bors.toml: expected commit_title to be a string"
  end

  def generate_bors_toml_error(:committer_details) do
    "bors.toml: committer must specify both name and email"
  end

  def generate_bors_toml_error(:max_batch_size) do
    "bors.toml: expected max_batch_size to be an integer"
  end

  def generate_bors_toml_error(:delegation_default_expiry_sec) do
    "bors.toml: expected [delegation] default_expiry_sec to be a positive integer " <>
      "of at most 90 days (in seconds)"
  end

  def generate_bors_toml_error(:delegation_invalidate_on_paths) do
    "bors.toml: expected [delegation] invalidate_on_paths to be a list of glob patterns"
  end

  def generate_bors_toml_error(:delegation_restrict_to_paths) do
    "bors.toml: expected [delegation] restrict_to_paths to be a list of glob patterns"
  end

  def generate_bors_toml_error(:labels) do
    "bors.toml: expected each [labels] entry (on_queue, building, failed, delegated) " <>
      "to be a non-empty string"
  end

  def generate_bors_toml_error(:label_names_not_distinct) do
    "bors.toml: each [labels] entry (on_queue, building, failed, delegated) " <>
      "must use a distinct label name"
  end

  # Catch-all so a future validation key can never crash the renderer (and the
  # batcher with it) the way the unhandled keys above silently did. Prefer an
  # explicit clause with friendly wording over relying on this.
  def generate_bors_toml_error(key) do
    "bors.toml: invalid configuration (#{key})"
  end

  def get_is_new_year do
    celebrate_new_year = Application.get_env(:bors, :celebrate_new_year)
    %{month: month, day: day} = DateTime.utc_now()

    case {celebrate_new_year, month, day} do
      {true, 12, 31} -> true
      {true, 1, 1} -> true
      {true, 1, 2} -> true
      _ -> false
    end
  end

  def get_is_public do
    System.get_env("PUBLIC_HOST") === "app.bors.tech"
  end
end
