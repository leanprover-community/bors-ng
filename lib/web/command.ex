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

  # link

  `bors link #456`, commented on a pull request, links it with #456 into a
  bundle that merges atomically. Each member still needs its own `bors r+`. Once
  every member is approved, they all enter the same batch and land together or
  not at all. Listing several numbers bundles more than two pull requests at once.
  The PR the comment is on is always included (listing its own number is harmless).
  `bors unlink` (or `bors link-`) dissolves the bundle.

  `bors stack #123`, commented on another PR, additionally records an order.
  This PR joins #123's bundle with #123's changes applied first (a separate
  commit directly after it under squash merges). Use it when changes must land
  together and in a fixed order.

  Bare `bors stack` infers the parent from the base-branch chain. It works when
  a stacked PR's base branch is its parent's head branch. These bases are
  retargeted onto the final branch automatically when the bundle is queued.
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
  alias BorsNG.Worker.Labeler
  alias BorsNG.Worker.Syncer

  import BorsNG.Router.Helpers
  require Logger

  defstruct(
    project: nil,
    commenter: nil,
    pr: nil,
    pr_xref: nil,
    patch: nil,
    comment: "",
    is_draft: nil
  )

  @type t :: %BorsNG.Command{
          project: Project.t(),
          commenter: User.t(),
          pr: map | nil,
          pr_xref: integer,
          patch: Patch.t() | nil,
          comment: binary,
          is_draft: boolean | nil
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

          # Catch-all, not `{:error, reason}`: `GitHub.get_pr/2` reports
          # failures as 2-, 3- and 4-element tuples (see `draft_at_merge?/2`
          # in the batcher), and only `ServerMock` uses the 2-tuple. A narrow
          # clause raises `CaseClauseError` here on any real GitHub error,
          # which fails the webhook rather than the one command.
          error ->
            Logger.warning("fetch_pr: failed for PR #{pr_xref}: #{inspect(error)}")
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
          | {:link, [pos_integer()]}
          | {:stack, [pos_integer()]}
          | {:link_malformed, :link | :stack, [binary]}
          | {:malformed_args,
             :priority
             | :priority_range
             | :single
             | {:delegate, binary, [binary], [binary]}
             | {:undelegate, binary, [binary]}}
          | :unlink
          | :unlink_with_args

  @delegation_max_duration_sec 90 * 24 * 60 * 60
  def delegation_max_duration_sec, do: @delegation_max_duration_sec

  # `Patch.pr_xref` is a 32-bit database column. A larger number cannot be a
  # real pull request, and passing one to a lookup crashes the query.
  @max_pr_xref 2_147_483_647

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
  def parse_cmd("r+ single" <> rest), do: with_activation(parse_single_patch(rest))
  def parse_cmd("r+ p=" <> rest), do: with_activation(parse_priority(rest))
  def parse_cmd("r+" <> _), do: [:activate]
  def parse_cmd("r-" <> _), do: [:deactivate]
  def parse_cmd("r=" <> arguments), do: parse_activation_args(arguments)
  def parse_cmd("merge-" <> _), do: [:deactivate]
  def parse_cmd("merge p=" <> rest), do: with_activation(parse_priority(rest))
  def parse_cmd("merge=" <> arguments), do: parse_activation_args(arguments)
  def parse_cmd("merge" <> _), do: [:activate]
  def parse_cmd("delegate=" <> arguments), do: parse_delegate_with(arguments, :delegate_to)
  def parse_cmd("delegate+=" <> arguments), do: parse_delegate_with(arguments, :delegate_to)
  def parse_cmd("delegate+" <> rest), do: parse_delegate_self("delegate+", rest)
  def parse_cmd("delegate-=" <> arguments), do: parse_delegation_args(arguments, :undelegate_to)
  def parse_cmd("delegate-" <> rest), do: parse_undelegate_all("delegate-", rest)
  def parse_cmd("d=" <> arguments), do: parse_delegate_with(arguments, :delegate_to)
  def parse_cmd("d+=" <> arguments), do: parse_delegate_with(arguments, :delegate_to)
  def parse_cmd("d+" <> rest), do: parse_delegate_self("d+", rest)
  def parse_cmd("d-=" <> arguments), do: parse_delegation_args(arguments, :undelegate_to)
  def parse_cmd("d-" <> rest), do: parse_undelegate_all("d-", rest)
  def parse_cmd("+r" <> _), do: [{:autocorrect, "r+"}]
  def parse_cmd("-r" <> _), do: [{:autocorrect, "r-"}]
  def parse_cmd("+"), do: [{:autocorrect, "r+"}]
  def parse_cmd("-"), do: [{:autocorrect, "r-"}]
  def parse_cmd("ping" <> _), do: [:ping]
  def parse_cmd("p=" <> rest), do: parse_priority(rest)
  def parse_cmd("retry" <> _), do: [:retry]
  def parse_cmd("cancel" <> _), do: [:deactivate]
  def parse_cmd("unlink" <> arguments), do: parse_unlink(arguments)
  def parse_cmd("link-" <> arguments), do: parse_unlink(arguments)
  def parse_cmd("link" <> arguments), do: parse_bundle_refs(:link, arguments)
  def parse_cmd("stack" <> arguments), do: parse_bundle_refs(:stack, arguments)
  def parse_cmd(_), do: []

  # `unlink` dissolves the whole bundle. Naming pull requests suggests the
  # user expects to remove just those, so refuse rather than surprise them.
  defp parse_unlink(arguments) do
    case parse_pr_refs(arguments) ++ malformed_pr_refs(arguments) do
      [] -> [:unlink]
      _ -> [:unlink_with_args]
    end
  end

  # A silent mistype would link the wrong pull requests. Refuse if any
  # argument was plausibly meant as a reference or another bors command.
  defp parse_bundle_refs(cmd, arguments) do
    case malformed_pr_refs(arguments) do
      [] -> [{cmd, parse_pr_refs(arguments)}]
      bad -> [{:link_malformed, cmd, bad}]
    end
  end

  @doc ~S"""
  Parse the arguments of a link or stack command. Arguments are pull request
  numbers separated by whitespace or commas, each with an optional leading `#`.

      iex> alias BorsNG.Command
      iex> Command.parse_pr_refs(" #1 #2")
      [1, 2]
      iex> Command.parse_pr_refs("= 1, 2, 3")
      [1, 2, 3]
      iex> Command.parse_pr_refs("")
      []
      iex> Command.parse_pr_refs(" nonsense")
      []
      iex> Command.parse_pr_refs(" #99999999999")
      []
  """
  def parse_pr_refs(arguments) do
    arguments
    |> ref_tokens()
    |> Enum.filter(&pr_ref?/1)
    |> Enum.map(&(&1 |> String.replace_prefix("#", "") |> String.to_integer()))
  end

  # A well-formed reference: an optional `#`, then a number small enough to
  # be a real pull request.
  defp pr_ref?(token) do
    String.match?(token, ~r/^#?\d+$/) and
      token |> String.replace_prefix("#", "") |> String.to_integer() <= @max_pr_xref
  end

  @doc ~S"""
  Tokens that were plausibly meant as a pull request reference or another bors
  command on the same line. Reference tokens start with `#` or a digit but do
  not parse as a number. Connective words are tolerated.

      iex> alias BorsNG.Command
      iex> Command.malformed_pr_refs(" #12abc #13")
      ["#12abc"]
      iex> Command.malformed_pr_refs(" on #13")
      []
      iex> Command.malformed_pr_refs(" #13 r+")
      ["r+"]
      iex> Command.malformed_pr_refs(" #13 p=5")
      ["p=5"]
      iex> Command.malformed_pr_refs(" #13 d=alice")
      ["d=alice"]
      iex> Command.malformed_pr_refs(" #99999999999")
      ["#99999999999"]
  """
  def malformed_pr_refs(arguments) do
    arguments
    |> ref_tokens()
    |> Enum.filter(fn token ->
      ref_like = String.match?(token, ~r/^[#\d]/) and not pr_ref?(token)
      ref_like or other_command?(token)
    end)
  end

  # Tokens that read as another bors command or its argument on the same
  # line. Refuse rather than guess which pull requests were meant. Asking
  # the real parser keeps this list from drifting as commands are added.
  # The two extra checks catch tokens the parser alone would not: key=value
  # fragments whose argument is empty or unreadable (`r=`, `d=`, `for=2w`),
  # and a bare `delegate`.
  defp other_command?(token) do
    parse_cmd(token) != [] or
      String.contains?(token, "=") or
      String.starts_with?(token, "delegate")
  end

  defp ref_tokens(arguments) do
    arguments
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim_leading()
    # `=` is optional `link=` or `stack=` sugar. Strip one leading `=` and
    # split on whitespace and commas so `p=5` stays a single token.
    |> String.replace_prefix("=", "")
    |> String.split(~r/[\s,]+/, trim: true)
  end

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
        case read_priority(priority_s) do
          {:ok, priority_i} -> {mentions, %{p: priority_i}}
          {:error, kind} -> {:malformed_priority, kind}
        end

      _ ->
        mentions
    end
  end

  def parse_activation_args(arguments) do
    arguments = parse_activation_args("", arguments)

    case arguments do
      "" -> []
      {:malformed_priority, kind} -> [{:malformed_args, kind}]
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
    {for_tokens, name_tokens} = split_for_tokens(s)

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

  defp split_for_tokens(s) do
    s
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.split_with(&String.starts_with?(&1, "for="))
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

  # `d+` delegates the PR author. Names after it most likely mean `d=`, so
  # refuse rather than delegate someone else. The refusal keeps what was
  # typed, and its suggestion keeps any `for=`.
  defp parse_delegate_self(typed, rest) do
    case split_for_tokens(rest) do
      {_, []} ->
        case extract_delegate_extras(rest) do
          {_, nil} -> [:delegate]
          {_, duration} -> [{:delegate, duration}]
        end

      {for_tokens, name_tokens} ->
        [{:malformed_args, {:delegate, typed <> rest, suggested_logins(name_tokens), for_tokens}}]
    end
  end

  # `d-` removes every delegation. Anything after it most likely names the
  # users meant to lose theirs, which is `d-=`, so refuse rather than remove
  # them all. The refusal keeps what was typed.
  defp parse_undelegate_all(_typed, ""), do: [:undelegate]

  defp parse_undelegate_all(typed, rest) do
    tokens = String.split(rest, ~r/[\s,]+/, trim: true)
    [{:malformed_args, {:undelegate, typed <> rest, suggested_logins(tokens)}}]
  end

  # The names a refusal can suggest: all of the tokens, or none when any of
  # them could not be a GitHub login.
  defp suggested_logins(tokens) do
    logins = Enum.map(tokens, &String.trim_leading(&1, "@"))
    if Enum.all?(logins, &login_shaped?/1), do: logins, else: []
  end

  # Loose on purpose: this only decides whether the suggestion repeats the
  # names. GitHub logins are letters, digits and hyphens; Enterprise managed
  # users add `_shortcode`, and app accounts a `[bot]` suffix.
  defp login_shaped?(token) do
    String.match?(token, ~r/^[A-Za-z0-9][A-Za-z0-9_-]*(\[bot\])?$/)
  end

  def parse_priority(binary) do
    case read_priority(binary) do
      {:ok, p} -> [{:set_priority, p}]
      {:error, kind} -> [{:malformed_args, kind}]
    end
  end

  # `Patch.priority` and `Batch.priority` are 32-bit columns. A value outside
  # that range crashes the batcher's write instead of reaching the queue.
  @min_priority -2_147_483_648
  @max_priority 2_147_483_647

  def priority_range, do: {@min_priority, @max_priority}

  # The number must end at whitespace or the end of the text, so `p=5abc` is
  # refused rather than read as 5.
  defp read_priority(binary) do
    case Integer.parse(binary) do
      {p, rest} ->
        cond do
          not String.match?(rest, ~r/^(\s|$)/) -> {:error, :priority}
          p < @min_priority or p > @max_priority -> {:error, :priority_range}
          true -> {:ok, p}
        end

      :error ->
        {:error, :priority}
    end
  end

  def parse_single_patch(binary) do
    case String.trim(binary) do
      "on" <> _ ->
        [{:set_is_single, true}]

      "off" <> _ ->
        [{:set_is_single, false}]

      _ ->
        [{:malformed_args, :single}]
    end
  end

  # A modifier that cannot be read swallows its activation: activating
  # anyway, with the modifier silently dropped, is the surprise being refused.
  defp with_activation([{:malformed_args, _}] = malformed), do: malformed
  defp with_activation(cmds), do: cmds ++ [:activate]

  @doc """
  Given a populated struct, run everything.
  """
  @spec run(t) :: :ok
  def run(c) do
    cmd_list = parse(c.comment)

    cond do
      cmd_list == [] ->
        :ok

      # Ahead of the permission block: a refused command must not reach
      # `verify_for_merge/2`, which revokes and comments as a side effect.
      # The list check comes first because `draft?/1` may hit the database.
      Enum.any?(cmd_list, &draft_blocked?/1) and draft?(c) ->
        draft_refused(c, cmd_list)

      true ->
        run_permitted(c, cmd_list)
    end
  end

  defp run_permitted(c, cmd_list) do
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
          #
          # For a bundled patch this is the only delegation check the
          # approval ever gets: "merge time" is hold time. The r+ this gate
          # blesses may be held on the patch (`Bundles.hold_approval/2`)
          # until the rest of the bundle is approved, and is not re-checked
          # when the bundle later queues. See DELEGATION_INVALIDATION.md,
          # "standing approvals".
          required_permission == :reviewer and
              DelegationInvalidator.verify_for_merge(c.patch, c.commenter) == :deny ->
            :ok

          Permission.permission?(required_permission, c.commenter, c.patch) ->
            cmd_list = resolve_delegation_logins(c, cmd_list)
            Enum.each(cmd_list, &run(c, &1))
            Enum.each(cmd_list, &log(c, &1))

          true ->
            permission_denied(c)
        end
      end
    end
  end

  # Looks up every login the delegation commands name before any of them
  # runs. One that GitHub does not know, or cannot look up, refuses every
  # delegation command in the comment: half-applying `d=alice,alcie`, or
  # applying `d-` without the `d=` meant to follow it, is the surprise being
  # refused. The other commands still run. The lookup settles each login's
  # spelling as GitHub has it, so `d=Alice` finds the stored `alice`.
  defp resolve_delegation_logins(c, cmd_list) do
    lookups =
      cmd_list
      |> Enum.flat_map(&delegation_login/1)
      |> Enum.uniq()
      |> Enum.map(&{&1, lookup_user(c, &1)})

    unknown = for {login, :not_found} <- lookups, do: login
    failed = for {login, :error} <- lookups, do: login

    refusal =
      cond do
        unknown != [] -> {:delegation_refused, :unknown_users, unknown}
        failed != [] -> {:delegation_refused, :lookup_failed, failed}
        true -> nil
      end

    if refusal do
      c.project.repo_xref
      |> Project.installation_connection(Repo)
      |> GitHub.post_comment!(c.pr_xref, Batcher.Message.generate_message(refusal))

      Enum.reject(cmd_list, &delegation_cmd?/1)
    else
      Enum.map(cmd_list, fn cmd ->
        case delegation_login(cmd) do
          [login] ->
            {_, {:ok, user}} = List.keyfind(lookups, login, 0)
            put_elem(cmd, 1, user.login)

          [] ->
            cmd
        end
      end)
    end
  end

  defp delegation_login({:delegate_to, login}), do: [login]
  defp delegation_login({:delegate_to, login, _duration}), do: [login]
  defp delegation_login({:undelegate_to, login}), do: [login]
  defp delegation_login(_), do: []

  defp delegation_cmd?(cmd) when is_tuple(cmd), do: delegation_cmd?(elem(cmd, 0))
  defp delegation_cmd?(tag), do: tag in [:delegate, :delegate_to, :undelegate, :undelegate_to]

  # The `false` clauses are the commands that cannot lead to a merge: a trial
  # build, and taking state away.
  @spec draft_blocked?(cmd) :: boolean
  defp draft_blocked?(:ping), do: false
  defp draft_blocked?({:autocorrect, _}), do: false
  defp draft_blocked?({:try, _}), do: false
  defp draft_blocked?(:try_cancel), do: false
  defp draft_blocked?(:deactivate), do: false
  defp draft_blocked?(:unlink), do: false
  defp draft_blocked?(:unlink_with_args), do: false
  defp draft_blocked?(:undelegate), do: false
  defp draft_blocked?({:undelegate_to, _}), do: false
  defp draft_blocked?({:malformed_args, {:undelegate, _, _}}), do: false
  defp draft_blocked?(:bros), do: false
  defp draft_blocked?(_), do: true

  # `is_draft: nil` means the caller did not say, not "not a draft", so it
  # falls through to the next source. The last clause queries instead of
  # storing the row on `c`, which would rob `fetch_patch/1` of its
  # `author_id` backfill.
  @spec draft?(t) :: boolean
  defp draft?(%Command{is_draft: is_draft}) when is_boolean(is_draft), do: is_draft
  defp draft?(%Command{pr: %{draft: draft}}) when is_boolean(draft), do: draft
  defp draft?(%Command{patch: %Patch{is_draft: is_draft}}), do: is_draft

  defp draft?(%Command{patch: nil, project: project, pr_xref: pr_xref})
       when not is_nil(project) and not is_nil(pr_xref) do
    case Repo.get_by(Patch, project_id: project.id, pr_xref: pr_xref) do
      %Patch{is_draft: is_draft} -> is_draft
      nil -> false
    end
  end

  defp draft?(_), do: false

  # Not logged: `bors retry` would later replay a command that never ran.
  @spec draft_refused(t, [cmd]) :: :ok
  defp draft_refused(c, cmd_list) do
    {blocked, also_dropped} = Enum.split_with(cmd_list, &draft_blocked?/1)

    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      Batcher.Message.generate_message({:draft_refused, blocked, also_dropped})
    )
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

  # link/stack/unlink write state to pull requests other than the commented one.
  # A per-patch delegation must not satisfy them: they require project-level
  # standing.
  def required_permission_level_cmd({:link, _}) do
    :project_member
  end

  def required_permission_level_cmd({:stack, _}) do
    :project_member
  end

  def required_permission_level_cmd(:unlink) do
    :project_member
  end

  def required_permission_level_cmd({:link_malformed, _, _}) do
    :project_member
  end

  def required_permission_level_cmd(:unlink_with_args) do
    :project_member
  end

  # The hint about an unreadable argument is gated at :member — enough to
  # keep outsiders from making bors post comments — and deliberately below
  # :reviewer, so a typo never trips the delegation merge-time gate.
  def required_permission_level_cmd({:malformed_args, _}) do
    :member
  end

  def required_permission_level_cmd(_) do
    :reviewer
  end

  def required_permission_level(cmd_list) do
    cmd_list
    |> Enum.reduce(:none, fn cmd, perm ->
      combine_permission_levels(perm, required_permission_level_cmd(cmd))
    end)
  end

  # :project_member and :project_reviewer are delegation-free levels. A
  # per-patch delegate satisfies :member and :reviewer on their own pull
  # request but not these. Combining a delegation-free command with a
  # reviewer-level one keeps both requirements (:project_reviewer).
  defp combine_permission_levels(:none, new), do: new
  defp combine_permission_levels(perm, :none), do: perm
  defp combine_permission_levels(p, p), do: p
  defp combine_permission_levels(:project_reviewer, _), do: :project_reviewer
  defp combine_permission_levels(_, :project_reviewer), do: :project_reviewer
  defp combine_permission_levels(:project_member, :reviewer), do: :project_reviewer
  defp combine_permission_levels(:reviewer, :project_member), do: :project_reviewer
  defp combine_permission_levels(:project_member, :member), do: :project_member
  defp combine_permission_levels(:member, :project_member), do: :project_member
  defp combine_permission_levels(_, :reviewer), do: :reviewer
  defp combine_permission_levels(:reviewer, _), do: :reviewer

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

  def run(c, {:link, pr_numbers}) do
    batcher = Batcher.Registry.get(c.project.id)
    Batcher.link(batcher, c.patch.id, pr_numbers)
  end

  def run(c, {:stack, pr_numbers}) do
    batcher = Batcher.Registry.get(c.project.id)
    Batcher.stack(batcher, c.patch.id, pr_numbers)
  end

  def run(c, :unlink) do
    batcher = Batcher.Registry.get(c.project.id)
    Batcher.unlink(batcher, c.patch.id)
  end

  def run(c, {:link_malformed, cmd, tokens}) do
    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      Batcher.Message.generate_message({:link_error, {:malformed_refs, cmd, tokens}})
    )
  end

  def run(c, :unlink_with_args) do
    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      Batcher.Message.generate_message({:link_error, :unlink_args})
    )
  end

  def run(c, {:malformed_args, kind}) do
    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      Batcher.Message.generate_message({:malformed_args, kind})
    )
  end

  def run(c, {:try, arguments}) do
    c = fetch_patch(c)

    Task.Supervisor.start_child(BorsNG.Worker.Syncer.Supervisor, fn ->
      DelegationInvalidator.lint_for_patch(c.patch.id)
    end)

    # `try` knows nothing about bundles: it builds this patch's branch alone.
    # Say so, or a green result overstates what the batch will do.
    if c.patch.bundle_id != nil do
      body =
        Batcher.Message.generate_message(
          :try_ignores_bundle,
          bundle_url(BorsNG.Endpoint, :show, c.patch.bundle_id)
        )

      c.project.repo_xref
      |> Project.installation_connection(Repo)
      |> GitHub.post_comment!(c.pr_xref, body)
    end

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
    # Checked before the delete: it enumerates the delegations being removed.
    held_note =
      if Delegation.standing_approval_by_delegate?(c.patch.id) do
        ~s{ Note: an approval already given under a removed delegation still counts. A reviewer can retract it with `bors r-`.}
      else
        ""
      end

    Permission.undelegate_patch(c.patch.id)

    Labeler.reconcile_delegated(c.patch)

    Project.ping!(c.project.id)

    c.project.repo_xref
    |> Project.installation_connection(Repo)
    |> GitHub.post_comment!(
      c.pr_xref,
      ~s{:no_entry_sign: All delegations have been removed from this PR. To re-add a delegation, reply with `bors d+` (to delegate the PR author) or `bors d=list,of,github,usernames` to delegate multiple users.} <>
        held_note
    )
  end

  def run(c, {:undelegate_to, login}) do
    undelegatee = get_or_insert_user_by_login(c, login)

    held_note =
      if Delegation.standing_approval?(c.patch.id, undelegatee.login) do
        ~s{ Note: the approval #{undelegatee.login} already gave still counts. A reviewer can retract it with `bors r-`.}
      else
        ""
      end

    Permission.undelegate(undelegatee.id, c.patch.id)

    Labeler.reconcile_delegated(c.patch)

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
      ~s{:no_entry_sign: This PR is no longer delegated to #{undelegatee.login}. To re-add their delegation, reply with `#{readd_command}`.} <>
        held_note
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

  # `run/1` has already resolved the login, so this is a database hit.
  defp get_or_insert_user_by_login(c, login) do
    {:ok, user} = lookup_user(c, login)
    user
  end

  # Postgres compares logins case-sensitively, so `Alice` can miss a stored
  # `alice`, and a renamed user misses under the new login. `sync_user/1`
  # matches GitHub's answer by id, so neither inserts a duplicate.
  @spec lookup_user(t, binary) :: {:ok, User.t()} | :not_found | :error
  defp lookup_user(c, login) do
    case Repo.get_by(User, login: login) do
      nil ->
        installation = Repo.get!(Installation, c.project.installation_id)

        case GitHub.get_user_by_login({:installation, installation.installation_xref}, login) do
          {:ok, nil} -> :not_found
          {:ok, gh_user} -> {:ok, Syncer.sync_user(gh_user)}
          {:error, _} -> :error
        end

      user ->
        {:ok, user}
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

      Labeler.reconcile_delegated(conn, toml, c.patch)

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
