defmodule BorsNG.Worker.Batcher.Dependencies do
  @moduledoc """
  Decide whether the `[dependencies]` label of `bors.toml` still blocks a pull
  request.

  On mathlib4, the dependent-issues action puts `blocked-by-other-PR` on every
  pull request whose description lists an open dependency, as in
  `- [ ] depends on: #123`, and takes it off once they are all closed. It knows
  nothing of bundles. A pull request linked or stacked with its dependency
  keeps the label, so the bundle could never queue.

  bors leaves the label alone and looks past it: the label stops blocking once
  every dependency the description lists is merged, closed, or in the pull
  request's bundle. A bundle lands in one push or not at all, so a dependency in
  it cannot land after the pull request that needs it.

  A mistake one way merges a pull request ahead of its dependency. A mistake
  the other way blocks it, as the label did before. So every doubt blocks:

  - The label still triggers the check. Without it nothing is read, and
    nothing changes.
  - bors has to find at least every dependency the labeller finds, not the same
    ones. It reads every reference on the rest of a keyword's line, not just
    the first. If there is none, it reads the next non-blank line, since the
    labeller lets whitespace, newlines included, separate a keyword from its
    reference.
  - A label with no dependency bors can read keeps blocking. Someone may have
    added it by hand.
  - A dependency in another repository blocks. So does a number bors has no
    pull request for, such as an issue.
  - Whether a dependency is closed comes from bors's own records, which
    webhooks keep current. Asking GitHub about a number that is not a pull
    request would retry its 404 for minutes inside the batcher.
  """

  alias BorsNG.Database.Patch
  alias BorsNG.Database.Repo
  alias BorsNG.Worker.Batcher.Bundles

  import Ecto.Query

  # `#N`, `owner/repo#N`, and links to GitHub issues and pull requests. A
  # superset of what dependent-issues reads.
  @reference ~r{(?:https?://)?(?:www\.)?github\.com/([\w.-]+)/([\w.-]+)/(?:issues|pull)/([1-9]\d*)|(?:([\w.-]+)/([\w.-]+))?#([1-9]\d*)}i

  # `pr_xref` is a 32-bit integer column. A larger number is no pull request,
  # and querying it would raise.
  @max_pr_xref 2_147_483_647

  @type ref :: {:local, pos_integer} | {:external, binary}

  @doc """
  The dependencies `body` lists after one of `keywords`. A keyword matches in
  any case, and its spaces match any whitespace. References to `repo_name`
  come back as `{:local, n}`, others as `{:external, "owner/repo#n"}`, in order
  of appearance and without repeats.
  """
  @spec references(binary | nil, [binary], binary) :: [ref]
  def references(nil, _keywords, _repo_name), do: []

  def references(body, keywords, repo_name) do
    keywords
    |> keyword_regex()
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(fn [{start, length}] ->
      body
      |> binary_part(start + length, byte_size(body) - start - length)
      |> String.split("\n")
      |> references_after_keyword(repo_name)
    end)
    |> Enum.uniq()
  end

  defp keyword_regex(keywords) do
    keywords
    |> Enum.map_join("|", fn keyword ->
      keyword
      |> String.split()
      |> Enum.map_join("\\s+", &Regex.escape/1)
    end)
    |> Regex.compile!("iu")
  end

  # The rest of the keyword's line, or else the next line that is not blank.
  defp references_after_keyword([rest | lines], repo_name) do
    case references_in(rest, repo_name) do
      [] ->
        case Enum.find(lines, &(String.trim(&1) != "")) do
          nil -> []
          line -> references_in(line, repo_name)
        end

      found ->
        found
    end
  end

  defp references_in(text, repo_name) do
    @reference
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn
      [owner, repo, number] -> reference(owner, repo, number, repo_name)
      ["", "", "", owner, repo, number] -> reference(owner, repo, number, repo_name)
    end)
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
  Whether the `[dependencies]` label still blocks `patch`, whose description
  is `body`:

  - `:clear` when every dependency it lists is merged, closed, or in its bundle.
  - `{:blocked, refs}` with the ones that are not, as `#N` or `owner/repo#N`.
  - `:unlisted` when it lists no dependency bors can read.
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
