defmodule BorsNG.GitHub.GitHubPrTest do
  use BorsNG.ConnCase

  setup do
    pr_standard = %{
      "number" => 1,
      "title" => "T",
      "body" => "B",
      "state" => "open",
      "base" => %{"ref" => "OTHER_BRANCH", "repo" => %{"id" => 456}},
      "head" => %{
        "sha" => "B",
        "ref" => "BAR_BRANCH",
        "repo" => %{
          "id" => 345
        }
      },
      "merged_at" => nil,
      "user" => %{
        "id" => 23,
        "login" => "ghost",
        "avatar_url" => "U"
      }
    }

    {:ok, pr_standard: pr_standard}
  end

  test "can parse a Poison-decoded JSON *without* mergeable field", %{pr_standard: pr_standard} do
    pr_without_field = pr_standard

    result = BorsNG.GitHub.Pr.from_json(pr_without_field)

    assert result ==
             {:ok,
              %BorsNG.GitHub.Pr{
                number: 1,
                title: "T",
                body: "B",
                state: :open,
                base_ref: "OTHER_BRANCH",
                head_sha: "B",
                head_ref: "BAR_BRANCH",
                head_repo_id: 345,
                base_repo_id: 456,
                user: %BorsNG.GitHub.User{
                  id: 23,
                  login: "ghost",
                  avatar_url: "U"
                },
                merged: false,
                mergeable: nil,
                draft: false
              }}
  end

  test "can parse a Poison-decoded JSON *with* mergeable field", %{pr_standard: pr_standard} do
    pr_with_field = Map.put(pr_standard, "mergeable", true)

    result = BorsNG.GitHub.Pr.from_json(pr_with_field)

    assert result ==
             {:ok,
              %BorsNG.GitHub.Pr{
                number: 1,
                title: "T",
                body: "B",
                state: :open,
                base_ref: "OTHER_BRANCH",
                head_sha: "B",
                head_ref: "BAR_BRANCH",
                head_repo_id: 345,
                base_repo_id: 456,
                user: %BorsNG.GitHub.User{
                  id: 23,
                  login: "ghost",
                  avatar_url: "U"
                },
                merged: false,
                mergeable: true,
                draft: false
              }}
  end

  # GitHub gives `"repo": null` once the head's repository is deleted, as a
  # fork is when its owner deletes it.
  test "parses a PR whose head repository is gone, as no repository's", %{
    pr_standard: pr_standard
  } do
    pr_without_repo = put_in(pr_standard, ["head", "repo"], nil)

    for json <- [pr_without_repo, Map.put(pr_without_repo, "mergeable", false)] do
      assert {:ok, pr} = BorsNG.GitHub.Pr.from_json(json)

      assert %BorsNG.GitHub.Pr{
               number: 1,
               head_sha: "B",
               head_ref: "BAR_BRANCH",
               head_repo_id: 0,
               base_repo_id: 456
             } = pr

      assert pr == BorsNG.GitHub.Pr.from_json!(json)
    end
  end
end
