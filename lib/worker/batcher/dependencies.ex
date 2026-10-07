defmodule BorsNG.Worker.Batcher.Dependencies do
  @moduledoc """
  Read the dependencies a pull request's description lists, and decide which
  of them still block it. Configured by the `[dependencies]` table of
  `bors.toml`.

  On mathlib4, the dependent-issues action reads lines such as
  `- [ ] depends on: #123` and puts `blocked-by-other-PR` on a pull request
  while any of them is open. The description is the source of truth. The label
  is a copy of it, up to one cron interval old, and dependent-issues takes it
  off any pull request that lists no dependency. dependent-issues knows nothing
  of bundles, so a pull request linked or stacked with its dependency keeps the
  label.

  So bors reads the description itself, on every check, and blocks while a
  dependency it lists is open and outside the pull request's bundle. A bundle
  lands in one push or not at all, so a dependency in it cannot land after the
  pull request that needs it. bors does not read the label.

  The parser reads what dependent-issues reads, no more and no less: a keyword,
  whitespace, then one reference right after it. Reading less would merge a
  pull request ahead of a dependency. Reading more would block pull requests
  that merge today, on text no dependency tool treats as a dependency. The
  keywords in `bors.toml` must match the labeller's exactly, for the same
  reason.

  - Keywords are literal text, matched in any case. Their spaces match any
    whitespace. dependent-issues takes keywords as regular expressions, so
    mathlib4's `- \\[ \\] depends on:` is `- [ ] depends on:` here.
  - Whitespace is JavaScript's `\\s`, newlines and Unicode spaces included.
  - A reference is `#N`, `owner/repo#N`, or a link to a GitHub issue or pull
    request.

  Whether a pull request of this repository is open comes from bors's own
  records, which webhooks keep current. bors asks GitHub about the rest:
  dependencies in other repositories, and numbers it has no pull request for,
  such as issues. As with dependent-issues, a closed one does not block and an
  open one does. So does one GitHub does not show bors, because it does not
  exist or is in a private repository bors is not installed on.
  """

  alias BorsNG.Database.Patch
  alias BorsNG.Database.Repo
  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.Bundles

  import Ecto.Query

  # JavaScript's `\s`. Without `:ucp`, PCRE's `\s` lacks the Unicode spaces,
  # while `\w`, `\d` and `\b` stay ASCII, as in JavaScript.
  @space ~S"[\s\x{0b}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]"

  # dependent-issues' references: issue-regex (`#N`, `owner/repo#N`), then a
  # link to an issue or pull request.
  @reference ~S"(?:(\w[\w.-]+)/(\w[\w.-]+))?#([1-9]\d*)\b|https?://github\.com/(\w[\w.-]+)/(\w[\w.-]+)/(?:issues|pull)/([1-9]\d*)\b"

  # `pr_xref` is a 32-bit integer column. A larger number is no pull request,
  # and querying it would raise.
  @max_pr_xref 2_147_483_647

  @type ref :: {:local, pos_integer} | {:external, binary, pos_integer}

  @doc """
  The dependencies `body` lists after one of `keywords`. References to
  `repo_name` come back as `{:local, n}`, others as
  `{:external, "owner/repo", n}`, in order of appearance and without repeats.
  """
  @spec references(binary | nil, [binary], binary) :: [ref]
  def references(nil, _keywords, _repo_name), do: []

  def references(body, keywords, repo_name) do
    keywords
    |> dependency_regex()
    |> Regex.scan(String.replace_invalid(body), capture: :all_but_first)
    |> Enum.map(fn
      [_, _, _, owner, repo, number] -> reference(owner, repo, number, repo_name)
      [owner, repo, number] -> reference(owner, repo, number, repo_name)
    end)
    |> Enum.uniq()
  end

  defp dependency_regex(keywords) do
    keywords =
      Enum.map_join(keywords, "|", fn keyword ->
        keyword
        |> String.split()
        |> Enum.map_join("#{@space}+", &Regex.escape/1)
      end)

    Regex.compile!("(?:#{keywords})#{@space}+(?:#{@reference})", [:unicode, :caseless])
  end

  defp reference("", "", number, _repo_name), do: {:local, String.to_integer(number)}

  defp reference(owner, repo, number, repo_name) do
    if String.downcase("#{owner}/#{repo}") == String.downcase(repo_name) do
      {:local, String.to_integer(number)}
    else
      {:external, "#{owner}/#{repo}", String.to_integer(number)}
    end
  end

  @doc """
  Which dependencies `body`, the description of `patch`, lists that still
  block it: `:clear` when every one is merged, closed, or in the patch's
  bundle (or it lists none), and otherwise `{:blocked, refs}` with the ones
  that are not, as `#N` or `owner/repo#N`. An error when GitHub cannot say
  whether a dependency is closed.
  """
  @spec check(GitHub.tconn(), Patch.t(), binary | nil, [binary], binary) ::
          :clear | {:blocked, [binary]} | {:error, term}
  def check(repo_conn, patch, body, keywords, repo_name) do
    references = references(body, keywords, repo_name)
    known = known(patch, for({:local, n} <- references, do: n))

    references
    |> Enum.reduce_while([], fn ref, blocking ->
      case state(repo_conn, known, ref) do
        {:ok, state} when state in [:bundled, :closed] -> {:cont, blocking}
        {:ok, _open_or_missing} -> {:cont, [format(ref) | blocking]}
        error -> {:halt, error}
      end
    end)
    |> case do
      [] -> :clear
      blocking when is_list(blocking) -> {:blocked, Enum.reverse(blocking)}
      error -> error
    end
  end

  # What bors's records say of `numbers`: `:bundled` for those in the patch's
  # bundle (the patch itself included), and otherwise `:open` or `:closed` for
  # those it has as pull requests of the patch's project.
  defp known(patch, numbers) do
    bundled =
      patch
      |> Bundles.members_or_self()
      |> Map.new(&{&1.pr_xref, :bundled})

    lookup = Enum.reject(numbers, &(&1 > @max_pr_xref or Map.has_key?(bundled, &1)))

    from(p in Patch,
      where: p.project_id == ^patch.project_id,
      where: p.pr_xref in ^lookup,
      select: {p.pr_xref, p.open}
    )
    |> Repo.all()
    |> Map.new(fn {n, open} -> {n, if(open, do: :open, else: :closed)} end)
    |> Map.merge(bundled)
  end

  defp state(_repo_conn, known, {:local, n}) when is_map_key(known, n), do: {:ok, known[n]}
  defp state(repo_conn, _known, {:local, n}), do: GitHub.get_issue_state(repo_conn, nil, n)

  defp state(repo_conn, _known, {:external, repo, n}),
    do: GitHub.get_issue_state(repo_conn, repo, n)

  defp format({:local, n}), do: "##{n}"
  defp format({:external, repo, n}), do: "#{repo}##{n}"
end
