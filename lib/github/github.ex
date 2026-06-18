require Logger

defmodule BorsNG.GitHub do
  @moduledoc """
  Wrappers around the GitHub REST API.
  """

  @typedoc """
  An authentication token;
  this may be a raw token (as on oAuth)
  or an installation xref (in which case the server will look it up).
  """
  @type ttoken :: {:installation, number} | {:raw, binary}

  @typedoc """
  A repository connection;
  it packages a repository with the permissions to access it.
  """
  @type tconn :: {ttoken, number} | {ttoken, number}

  @type tuser :: BorsNG.GitHub.User.t()
  @type trepo :: BorsNG.GitHub.Repo.t()
  @type tpr :: BorsNG.GitHub.Pr.t()
  @type tstatus :: :ok | :running | :error
  @type trepo_perm :: BorsNG.Database.ProjectPermission.trepo_perm()
  @type tuser_repo_perms :: BorsNG.Database.ProjectPermission.tuser_repo_perms()
  @type tcollaborator :: %{user: tuser, perms: tuser_repo_perms}
  @type tcommitter :: %{name: bitstring, email: bitstring}

  @spec get_pr_files!(tconn, integer) :: [BorsNG.GitHub.File.t()]
  def get_pr_files!(repo_conn, pr_xref) do
    {:ok, pr} = get_pr_files(repo_conn, pr_xref)
    pr
  end

  @spec get_pr_files(tconn, integer) ::
          {:ok, [BorsNG.GitHub.File.t()]} | {:error, term}
  def get_pr_files(repo_conn, pr_xref) do
    call_with_retry(:get_pr_files, repo_conn, {pr_xref}, 500, 4_000)
  end

  @spec get_pr_compare(tconn, binary, binary) ::
          {:ok, [BorsNG.GitHub.File.t()]} | {:error, term}
  def get_pr_compare(repo_conn, base, head) do
    call_with_retry(:get_pr_compare, repo_conn, {base, head}, 500, 4_000)
  end

  @spec get_pr!(tconn, integer | bitstring) :: BorsNG.GitHub.Pr.t()
  def get_pr!(repo_conn, pr_xref) do
    {:ok, pr} = get_pr(repo_conn, pr_xref)
    pr
  end

  @spec get_pr(tconn, integer | bitstring) ::
          {:ok, BorsNG.GitHub.Pr.t()} | {:error, term}
  def get_pr(repo_conn, pr_xref) do
    call_with_retry(:get_pr, repo_conn, {pr_xref}, 500, 4_000)
  end

  @spec update_pr_base!(tconn, BorsNG.GitHub.Pr.t()) :: BorsNG.GitHub.Pr.t()
  def update_pr_base!(repo_conn, pr) do
    {:ok, pr} = update_pr_base(repo_conn, pr)
    pr
  end

  @spec update_pr!(tconn, BorsNG.GitHub.Pr.t()) :: BorsNG.GitHub.Pr.t()
  def update_pr!(repo_conn, pr) do
    {:ok, pr} = update_pr(repo_conn, pr)
    pr
  end

  @spec update_pr_base(tconn, BorsNG.GitHub.Pr.t()) ::
          {:ok, BorsNG.GitHub.Pr.t()} | {:error, term}
  def update_pr_base(repo_conn, pr) do
    GenServer.call(
      BorsNG.GitHub,
      {:update_pr_base, repo_conn, pr},
      Confex.fetch_env!(:bors, :api_github_timeout)
    )
  end

  @spec update_pr(tconn, BorsNG.GitHub.Pr.t()) ::
          {:ok, BorsNG.GitHub.Pr.t()} | {:error, term}
  def update_pr(repo_conn, pr) do
    GenServer.call(
      BorsNG.GitHub,
      {:update_pr, repo_conn, pr},
      Confex.fetch_env!(:bors, :api_github_timeout)
    )
  end

  @spec get_pr_commits!(tconn, integer | bitstring) :: [BorsNG.GitHub.Commit.t()]
  def get_pr_commits!(repo_conn, pr_xref) do
    {:ok, commits} = get_pr_commits(repo_conn, pr_xref)
    commits
  end

  @spec get_pr_commits(tconn, integer | bitstring) ::
          {:ok, [BorsNG.GitHub.Commit.t()]} | {:error, term}
  def get_pr_commits(repo_conn, pr_xref) do
    call_with_retry(:get_pr_commits, repo_conn, {pr_xref}, 500, 4_000)
  end

  @spec get_open_prs!(tconn) :: [tpr]
  def get_open_prs!(repo_conn) do
    {:ok, prs} =
      GenServer.call(
        BorsNG.GitHub,
        {:get_open_prs, repo_conn, {}},
        Confex.fetch_env!(:bors, :api_github_timeout)
      )

    prs
  end

  @spec get_open_prs_with_base!(tconn, binary) :: [tpr]
  def get_open_prs_with_base!(repo_conn, base) do
    {:ok, prs} =
      GenServer.call(
        BorsNG.GitHub,
        {:get_open_prs_with_base, repo_conn, {base}},
        Confex.fetch_env!(:bors, :api_github_timeout)
      )

    prs
  end

  @spec push!(tconn, binary, binary) :: binary
  def push!(repo_conn, sha, to) do
    {:ok, sha} =
      GenServer.call(
        BorsNG.GitHub,
        {:push, repo_conn, {sha, to}},
        Confex.fetch_env!(:bors, :api_github_timeout)
      )

    sha
  end

  @spec push(tconn, binary, binary) :: {:ok, binary} | {:error, term, term, term}
  def push(repo_conn, sha, to) do
    GenServer.call(
      BorsNG.GitHub,
      {:push, repo_conn, {sha, to}},
      Confex.fetch_env!(:bors, :api_github_timeout)
    )
  end

  @spec get_branch!(tconn, binary) :: %{commit: bitstring, tree: bitstring}
  def get_branch!(repo_conn, from) do
    {:ok, commit} = call_with_retry(:get_branch, repo_conn, {from}, 500, 4_000)
    commit
  end

  @spec delete_branch!(tconn, binary) :: :ok
  def delete_branch!(repo_conn, branch) do
    :ok = call_with_retry(:delete_branch, repo_conn, {branch})
    :ok
  end

  @spec merge_branch!(tconn, %{
          from: bitstring,
          to: bitstring,
          commit_message: bitstring
        }) :: %{commit: binary, tree: binary} | :conflict
  def merge_branch!(repo_conn, info) do
    {:ok, commit} = call_with_retry(:merge_branch, repo_conn, {info})
    commit
  end

  @spec synthesize_commit!(tconn, %{
          branch: bitstring,
          tree: bitstring,
          parents: [bitstring],
          commit_message: bitstring,
          committer: tcommitter | nil
        }) :: binary
  def synthesize_commit!(repo_conn, info) do
    {:ok, sha} = call_with_retry(:synthesize_commit, repo_conn, {info}, 500, 4_000)
    sha
  end

  @spec create_commit!(tconn, %{
          tree: bitstring,
          parents: [bitstring],
          commit_message: bitstring,
          committer: tcommitter | nil
        }) :: binary
  def create_commit!(repo_conn, info) do
    {:ok, sha} = create_commit(repo_conn, info)

    sha
  end

  @spec create_commit(tconn, %{
          tree: bitstring,
          parents: [bitstring],
          commit_message: bitstring,
          committer: tcommitter | nil
        }) :: {:ok, binary} | {:error, term, term, term, term}
  def create_commit(repo_conn, info) do
    call_with_retry(:create_commit, repo_conn, {info})
  end

  @spec get_file(tconn, binary, binary) :: {:ok, binary | nil} | {:error, term}
  def get_file(repo_conn, branch, path) do
    call_with_retry(:get_file, repo_conn, {branch, path}, 500, 4_000)
  end

  @spec get_repo_tree(tconn, binary) ::
          {:ok, [binary]} | {:ok, {:truncated, binary}} | {:error, term}
  def get_repo_tree(repo_conn, branch) do
    call_with_retry(:get_repo_tree, repo_conn, {branch}, 500, 4_000)
  end

  @spec force_push!(tconn, binary, binary) :: binary
  def force_push!(repo_conn, sha, to) do
    {:ok, sha} = call_with_retry(:force_push, repo_conn, {sha, to}, 500, 4_000)
    sha
  end

  @spec get_commit_status!(tconn, binary) :: %{
          binary => tstatus
        }
  def get_commit_status!(repo_conn, sha) do
    {:ok, status} = get_commit_status(repo_conn, sha)

    status
  end

  @spec get_commit_status(tconn, binary) :: {:ok, %{binary => tstatus}} | {:error, term}
  def get_commit_status(repo_conn, sha) do
    call_with_retry(:get_commit_status, repo_conn, {sha}, 500, 4_000)
  end

  @spec get_labels!(tconn, integer | bitstring) :: [bitstring]
  def get_labels!(repo_conn, issue_xref) do
    {:ok, labels} = get_labels(repo_conn, issue_xref)

    labels
  end

  @spec get_labels(tconn, integer | bitstring) :: {:ok, [bitstring]} | {:error, term}
  def get_labels(repo_conn, issue_xref) do
    call_with_retry(:get_labels, repo_conn, {issue_xref}, 500, 4_000)
  end

  @doc """
  Add labels to a PR or issue. Idempotent: GitHub does not duplicate a label
  that is already present. An empty list is a no-op (no API call).
  """
  @spec add_labels(tconn, integer | bitstring, [bitstring]) :: :ok | {:error, term}
  def add_labels(_repo_conn, _issue_xref, []), do: :ok

  def add_labels(repo_conn, issue_xref, labels) when is_list(labels) do
    call_with_retry(:add_labels, repo_conn, {issue_xref, labels}, 500, 4_000)
  end

  @doc """
  Remove a single label from a PR or issue. Idempotent: a label that is already
  absent (GitHub responds `404`) is treated as success.
  """
  @spec remove_label(tconn, integer | bitstring, bitstring) :: :ok | {:error, term}
  def remove_label(repo_conn, issue_xref, label) do
    call_with_retry(:remove_label, repo_conn, {issue_xref, label}, 500, 4_000)
  end

  @doc """
  List the open issues/PRs in the repo that currently carry `label`, each paired
  with its full set of label names (as the GitHub issues endpoint returns them).

  Drives the label backstop sweep (LIFECYCLE_LABELS.md): the labels in the
  response feed a diff against bors's own state, so a sweep that finds no drift
  performs no writes.
  """
  @spec list_issues_by_label(tconn, bitstring) ::
          {:ok, [{integer, [bitstring]}]} | {:error, term}
  def list_issues_by_label(repo_conn, label) do
    call_with_retry(:list_issues_by_label, repo_conn, {label}, 500, 4_000)
  end

  @spec get_reviews!(tconn, integer | bitstring) :: map
  def get_reviews!(repo_conn, issue_xref) do
    {:ok, labels} = get_reviews(repo_conn, issue_xref)

    labels
  end

  @spec get_reviews(tconn, integer | bitstring) :: {:ok, map} | {:error, term}
  def get_reviews(repo_conn, issue_xref) do
    call_with_retry(:get_reviews, repo_conn, {issue_xref}, 500, 4_000)
  end

  @spec get_commit_reviews!(tconn, integer | bitstring, binary) :: map
  def get_commit_reviews!(repo_conn, issue_xref, sha) do
    {:ok, labels} = get_commit_reviews(repo_conn, issue_xref, sha)

    labels
  end

  @spec get_commit_reviews(tconn, integer | bitstring, binary) :: {:ok, map} | {:error, term}
  def get_commit_reviews(repo_conn, issue_xref, sha) do
    call_with_retry(:get_reviews, repo_conn, {issue_xref, sha}, 500, 4_000)
  end

  @spec get_file!(tconn, binary, binary) :: binary | nil
  def get_file!(repo_conn, branch, path) do
    case call_with_retry(:get_file, repo_conn, {branch, path}, 500, 4_000) do
      {:ok, file} ->
        file

      {:error, :get_file, status, _body, request_id} ->
        Logger.warning(
          "get_file!(#{path}): failed with status #{status}, request_id=#{inspect(request_id)}"
        )

        nil

      {:error, :get_file} ->
        Logger.warning("get_file!(#{path}): failed")
        nil

      {:error, reason, _} ->
        Logger.warning("get_file!(#{path}): failed with #{inspect(reason)}")
        nil

      {:error, reason, _, _} ->
        Logger.warning("get_file!(#{path}): failed with #{inspect(reason)}")
        nil

      {:error, reason, _, _, _} ->
        Logger.warning("get_file!(#{path}): failed with #{inspect(reason)}")
        nil

      {:error, reason} ->
        Logger.warning("get_file!(#{path}): failed with #{inspect(reason)}")
        nil
    end
  end

  @spec post_comment(tconn, number, binary) :: :ok | {:error, term}
  def post_comment(repo_conn, number, body) do
    call_with_retry(:post_comment, repo_conn, {number, body}, 500, 4_000)
  end

  @spec post_comment!(tconn, number, binary) :: :ok
  def post_comment!(repo_conn, number, body) do
    :ok = call_with_retry(:post_comment, repo_conn, {number, body}, 500, 4_000)
    :ok
  end

  @spec get_pr_comments(tconn, number) :: {:ok, [binary]} | {:error, term}
  def get_pr_comments(repo_conn, number) do
    call_with_retry(:get_pr_comments, repo_conn, {number}, 500, 4_000)
  end

  @spec post_commit_status(tconn, {binary, tstatus, binary, binary}) :: :ok | {:error, term}
  def post_commit_status(repo_conn, {sha, status, msg, url}) do
    call_with_retry(:post_commit_status, repo_conn, {sha, status, msg, url}, 500, 4_000)
  end

  @spec post_commit_status!(tconn, {binary, tstatus, binary, binary}) :: :ok
  def post_commit_status!(repo_conn, {sha, status, msg, url}) do
    :ok = call_with_retry(:post_commit_status, repo_conn, {sha, status, msg, url}, 500, 4_000)
    :ok
  end

  @spec get_user_by_login!(ttoken, binary) :: tuser | nil
  def get_user_by_login!(token, login) do
    {:ok, user} = get_user_by_login(token, login)
    user
  end

  @spec get_user_by_login(ttoken, binary) :: {:ok, tuser | nil} | {:error, term}
  def get_user_by_login(token, login) do
    GenServer.call(
      BorsNG.GitHub,
      {:get_user_by_login, token, {String.trim(login)}},
      Confex.fetch_env!(:bors, :api_github_timeout)
    )
  end

  @spec belongs_to_team?(tconn, String.t(), String.t(), String.t()) ::
          boolean
  def belongs_to_team?(repo_conn, org, team_slug, username) do
    GenServer.call(
      BorsNG.GitHub,
      {:belongs_to_team, repo_conn, {org, team_slug, username}},
      Confex.fetch_env!(:bors, :api_github_timeout)
    )
  end

  @spec get_collaborators_by_repo(tconn) ::
          {:ok, [tcollaborator]} | :error
  def get_collaborators_by_repo(repo_conn) do
    GenServer.call(
      BorsNG.GitHub,
      {:get_collaborators_by_repo, repo_conn, {}},
      Confex.fetch_env!(:bors, :api_github_timeout)
    )
  end

  @spec get_app!() :: String.t()
  def get_app! do
    {:ok, app_link} =
      GenServer.call(BorsNG.GitHub, :get_app, Confex.fetch_env!(:bors, :api_github_timeout))

    app_link
  end

  @spec get_installation_repos!(ttoken) :: [trepo]
  def get_installation_repos!(token) do
    {:ok, repos} =
      GenServer.call(
        BorsNG.GitHub,
        {:get_installation_repos, token, {}},
        Confex.fetch_env!(:bors, :api_github_timeout)
      )

    repos
  end

  @spec get_installation_list! :: [integer]
  def get_installation_list! do
    {:ok, installations} =
      GenServer.call(
        BorsNG.GitHub,
        :get_installation_list,
        Confex.fetch_env!(:bors, :api_github_timeout)
      )

    installations
  end

  @spec map_state_to_status(binary) :: tstatus
  def map_state_to_status(state) do
    case state do
      "pending" -> :running
      "success" -> :ok
      "neutral" -> :ok
      "skipped" -> :error
      "failure" -> :error
      "cancelled" -> :error
      "error" -> :error
    end
  end

  @spec map_check_to_status(binary) :: tstatus
  def map_check_to_status(conclusion) do
    case conclusion do
      nil -> :running
      "success" -> :ok
      _ -> :error
    end
  end

  @spec map_status_to_state(tstatus) :: binary
  def map_status_to_state(state) do
    case state do
      :running -> "pending"
      :ok -> "success"
      :error -> "failure"
    end
  end

  @spec map_changed_status(binary) :: binary
  def map_changed_status(check_name) do
    case check_name do
      "Travis CI - Branch" -> "continuous-integration/travis-ci/push"
      check_name -> check_name
    end
  end

  # Private function to handle retry logic with exponential backoff
  defp call_with_retry(action, repo_conn, params, min_delay \\ 1_000, max_delay \\ 5_000) do
    timeout = Confex.fetch_env!(:bors, :api_github_timeout)
    started_at = System.monotonic_time(:millisecond)

    do_call_with_retry(
      action,
      repo_conn,
      params,
      timeout,
      min_delay,
      max_delay,
      started_at
    )
  end

  defp do_call_with_retry(
         action,
         repo_conn,
         params,
         timeout,
         current_delay,
         max_delay,
         started_at
       ) do
    result = safe_genserver_call(action, repo_conn, params, timeout)

    if Application.get_env(:bors, :is_test) do
      result
    else
      case result do
        :ok ->
          Logger.info(
            "call_with_retry(#{action}): succeeded when current_delay was #{current_delay}"
          )

          :ok

        {:ok, _} = success ->
          Logger.info(
            "call_with_retry(#{action}): succeeded when current_delay was #{current_delay}"
          )

          success

        _ ->
          if retry_timeout_elapsed?(action, started_at) do
            Logger.warning(
              "call_with_retry(#{action}): giving up when current_delay was #{current_delay}"
            )

            result
          else
            delay = min(current_delay, max_delay)
            Process.sleep(add_jitter(delay))

            do_call_with_retry(
              action,
              repo_conn,
              params,
              timeout,
              min(current_delay * 2, max_delay),
              max_delay,
              started_at
            )
          end
      end
    end
  end

  defp safe_genserver_call(action, repo_conn, params, timeout) do
    GenServer.call(BorsNG.GitHub, {action, repo_conn, params}, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _}} ->
      {:error, :github_call_timeout, action}

    :exit, {:noproc, {GenServer, :call, _}} ->
      {:error, :github_server_unavailable, action}

    :exit, reason ->
      {:error, :github_call_exit, action, reason}
  end

  defp retry_timeout_elapsed?(action, started_at) do
    max_elapsed_ms = max_retry_elapsed_ms(action)
    System.monotonic_time(:millisecond) - started_at >= max_elapsed_ms
  end

  # Total wall-clock budget for the retry loop (not per-attempt; that's
  # :api_github_timeout). The two values are named "read"/"write" for the
  # common case, but the real axis is *how costly it is to give up*, which
  # comes down to two questions:
  #
  #   1. Is retrying safe? All reads are idempotent, so they qualify. Some
  #      writes are too — :post_commit_status, :force_push and :delete_branch
  #      are all last-write-wins — whereas :merge_branch, :synthesize_commit,
  #      :create_commit and :post_comment mutate fresh state, so a retry can
  #      duplicate work (a second comment, a stray commit). Those never get the
  #      long budget. But idempotency is necessary, not sufficient: it lets a
  #      write *onto* the list, it doesn't put it there. Question 2 decides that.
  #   2. What happens if we give up? The long budget is for calls where
  #      surrendering to a transient GitHub blip has a real cost. This is what
  #      separates the idempotent writes from each other: :post_commit_status is
  #      bors reporting its own status — what users and the `ci-success` gate
  #      watch — so a dropped update leaves a batch looking stuck; worth
  #      grinding. A failed :force_push / :delete_branch just makes the batcher
  #      re-run or re-clean the attempt cheaply, so they stay short. :get_pr_compare
  #      is the sharp read example: on failure classify_delegation/6 returns
  #      :unverifiable, which the merge-time gate treats as fail-closed and
  #      *blocks the merge*, forcing a human to re-issue `bors r+`. Grinding for
  #      three minutes beats that, so it sits on the long budget alongside its
  #      sibling :get_pr_files.
  #
  # Anything not listed (e.g. the advisory-lint reads :get_repo_tree and
  # :get_pr_comments, whose failure just skips a cosmetic warning) falls through
  # to the short budget — there's nothing worth tying up a worker three minutes
  # for. Add an action here only when giving up early would itself be harmful.
  defp max_retry_elapsed_ms(action)
       when action in [
              :get_branch,
              :get_file,
              :get_pr,
              :get_pr_compare,
              :get_pr_files,
              :get_pr_commits,
              :get_commit_status,
              :get_labels,
              :get_reviews,
              :post_commit_status
            ] do
    Confex.get_env(:bors, :api_github_retry_max_elapsed_ms, 180_000)
  end

  # Label operations are best-effort projections of bors's own state
  # (LIFECYCLE_LABELS.md): a dropped write is re-reconciled on the next
  # lifecycle event or backstop sweep, so it is never worth grinding retries
  # that serially block the batcher or the sweeps. The acute case is a missing
  # `issues: write` scope, where every call 403s and the write budget below
  # would burn ~10 attempts / ~30s apiece. The backstop's own label listing
  # rides the same budget: giving up early just means it re-runs next tick.
  # Give them all an essentially single-shot budget instead.
  defp max_retry_elapsed_ms(action)
       when action in [:add_labels, :remove_label, :list_issues_by_label] do
    Confex.get_env(:bors, :api_github_retry_label_max_elapsed_ms, 1_000)
  end

  defp max_retry_elapsed_ms(_action) do
    Confex.get_env(:bors, :api_github_retry_write_max_elapsed_ms, 30_000)
  end

  defp add_jitter(delay_ms) do
    delay_ms + :rand.uniform(250) - 1
  end
end
