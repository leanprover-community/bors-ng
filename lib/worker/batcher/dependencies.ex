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
    request. As in issue-regex, which dependent-issues uses, an owner or
    repository name has at least two characters, so `x/y#5` is no reference.
    A word character is ASCII, so `#5é` reads `#5`.

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

  # The regex spells out its classes and its case, with no `\w`, `\b` or
  # `:caseless`, because PCRE's are not JavaScript's. Erlang builds PCRE's
  # tables for Latin-1, so its `\w` and `\b` take letters such as `é` and `ª`.
  # Its `:caseless` folds the Kelvin sign into `k` and `ſ` into `s`.
  # dependent-issues compiles with `gi`: `\w` and `\d` are ASCII, and `i`
  # never folds a letter outside ASCII into one inside it.

  # JavaScript's `\s`.
  @space ~S"[\t\n\x{0b}\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]"

  # issue-regex's `\w[\w-.]+`: an owner or a repository name.
  @name "[A-Za-z0-9_][A-Za-z0-9_.-]+"

  # issue-regex's `[1-9]\d*\b`: a whole number, with no word character after it.
  @number "([1-9][0-9]*)(?![A-Za-z0-9_])"

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
    # GitHub names are case-insensitive, so each dependency is listed once.
    |> Enum.uniq_by(fn
      {:local, n} -> {:local, n}
      {:external, repo, n} -> {:external, String.downcase(repo), n}
    end)
  end

  # dependent-issues' references: issue-regex (`#N`, `owner/repo#N`), then a
  # link to an issue or pull request.
  defp dependency_regex(keywords) do
    keywords =
      Enum.map_join(keywords, "|", fn keyword ->
        keyword
        |> String.split()
        |> Enum.map_join("#{@space}+", &caseless/1)
      end)

    issue = "(?:(#{@name})/(#{@name}))?##{@number}"

    link =
      "#{caseless("http")}#{caseless("s")}?://#{caseless("github.com")}/" <>
        "(#{@name})/(#{@name})/(?:#{caseless("issues")}|#{caseless("pull")})/#{@number}"

    Regex.compile!("(?:#{keywords})#{@space}+(?:#{issue}|#{link})", [:unicode])
  end

  # `text` in any case, as JavaScript's `i` flag matches it: each letter also
  # matches its other case, but never across ASCII and the rest.
  defp caseless(text) do
    text
    |> String.codepoints()
    |> Enum.map_join(fn char ->
      [char, String.upcase(char), String.downcase(char)]
      |> Enum.uniq()
      |> Enum.filter(&(match?([_], String.codepoints(&1)) and ascii?(&1) == ascii?(char)))
      |> case do
        [char] -> Regex.escape(char)
        chars -> "(?:#{Enum.map_join(chars, "|", &Regex.escape/1)})"
      end
    end)
  end

  defp ascii?(<<char::utf8>>), do: char < 128

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
  whether a dependency is closed and none surely blocks. After one such error,
  bors asks GitHub nothing more, so a check costs at most one failed read.
  """
  @spec check(GitHub.tconn(), Patch.t(), binary | nil, [binary], binary) ::
          :clear | {:blocked, [binary]} | {:error, term}
  def check(repo_conn, patch, body, keywords, repo_name) do
    case references(body, keywords, repo_name) do
      [] -> :clear
      references -> check_references(repo_conn, patch, references)
    end
  end

  defp check_references(repo_conn, patch, references) do
    known = known(patch, for({:local, n} <- references, do: n))

    references
    |> Enum.reduce({[], nil}, fn ref, {blocking, error} ->
      case state(repo_conn, known, ref, error) do
        {:ok, state} when state in [:bundled, :closed] -> {blocking, error}
        {:ok, _open_or_missing} -> {[format(ref) | blocking], error}
        :unasked -> {blocking, error}
        new_error -> {blocking, new_error}
      end
    end)
    |> case do
      {[], nil} -> :clear
      {[], error} -> error
      {blocking, _} -> {:blocked, Enum.reverse(blocking)}
    end
  end

  # What bors's records say of `numbers`: `:bundled` for those in the patch's
  # bundle (the patch itself included), and otherwise `:open` or `:closed` for
  # those it has as pull requests of the patch's project.
  defp known(_patch, []), do: %{}

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

  # A state from bors's records, or else from GitHub, unless GitHub has
  # already failed to answer during this check.
  defp state(_repo_conn, known, {:local, n}, _error) when is_map_key(known, n),
    do: {:ok, known[n]}

  defp state(_repo_conn, _known, _ref, error) when error != nil, do: :unasked
  defp state(repo_conn, _known, {:local, n}, nil), do: GitHub.get_issue_state(repo_conn, nil, n)

  defp state(repo_conn, _known, {:external, repo, n}, nil),
    do: GitHub.get_issue_state(repo_conn, repo, n)

  defp format({:local, n}), do: "##{n}"
  defp format({:external, repo, n}), do: "#{repo}##{n}"
end
