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
  pull request that needs it. The label does not block on its own. It blocks
  only when the description lists nothing bors can read, as a backstop for a
  dependency the labeller found and bors did not.

  The parser reads what dependent-issues reads, no more and no less: a keyword,
  whitespace, then one reference right after it. Reading less would merge a
  pull request ahead of a dependency. Reading more would block pull requests
  that merge today, on text no dependency tool treats as a dependency.

  - Keywords are literal text, matched in any case. Their spaces match any
    whitespace. dependent-issues takes keywords as regular expressions, so
    mathlib4's `- \\[ \\] depends on:` is `- [ ] depends on:` here.
  - Whitespace is JavaScript's `\\s`, newlines and Unicode spaces included.
  - A reference is `#N`, `owner/repo#N`, or a link to a GitHub issue or pull
    request.

  A dependency in another repository blocks: bors only knows the pull requests
  of this one. So does a number bors has no pull request for, such as an
  issue. Whether a dependency is closed comes from bors's own records, which
  webhooks keep current. Asking GitHub about a number that is not a pull
  request would retry its 404 for minutes inside the batcher.
  """

  alias BorsNG.Database.Patch
  alias BorsNG.Database.Repo
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

  @type ref :: {:local, pos_integer} | {:external, binary}

  @doc """
  The dependencies `body` lists after one of `keywords`. References to
  `repo_name` come back as `{:local, n}`, others as
  `{:external, "owner/repo#n"}`, in order of appearance and without repeats.
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
      {:external, "#{owner}/#{repo}##{number}"}
    end
  end

  @doc """
  Which dependencies `body`, the description of `patch`, lists that still
  block it:

  - `:clear` when every one is merged, closed, or in the patch's bundle.
  - `{:blocked, refs}` with the ones that are not, as `#N` or `owner/repo#N`.
  - `:unlisted` when it lists none.
  """
  @spec check(Patch.t(), binary | nil, [binary], binary) ::
          :clear | :unlisted | {:blocked, [binary]}
  def check(patch, body, keywords, repo_name) do
    case references(body, keywords, repo_name) do
      [] ->
        :unlisted

      references ->
        resolved = resolved(patch, for({:local, n} <- references, do: n))

        references
        |> Enum.reject(fn
          {:local, n} -> MapSet.member?(resolved, n)
          {:external, _} -> false
        end)
        |> case do
          [] -> :clear
          blocking -> {:blocked, Enum.map(blocking, &format/1)}
        end
    end
  end

  # The numbers among `numbers` that are in the patch's bundle (the patch
  # itself included) or that bors has as closed pull requests.
  defp resolved(patch, numbers) do
    bundled =
      patch
      |> Bundles.members_or_self()
      |> MapSet.new(& &1.pr_xref)

    lookup = Enum.reject(numbers, &(&1 > @max_pr_xref or MapSet.member?(bundled, &1)))

    closed =
      from(p in Patch,
        where: p.project_id == ^patch.project_id,
        where: p.pr_xref in ^lookup,
        where: not p.open,
        select: p.pr_xref
      )
      |> Repo.all()

    MapSet.union(bundled, MapSet.new(closed))
  end

  defp format({:local, n}), do: "##{n}"
  defp format({:external, ref}), do: ref
end
