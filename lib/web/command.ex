defmodule BorsNG.Command do
  @moduledoc """
  Resolve magic comments.

  # try

  The bors comment CLI allows parameters to be passed to try.
  Assuming the activation phrase is "bors try", you can do things like this:

      bors try --layout

  And the commit will come out like:

      Try #13: --layout

  Your build scripts should then inspect the commit message
  to pull out the commands.
  """

  alias BorsNG.Worker.Attemptor
  alias BorsNG.Worker.Batcher
  alias BorsNG.Command
  alias BorsNG.Database.Context.Delegation
  alias BorsNG.Database.Context.Logging
  alias BorsNG.Database.Context.Permission
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Repo
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.User
  alias BorsNG.GitHub
  alias BorsNG.Worker.DelegationInvalidator
  alias BorsNG.Worker.Syncer

  import BorsNG.Router.Helpers
  require Logger

  defstruct(
    project: nil,
    commenter: nil,
    pr: nil,
    pr_xref: nil,
    patch: nil,
    comment: ""
  )

  @type t :: %BorsNG.Command{
          project: Project.t(),
          commenter: User.t(),
          pr: map | nil,
          pr_xref: integer,
          patch: Patch.t() | nil,
          comment: binary
        }

  defp command_trigger(),
    do: Confex.fetch_env!(:bors, BorsNG)[:command_trigger]

  @doc """
  If the GitHub PR is not already in this struct, fetch it.
  """
  @spec fetch_pr(t) :: t
  def fetch_pr(c) do
    case {c.pr, c.pr_xref} do
      {nil, pr_xref} ->
        case c.project.repo_xref
             |> Project.installation_connection(Repo)
             |> GitHub.get_pr(pr_xref) do
          {:ok, pr} ->
            %Command{c | pr: pr}

          {:error, reason} ->
            Logger.warning("fetch_pr: failed for PR #{pr_xref}: #{inspect(reason)}")
            c
        end

      {_, _} ->
        c
    end
  end

  @doc """
  If the Patch is not already in this struct, fetch it.
  This will not re-sync from GitHub unless it isn't even in the database.
  """
  @spec fetch_patch(t) :: t
  def fetch_patch(c) do
    case {c.patch, c.pr, c.pr_xref} do
      {nil, nil, pr_xref} ->
        case Repo.get_by(Patch, project_id: c.project.id, pr_xref: pr_xref) do
          nil ->
            c = fetch_pr(c)

            case c.pr do
              nil -> c
              _ -> fetch_patch(c)
            end

          patch ->
            if is_nil(patch.author_id) and is_nil(c.pr) do
              c = fetch_pr(c)

              case c.pr do
                nil -> %Command{c | patch: patch}
                pr -> %Command{c | patch: Syncer.sync_patch(c.project.id, pr)}
              end
            else
              %Command{c | patch: patch}
            end
        end

      {nil, pr, _} ->
        patch = Syncer.sync_patch(c.project.id, pr)
        %Command{c | patch: patch}

      {_, _, _} ->
        c
    end
  end

  @type cmd ::
          {:try, binary}
          | :try_cancel
          | {:activate_by, binary}
          | {:set_is_single, integer()}
          | {:set_priority, integer()}
          | :activate
          | :deactivate
          | :delegate
          | {:delegate, pos_integer()}
          | {:delegate_to, binary}
          | {:delegate_to, binary, pos_integer()}
          | {:autocorrect, binary}
          | :ping
          | :retry

  @delegation_max_duration_sec 90 * 24 * 60 * 60
  def delegation_max_duration_sec, do: @delegation_max_duration_sec

  @doc """
  Parse a comment for bors commands.
  """
  @spec parse(nil) :: []
  def parse(nil) do
    []
  end

  @spec parse(binary) :: [cmd]
  def parse(comment) do
    comment
    |> String.splitter("\n")
    |> Enum.flat_map(fn string ->
      trim_and_parse_cmd(Regex.named_captures(regex(), string))
    end)
  end

  def regex, do: ~r/^(?<command_trigger>#{command_trigger()}|bros):?\s(?<command>.+)/i

  def trim_and_parse_cmd(%{"command_trigger" => "bros", "command" => cmd}) do
    with [_] <- parse_cmd(cmd), do: [:bros]
  end

  def trim_and_parse_cmd(%{"command" => cmd}) do
    cmd
    |> String.trim()
    |> parse_cmd()
  end

  def trim_and_parse_cmd(_), do: []

  def parse_cmd("try-"), do: [:try_cancel]
  def parse_cmd("try" <> arguments), do: [{:try, arguments}]
  def parse_cmd("single" <> rest), do: parse_single_patch(rest)
  def parse_cmd("r+ single" <> rest), do: parse_single_patch(rest) ++ [:activate]
  def parse_cmd("r+ p=" <> rest), do: parse_priority(rest) ++ [:activate]
  def parse_cmd("r+" <> _), do: [:activate]
  def parse_cmd("r-" <> _), do: [:deactivate]
  def parse_cmd("r=" <> arguments), do: parse_activation_args(arguments)
  def parse_cmd("merge-" <> _), do: [:deactivate]
  def parse_cmd("merge p=" <> rest), do: parse_priority(rest) ++ [:activate]
  def parse_cmd("merge=" <> arguments), do: parse_activation_args(arguments)
  def parse_cmd("merge" <> _), do: [:activate]
  def parse_cmd("delegate=" <> arguments), do: parse_delegate_with(arguments, :delegate_to)
  def parse_cmd("delegate+=" <> arguments), do: parse_delegate_with(arguments, :delegate_to)
  def parse_cmd("delegate+" <> rest), do: parse_delegate_self(rest)
  def parse_cmd("delegate-=" <> arguments), do: parse_delegation_args(arguments, :undelegate_to)
  def parse_cmd("delegate-" <> _), do: [:undelegate]
  def parse_cmd("d=" <> arguments), do: parse_delegate_with(arguments, :delegate_to)
  def parse_cmd("d+=" <> arguments), do: parse_delegate_with(arguments, :delegate_to)
  def parse_cmd("d+" <> rest), do: parse_delegate_self(rest)
  def parse_cmd("d-=" <> arguments), do: parse_delegation_args(arguments, :undelegate_to)
  def parse_cmd("d-" <> _), do: [:undelegate]
  def parse_cmd("+r" <> _), do: [{:autocorrect, "r+"}]
  def parse_cmd("-r" <> _), do: [{:autocorrect, "r-"}]
  def parse_cmd("+"), do: [{:autocorrect, "r+"}]
  def parse_cmd("-"), do: [{:autocorrect, "r-"}]
  def parse_cmd("ping" <> _), do: [:ping]
  def parse_cmd("p=" <> rest), do: parse_priority(rest)
  def parse_cmd("retry" <> _), do: [:retry]
  def parse_cmd("cancel" <> _), do: [:deactivate]
  def parse_cmd(_), do: []

  @doc ~S"""
  The username part of an activation-by command is defined like this:

    * It may start with whitespace
    * @-signs are stripped
    * ", " is converted to ","
    * Otherwise, whitespace ends it.

      iex> alias BorsNG.Command
      iex> Command.parse_activation_args("", " this, is, whitespace heavy")
      "this,is,whitespace"
      iex> Command.parse_activation_args("", " @this, @has, @ats")
      "this,has,ats"
      iex> Command.parse_activation_args("", " trimmed ")
      "trimmed"
      iex> Command.parse_activation_args("", "what\never")
      "what"
      iex> Command.parse_activation_args("", "")
      ""
      iex> Command.parse_activation_args("somebody")
      [{:activate_by, "somebody"}]
      iex> Command.parse_activation_args("")
      []
      iex> Command.parse_activation_args("  ")
      []
      iex> Command.parse_activation_args("somebody p=10")
      [{:set_priority, 10}, {:activate_by, "somebody"}]
  """
  def parse_activation_args("", string) do
    {rest, mentions} =
      string
      |> String.trim()
      |> String.replace(~r/, */, ",")
      |> String.split("\n", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.split(~r/, */)
      |> Enum.map(fn s -> String.replace(s, "@", "") end)
      |> List.pop_at(-1)

    [last_mention | rest_list] =
      rest
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)

    mentions = mentions ++ [last_mention]
    mentions = Enum.join(mentions, ",")

    params =
      case rest_list do
        [] ->
          nil

        [rest] ->
          rest
          |> String.trim()
          |> String.split("=", parts: 2)
          |> Enum.map(&String.trim(&1))
      end

    case params do
      ["p", priority_s] ->
        {priority_i, _} = Integer.parse(priority_s)
        {mentions, %{p: priority_i}}

      _ ->
        mentions
    end
  end

  def parse_activation_args(arguments) do
    arguments = parse_activation_args("", arguments)

    case arguments do
      "" -> []
      {mentions, %{p: p}} -> [{:set_priority, p}, {:activate_by, mentions}]
      arguments -> [{:activate_by, arguments}]
    end
  end

  @doc ~S"""
  The username part of a delegate-to command is defined like this:

    * It may start with whitespace
    * @-signs are stripped
    * ", " is converted to ","
    * Otherwise, whitespace ends it.
    * It's split on comma.

      iex> alias BorsNG.Command
      iex> Command.parse_delegation_args(" this, is, whitespace heavy", :delegate_to)
      [
        {:delegate_to, "this"},
        {:delegate_to, "is"},
        {:delegate_to, "whitespace"}]
      iex> Command.parse_delegation_args(" @this, @has, @ats", :undelegate_to)
      [{:undelegate_to, "this"}, {:undelegate_to, "has"}, {:undelegate_to, "ats"}]
      iex> Command.parse_delegation_args(" trimmed ", :delegate_to)
      [{:delegate_to, "trimmed"}]
      iex> Command.parse_delegation_args("what\never", :undelegate_to)
      [{:undelegate_to, "what"}]
      iex> Command.parse_delegation_args("somebody", :delegate_to)
      [{:delegate_to, "somebody"}]
      iex> Command.parse_delegation_args("", :undelegate_to)
      []
      iex> Command.parse_delegation_args("  ", :delegate_to)
      []
  """
  def parse_delegation_args([], "", " " <> rest) do
    parse_delegation_args([], "", rest)
  end

  def parse_delegation_args(l, nick, "@" <> rest) do
    parse_delegation_args(l, nick, rest)
  end

  def parse_delegation_args(l, nick, ", " <> rest) do
    parse_delegation_args([nick | l], "", rest)
  end

  def parse_delegation_args(l, nick, "," <> rest) do
    parse_delegation_args([nick | l], "", rest)
  end

  def parse_delegation_args(l, nick, "\n" <> _) do
    [nick | l]
  end

  def parse_delegation_args(l, nick, "") do
    [nick | l]
  end

  def parse_delegation_args(l, nick, " " <> _) do
    [nick | l]
  end

  def parse_delegation_args(l, nick, <<c::8, rest::binary>>) do
    parse_delegation_args(l, <<nick::binary, c::8>>, rest)
  end

  def parse_delegation_args(arguments, action) do
    []
    |> parse_delegation_args("", arguments)
    |> :lists.reverse()
    |> Enum.flat_map(fn
      "" -> []
      nick -> [{action, nick}]
    end)
  end

  @doc ~S"""
  Parse a `for=` duration argument like `24h`, `7d`, or `2w`.
  Returns `{:ok, seconds}` or `:error`. Capped at 90 days.

      iex> alias BorsNG.Command
      iex> Command.parse_duration("24h")
      {:ok, 86400}
      iex> Command.parse_duration("7d")
      {:ok, 604800}
      iex> Command.parse_duration("2w")
      {:ok, 1209600}
      iex> Command.parse_duration("0h")
      :error
      iex> Command.parse_duration("100d")
      :error
      iex> Command.parse_duration("abc")
      :error
      iex> Command.parse_duration("")
      :error
  """
  @spec parse_duration(binary) :: {:ok, pos_integer()} | :error
  def parse_duration(str) when is_binary(str) do
    case Regex.run(~r/^(\d+)(h|d|w)$/, str, capture: :all_but_first) do
      [n_str, unit] ->
        n = String.to_integer(n_str)

        secs =
          case unit do
            "h" -> n * 60 * 60
            "d" -> n * 24 * 60 * 60
            "w" -> n * 7 * 24 * 60 * 60
          end

        if secs > 0 and secs <= @delegation_max_duration_sec do
          {:ok, secs}
        else
          :error
        end

      nil ->
        :error
    end
  end

  # Splits a delegate argument list into {names_part, duration_seconds_or_nil}.
  # A `for=<duration>` token may appear anywhere among the comma/space-separated
  # tokens; if multiple appear, the last valid one wins. The remaining tokens
  # are rejoined with ", " for parse_delegation_args/2, which expects comma
  # separation (a literal space terminates a name).
  defp extract_delegate_extras(s) do
    {for_tokens, name_tokens} =
      s
      |> String.split(~r/[\s,]+/, trim: true)
      |> Enum.split_with(&String.starts_with?(&1, "for="))

    duration =
      for_tokens
      |> Enum.reverse()
      |> Enum.find_value(fn token ->
        case parse_duration(String.replace_prefix(token, "for=", "")) do
          {:ok, secs} -> secs
          :error -> nil
        end
      end)

    {Enum.join(name_tokens, ", "), duration}
  end

  defp parse_delegate_with(arguments, action) do
    {names, duration} = extract_delegate_extras(arguments)

    names
    |> parse_delegation_args(action)
    |> Enum.map(fn
      {^action, login} when not is_nil(duration) -> {action, login, duration}
      cmd -> cmd
    end)
  end

  defp parse_delegate_self(rest) do
    case extract_delegate_extras(rest) do
      {_, nil} -> [:delegate]
      {_, duration} -> [{:delegate, duration}]
    end
  end

  def parse_priority(binary) do
    {p, _} = Integer.parse(binary)

    [{:set_priority, p}]
  end

  def parse_single_patch(binary) do
    case String.trim(binary) do
      "on" <> _ ->
        [{:set_is_single, true}]

      "off" <> _ ->
        [{:set_is_single, false}]
    end
  end

  @doc """
  Given a populated struct, run everything.
  """
  @spec run(t) :: :ok
  def run(c) do
    cmd_list = parse(c.comment)

    if cmd_list == [] do
      :ok
    else
      required_permission = required_permission_level(cmd_list)

      if required_permission == :none do
        c = fetch_patch_local(c)
        Enum.each(cmd_list, &run(c, &1))
        maybe_log_commands(c, cmd_list)
      else
        c = fetch_patch(c)

        if is_nil(c.patch) do
          Logger.warning(
            "Command.run: patch lookup failed for project=#{c.project.id} pr=#{c.pr_xref}"
          )

          :ok
        else
          cond do
            # Merge-time gate: a reviewer-level command relying on a delegation
            # is re-checked against the current head and fails closed. If the
            # gate denies, it has already revoked + commented (or explained an
            # unverifiable check), so don't also post the generic denial.
            required_permission == :reviewer and
                DelegationInvalidator.verify_for_merge(c.patch, c.commenter) == :deny ->
              :ok

            Permission.permission?(required_permission, c.commenter, c.patch) ->
              Enum.each(cmd_list, &run(c, &1))
              Enum.each(cmd_list, &log(c, &1))

            true ->
              permission_denied(c)
          end
        end
      end
    end
  end

  def required_permission_level_cmd(:ping) do
    :none
  end

  def required_permission_level_cmd({:autocorrect, _}) do
    :none
  end

  def required_permission_level_cmd({:try, _}) do
    :member
  end

  def required_permission_level_cmd(:try_cancel) do
    :member
  end

  def required_permission_level_cmd(:deactivate) do
    :member
  end

  def required_permission_level_cmd(:retry) do
    :member
  end

  def required_permission_level_cmd(_) do
    :reviewer
  end

  def required_permission_level(cmd_list) do
    cmd_list
    |> Enum.reduce(:none, fn cmd, perm ->
      new_perm = cmd |> required_permission_level_cmd()

      case {perm, new_perm} do
        {:none, new_perm} -> new_perm
        {perm, :none} -> perm
        {_, :reviewer} -> :reviewer
        {:reviewer, _} -> :reviewer
        {p, p} -> p
      end
    end)
  end

  def permission_denied(c) do
    login = c.commenter.login

    url =
      project_url(
        BorsNG.Endpoint,
        :confirm_add_reviewer,
        c.project,
        login
      )

    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      """
      :lock: Permission denied

      An existing reviewer can [click here to make #{login} a reviewer](#{url}).
      """
    )
  end

  @spec log(t, cmd) :: :ok
  def log(c, cmd) do
    Logging.log_cmd(c.patch, c.commenter, cmd)
  end

  defp fetch_patch_local(c) do
    case c.patch do
      nil ->
        case Repo.get_by(Patch, project_id: c.project.id, pr_xref: c.pr_xref) do
          nil -> c
          patch -> %Command{c | patch: patch}
        end

      _ ->
        c
    end
  end

  defp maybe_log_commands(%Command{patch: nil}, _cmd_list), do: :ok
  defp maybe_log_commands(%Command{commenter: nil}, _cmd_list), do: :ok

  defp maybe_log_commands(c, cmd_list) do
    Enum.each(cmd_list, &log(c, &1))
  end

  @spec run(t, cmd) :: :ok
  def run(c, :activate) do
    run(c, {:activate_by, c.commenter.login})
  end

  def run(c, {:activate_by, username}) do
    batcher = Batcher.Registry.get(c.project.id)
    Batcher.reviewed(batcher, c.patch.id, username)
  end

  def run(c, {:set_is_single, is_single}) do
    batcher = Batcher.Registry.get(c.project.id)
    Batcher.set_is_single(batcher, c.patch.id, is_single)
  end

  def run(c, {:set_priority, priority}) do
    batcher = Batcher.Registry.get(c.project.id)
    Batcher.set_priority(batcher, c.patch.id, priority)
  end

  def run(c, :deactivate) do
    c = fetch_patch(c)
    batcher = Batcher.Registry.get(c.project.id)
    Batcher.cancel(batcher, c.patch.id)
  end

  def run(c, {:try, arguments}) do
    c = fetch_patch(c)

    Task.Supervisor.start_child(BorsNG.Worker.Syncer.Supervisor, fn ->
      DelegationInvalidator.lint_for_patch(c.patch.id)
    end)

    attemptor = Attemptor.Registry.get(c.project.id)
    Attemptor.tried(attemptor, c.patch.id, arguments)
  end

  def run(c, :try_cancel) do
    c = fetch_patch(c)
    attemptor = Attemptor.Registry.get(c.project.id)
    Attemptor.cancel(attemptor, c.patch.id)
  end

  def run(c, {:autocorrect, command}) do
    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      ~s/Did you mean "#{command}"?/
    )
  end

  def run(c, :ping) do
    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      "pong"
    )
  end

  def run(c, :delegate) do
    patch = Repo.preload(c.patch, :author)
    delegate_to(c, patch.author, nil)
  end

  def run(c, {:delegate, duration}) when is_integer(duration) do
    patch = Repo.preload(c.patch, :author)
    delegate_to(c, patch.author, duration)
  end

  def run(c, {:delegate_to, login}) do
    delegatee = get_or_insert_user_by_login(c, login)
    delegate_to(c, delegatee, nil)
  end

  def run(c, {:delegate_to, login, duration}) when is_integer(duration) do
    delegatee = get_or_insert_user_by_login(c, login)
    delegate_to(c, delegatee, duration)
  end

  def run(c, :undelegate) do
    Permission.undelegate_patch(c.patch.id)

    Project.ping!(c.project.id)

    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      ~s{:no_entry_sign: All delegations have been removed from this PR. To re-add a delegation, reply with `bors d+` (to delegate the PR author) or `bors d=list,of,github,usernames` to delegate multiple users.}
    )
  end

  def run(c, {:undelegate_to, login}) do
    undelegatee = get_or_insert_user_by_login(c, login)

    Permission.undelegate(undelegatee.id, c.patch.id)

    Project.ping!(c.project.id)

    readd_command =
      case c.patch.author do
        ^undelegatee -> "bors d+"
        _ -> "bors d=#{undelegatee.login}"
      end

    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      ~s{:no_entry_sign: This PR is no longer delegated to #{undelegatee.login}. To re-add their delegation, reply with `#{readd_command}`.}
    )
  end

  def run(c, :retry) do
    case Logging.most_recent_cmd(c.patch) do
      {commenter, cmd} ->
        run(%{c | commenter: commenter}, cmd)

      nil ->
        c.project.repo_xref
        |> Project.installation_connection(Repo)
        |> GitHub.post_comment!(c.pr_xref, "Nothing to retry.")
    end
  end

  def run(c, :bros) do
    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      ~s/👊/
    )
  end

  defp get_or_insert_user_by_login(c, login) do
    case Repo.get_by(User, login: login) do
      nil ->
        installation = Repo.get!(Installation, c.project.installation_id)

        gh_user =
          GitHub.get_user_by_login!(
            {:installation, installation.installation_xref},
            login
          )

        Repo.insert!(%User{
          login: gh_user.login,
          user_xref: gh_user.id
        })

      user ->
        user
    end
  end

  def delegate_to(c, delegatee, explicit_duration) do
    conn = Project.installation_connection(c.project.repo_xref, Repo)
    toml = fetch_bors_toml(conn, c)
    duration = explicit_duration || toml_default_expiry(toml)

    Delegation.reconcile_default_expiry(c.patch, toml_default_expiry(toml))

    if is_integer(duration) and duration > 0 do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      expires_at = NaiveDateTime.add(now, duration, :second)

      Permission.delegate(delegatee, c.patch,
        expires_at: expires_at,
        delegated_at_commit: c.patch.commit
      )

      Project.ping!(c.project.id)

      msg =
        ~s{:v: #{delegatee.login} can now approve this pull request until #{format_expires_at(expires_at)} (in #{format_duration(duration)}). To approve and merge, reply with `bors r+`. More detailed instructions are available [here](https://bors.tech/documentation/getting-started/#reviewing-pull-requests).} <>
          delegation_paths_note(toml)

      GitHub.post_comment!(conn, c.pr_xref, msg)
    else
      GitHub.post_comment!(
        conn,
        c.pr_xref,
        ~s{:lock: Delegation requires an explicit expiration. Pass `for=24h`, `for=7d`, or `for=2w`, or have a reviewer set `default_expiry_sec` under `[delegation]` in `bors.toml`.}
      )
    end
  end

  defp fetch_bors_toml(conn, c) do
    case Batcher.GetBorsToml.get(conn, c.patch.into_branch) do
      {:ok, toml} -> toml
      {:error, _} -> nil
    end
  end

  @minute 60
  @hour 60 * @minute
  @day 24 * @hour
  @week 7 * @day

  defp toml_default_expiry(nil), do: nil
  defp toml_default_expiry(toml), do: toml.delegation_default_expiry_sec

  # Standing note appended to the delegate-success comment, describing what
  # will revoke the delegation. See DELEGATION_INVALIDATION.md, "User-facing
  # messages".
  defp delegation_paths_note(nil), do: ""

  defp delegation_paths_note(toml) do
    sentences =
      []
      |> add_paths_sentence(toml.delegation_restrict_to_paths, fn rendered ->
        "This delegation only covers changes within #{rendered}; an author commit " <>
          "touching anything else will revoke it."
      end)
      |> add_paths_sentence(toml.delegation_invalidate_on_paths, fn rendered ->
        "A new author commit touching any of these paths will revoke this delegation: " <>
          rendered <> "."
      end)

    case sentences do
      [] ->
        ""

      _ ->
        caveat =
          "Bors also revokes it if a later push changes too many files for it to check " <>
            "the full list — even if it stays within scope."

        "\n\n:warning: " <> Enum.join(sentences ++ [caveat], " ")
    end
  end

  defp add_paths_sentence(acc, [], _fun), do: acc

  defp add_paths_sentence(acc, paths, fun) do
    rendered = paths |> Enum.map(&"`#{&1}`") |> Enum.join(", ")
    acc ++ [fun.(rendered)]
  end

  @doc """
  Render a delegation expiry timestamp for a comment, e.g.
  `"2026-06-07 12:34 UTC"`. Delegations are always stored in UTC, so the
  zone is spelled out rather than abbreviated to `Z`. Seconds are dropped:
  they're noise for an expiry deadline.

  ## Examples

      iex> Command.format_expires_at(~N[2026-06-07 12:34:56])
      "2026-06-07 12:34 UTC"
  """
  def format_expires_at(naive_dt) do
    Calendar.strftime(naive_dt, "%Y-%m-%d %H:%M UTC")
  end

  @doc """
  Render `seconds` as a human-friendly duration using up to the two most
  significant non-zero units, e.g. `"1 week, 5 days"` or `"2 days, 3 hours"`.

  Always **rounds down** (truncates). This is shown as the time left before a
  delegation expires, so overstating it would be worse than ugly: a user told
  they have "1 week" when only 6d 23h 59m remains could find they can no
  longer merge. Rounding down means the displayed figure is a floor — there is
  always at least this much time left. The cost is the occasional unlovely
  value like `"6 days, 23 hours"`, which is the right trade here.

  ## Examples

      iex> Command.format_duration(12 * 24 * 60 * 60)
      "1 week, 5 days"
      iex> Command.format_duration(51 * 60 * 60)
      "2 days, 3 hours"
      iex> Command.format_duration(7 * 24 * 60 * 60)
      "1 week"
      iex> Command.format_duration(6 * 86400 + 23 * 3600 + 59 * 60 + 57)
      "6 days, 23 hours"
      iex> Command.format_duration(45)
      "less than a minute"
  """
  def format_duration(seconds) when is_integer(seconds) do
    parts =
      [{@week, "week"}, {@day, "day"}, {@hour, "hour"}, {@minute, "minute"}]
      |> Enum.map_reduce(max(seconds, 0), fn {size, label}, remaining ->
        {{div(remaining, size), label}, rem(remaining, size)}
      end)
      |> elem(0)
      |> Enum.filter(fn {n, _label} -> n > 0 end)
      |> Enum.take(2)

    case parts do
      [] -> "less than a minute"
      parts -> Enum.map_join(parts, ", ", fn {n, label} -> pluralize(n, label) end)
    end
  end

  defp pluralize(1, label), do: "1 #{label}"
  defp pluralize(n, label), do: "#{n} #{label}s"
end
