defmodule BorsNG.Worker.Batcher.BorsToml do
  @moduledoc """
  The format for `bors.toml`. It looks like this:

      status = [
        "continuous-integration/travis-ci/push",
        "continuous-integration/appveyor/branch"]

      block_labels = [ "S-do-not-merge-yet" ]

      pr_status = [ "continuous-integration/travis-ci/pull" ]
  """

  alias BorsNG.GitHub

  defstruct status: [],
            block_labels: [],
            pr_status: [],
            timeout_sec: 60 * 60,
            # prerun_timeout_sec controls how long bors will wait for all GitHub status checks to be completed before taking action.
            # If this value is set to 0, bors will not wait for status checks to be completed. Otherwise, Bors will poll status checks
            # every 5 minutes. If prerun_timeout_sec or more elapsed in the latest poll, Bors will return an error message.
            # Half an hour by default.
            prerun_timeout_sec: 30 * 60,
            use_squash_merge: false,
            required_approvals: nil,
            up_to_date_approvals: false,
            cut_body_after: nil,
            delete_merged_branches: false,
            use_codeowners: false,
            committer: nil,
            commit_title: "Merge ${PR_REFS}",
            update_base_for_deletes: false,
            max_batch_size: nil,
            delegation_default_expiry_sec: nil,
            delegation_invalidate_on_paths: [],
            delegation_restrict_to_paths: []

  @type tcommitter :: %{
          name: binary,
          email: binary
        }

  @type t :: %BorsNG.Worker.Batcher.BorsToml{
          status: [binary],
          use_squash_merge: boolean,
          block_labels: [binary],
          pr_status: [binary],
          timeout_sec: integer,
          prerun_timeout_sec: integer,
          required_approvals: integer | nil,
          up_to_date_approvals: boolean,
          cut_body_after: binary | nil,
          delete_merged_branches: boolean,
          use_codeowners: boolean,
          committer: tcommitter,
          commit_title: binary,
          update_base_for_deletes: boolean,
          max_batch_size: integer | nil,
          delegation_default_expiry_sec: pos_integer() | nil,
          delegation_invalidate_on_paths: [binary],
          delegation_restrict_to_paths: [binary]
        }

  @type err ::
          :status
          | :block_labels
          | :pr_status
          | :timeout_sec
          | :prerun_timeout_sec
          | :required_approvals
          | :cut_body_after
          | :committer_details
          | :commit_title
          | :max_batch_size
          | :delegation_default_expiry_sec
          | :delegation_invalidate_on_paths
          | :delegation_restrict_to_paths
          | :empty_config
          | :parse_failed

  defp to_map(toml) do
    toml
    |> Enum.map(fn {key, val} -> {String.replace(key, "-", "_"), val} end)
    |> Map.new()
  end

  # A delegation path entry must be a string that compiles as a glob.
  # `:glob.matches/2` raises `badarg` on an uncompilable pattern, and it runs in
  # the synchronous merge-time gate, so we reject bad patterns at config-parse
  # time (clean "Configuration problem" comment) rather than crash at match
  # time. `:glob.compile/1` returns {:ok, _} | {:error, _} without raising.
  defp valid_glob?(pattern) when is_binary(pattern) do
    match?({:ok, _}, :glob.compile(pattern))
  end

  defp valid_glob?(_pattern), do: false

  @spec new(binary) :: {:ok, t} | {:error, err}
  def new(str) when is_binary(str) do
    case Toml.decode(str) do
      {:ok, toml} ->
        toml = to_map(toml)

        delegation_table =
          case Map.get(toml, "delegation", nil) do
            nil -> %{}
            d when is_map(d) -> to_map(d)
            _ -> :invalid
          end

        {delegation_default_expiry_sec, delegation_invalidate_on_paths,
         delegation_restrict_to_paths} =
          case delegation_table do
            :invalid ->
              {:invalid, :invalid, :invalid}

            m ->
              {Map.get(m, "default_expiry_sec", nil), Map.get(m, "invalidate_on_paths", []),
               Map.get(m, "restrict_to_paths", [])}
          end

        committer = Map.get(toml, "committer", nil)

        committer =
          case committer do
            nil ->
              nil

            _ ->
              c = to_map(committer)

              %{
                name: Map.get(c, "name", nil),
                email: Map.get(c, "email", nil)
              }
          end

        toml = %BorsNG.Worker.Batcher.BorsToml{
          status: Map.get(toml, "status", []),
          use_squash_merge:
            Map.get(
              toml,
              "use_squash_merge",
              false
            ),
          block_labels: Map.get(toml, "block_labels", []),
          pr_status: Map.get(toml, "pr_status", []),
          timeout_sec: Map.get(toml, "timeout_sec", 60 * 60),
          prerun_timeout_sec: Map.get(toml, "prerun_timeout_sec", 30 * 60),
          required_approvals: Map.get(toml, "required_approvals", nil),
          up_to_date_approvals: Map.get(toml, "up_to_date_approvals", false),
          cut_body_after: Map.get(toml, "cut_body_after", nil),
          delete_merged_branches:
            Map.get(
              toml,
              "delete_merged_branches",
              false
            ),
          use_codeowners:
            Map.get(
              toml,
              "use_codeowners",
              false
            ),
          committer: committer,
          commit_title: Map.get(toml, "commit_title", "Merge ${PR_REFS}"),
          update_base_for_deletes: Map.get(toml, "update_base_for_deletes", false),
          max_batch_size: Map.get(toml, "max_batch_size", nil),
          delegation_default_expiry_sec: delegation_default_expiry_sec,
          delegation_invalidate_on_paths: delegation_invalidate_on_paths,
          delegation_restrict_to_paths: delegation_restrict_to_paths
        }

        case toml do
          %{status: status} when not is_list(status) ->
            {:error, :status}

          %{block_labels: block_labels} when not is_list(block_labels) ->
            {:error, :block_labels}

          %{pr_status: pr_status} when not is_list(pr_status) ->
            {:error, :pr_status}

          %{timeout_sec: timeout_sec} when not is_integer(timeout_sec) ->
            {:error, :timeout_sec}

          %{prerun_timeout_sec: prerun_timeout_sec} when not is_integer(prerun_timeout_sec) ->
            {:error, :prerun_timeout_sec}

          %{required_approvals: req_approve}
          when not is_integer(req_approve) and not is_nil(req_approve) ->
            {:error, :required_approvals}

          %{cut_body_after: c} when not is_binary(c) and not is_nil(c) ->
            {:error, :cut_body_after}

          %{status: [], block_labels: [], pr_status: []} ->
            {:error, :empty_config}

          %{committer: %{name: n, email: e}} when is_nil(n) or is_nil(e) ->
            {:error, :committer_details}

          %{commit_title: msg} when not is_binary(msg) and not is_nil(msg) ->
            {:error, :commit_title}

          %{max_batch_size: max_batch_size}
          when not is_nil(max_batch_size) and not is_integer(max_batch_size) ->
            {:error, :max_batch_size}

          %{delegation_default_expiry_sec: secs}
          when secs == :invalid or
                 (not is_nil(secs) and (not is_integer(secs) or secs <= 0)) ->
            {:error, :delegation_default_expiry_sec}

          %{delegation_invalidate_on_paths: paths} when not is_list(paths) ->
            {:error, :delegation_invalidate_on_paths}

          %{delegation_restrict_to_paths: paths} when not is_list(paths) ->
            {:error, :delegation_restrict_to_paths}

          toml ->
            status =
              toml.status
              |> Enum.map(&GitHub.map_changed_status/1)
              |> Enum.uniq()

            pr_status =
              toml.pr_status
              |> Enum.map(&GitHub.map_changed_status/1)
              |> Enum.uniq()

            cond do
              Enum.count(status) != Enum.count(toml.status) ->
                {:error, :status}

              Enum.count(pr_status) != Enum.count(toml.pr_status) ->
                {:error, :pr_status}

              is_integer(toml.delegation_default_expiry_sec) and
                  toml.delegation_default_expiry_sec >
                    BorsNG.Command.delegation_max_duration_sec() ->
                {:error, :delegation_default_expiry_sec}

              not Enum.all?(toml.delegation_invalidate_on_paths, &valid_glob?/1) ->
                {:error, :delegation_invalidate_on_paths}

              not Enum.all?(toml.delegation_restrict_to_paths, &valid_glob?/1) ->
                {:error, :delegation_restrict_to_paths}

              true ->
                {:ok, %{toml | status: status, pr_status: pr_status}}
            end
        end

      {:error, _error} ->
        {:error, :parse_failed}
    end
  end
end
