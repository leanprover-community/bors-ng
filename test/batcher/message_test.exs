defmodule BorsNG.Worker.BatcherMessageTest do
  use ExUnit.Case, async: true

  alias BorsNG.Worker.Batcher.Message

  test "suppress pings" do
    assert Message.suppress_pings(nil) == nil
    assert Message.suppress_pings("") == ""
    assert Message.suppress_pings("basic") == "basic"
    assert Message.suppress_pings("basic\n") == "basic\n"
    assert Message.suppress_pings("basic\nbasic") == "basic\nbasic"
    assert Message.suppress_pings("@someone\nbasic") == "`@someone`\nbasic"
    assert Message.suppress_pings("@someone\n@else") == "`@someone`\n`@else`"
    assert Message.suppress_pings("me@example.com") == "me@example.com"
  end

  test "generate configuration problem message" do
    expected_message = "Configuration problem:\nExample problem"
    actual_message = Message.generate_message({:config, "Example problem"})
    assert expected_message == actual_message
  end

  test "every bors.toml error key has an explicit, friendly renderer" do
    # Single source of truth: BorsToml's @type err (introspected below), plus
    # the fetch-layer-only :fetch_failed. Adding a new validation key extends
    # that type, which makes this test require an explicit
    # generate_bors_toml_error/1 clause for it. Forget the clause and the key
    # falls through to the catch-all, which this test detects and fails on — so
    # a new key can't silently ship with a generic message (or, before the
    # catch-all existed, crash the batcher).
    keys = bors_toml_error_keys() ++ [:fetch_failed]

    # Reconstruct the catch-all's output for a key by templating from a sentinel
    # that has no explicit clause, so this stays correct if the catch-all
    # wording changes.
    sentinel = :__unhandled_sentinel_key__

    catch_all = fn key ->
      String.replace(
        Message.generate_bors_toml_error(sentinel),
        to_string(sentinel),
        to_string(key)
      )
    end

    for key <- keys do
      message = Message.generate_bors_toml_error(key)
      assert is_binary(message)
      assert String.contains?(message, "bors.toml")

      refute message == catch_all.(key),
             "#{inspect(key)} has no explicit generate_bors_toml_error/1 clause; it falls " <>
               "through to the catch-all. Add a friendly message in message.ex."
    end
  end

  test "unknown bors.toml error keys fall back to the catch-all renderer" do
    message = Message.generate_bors_toml_error(:some_future_key)
    assert is_binary(message)
    assert String.contains?(message, "bors.toml")
  end

  # Atom members of BorsToml's `@type err` union, read from the compiled
  # typespec so this list can't drift from the source of truth.
  defp bors_toml_error_keys do
    {:ok, types} = Code.Typespec.fetch_types(BorsNG.Worker.Batcher.BorsToml)
    {_, {:err, definition, []}} = Enum.find(types, fn {_, {name, _, _}} -> name == :err end)
    {:type, _, :union, members} = definition
    Enum.map(members, fn {:atom, _, atom} -> atom end)
  end

  test "generate retry message" do
    expected_message = "Build failed (retrying...):\n  * stat"
    example_statuses = [%{url: nil, identifier: "stat"}]
    actual_message = Message.generate_message({:retrying, example_statuses})
    assert expected_message == actual_message
  end

  test "generate retry message w/ url" do
    expected_message = "Build failed (retrying...):\n  * [stat](x)"
    example_statuses = [%{url: "x", identifier: "stat"}]
    actual_message = Message.generate_message({:retrying, example_statuses})
    assert expected_message == actual_message
  end

  test "generate failure message" do
    expected_message =
      "Build failed:\n  * stat\n\nFix if necessary, and then someone with permission can run `bors r+` or `bors retry`."

    example_statuses = [%{url: nil, identifier: "stat"}]
    actual_message = Message.generate_message({:failed, example_statuses})
    assert expected_message == actual_message
  end

  test "generate success message" do
    expected_message = "Build succeeded:\n  * stat"
    example_statuses = [%{url: nil, identifier: "stat"}]
    actual_message = Message.generate_message({:succeeded, example_statuses})
    assert expected_message == actual_message
  end

  test "generate conflict message" do
    expected_message =
      "Merge conflict.\n\nMerge or rebase `main` into this PR and resolve the conflict, then someone with permission can run `bors r+` or `bors retry`."

    actual_message = Message.generate_message({:conflict, :failed, "main"})
    assert expected_message == actual_message
  end

  test "generate canceled message" do
    expected_message =
      "Bors build canceled.\n\nAddress comments or fix if necessary, and then someone with permission can run `bors r+`."

    actual_message = Message.generate_message({:canceled, :failed, :requested})
    assert expected_message == actual_message
  end

  test "generate canceled message names the push as the reason and defers to the delegation comment" do
    expected_message =
      "Bors build canceled because the PR branch was pushed to.\n\nThis cancels the in-progress bors run; if the push also touched a delegation-restricted path, any affected delegation is revoked in a separate comment. Address comments or fix if necessary, and then someone with permission can re-run `bors r+` once the PR is ready."

    actual_message = Message.generate_message({:canceled, :failed, :push})
    assert expected_message == actual_message
  end

  test "generate canceled message is suppressed for closed and draft PRs" do
    assert nil == Message.generate_message({:canceled, :failed, :closed})
    assert nil == Message.generate_message({:canceled, :failed, :draft})
  end

  test "generate canceled/retry message" do
    expected_message =
      "This PR was included in a batch that was canceled, it will be automatically retried"

    actual_message = Message.generate_message({:canceled, :retrying})
    assert expected_message == actual_message
  end

  test "generate timeout message" do
    expected_message =
      "Timed out.\n\nFix if necessary, and then someone with permission can run `bors r+` or `bors retry`."

    actual_message = Message.generate_message({:timeout, :failed})
    assert expected_message == actual_message
  end

  test "generate timeout/retry message" do
    expected_message =
      "This PR was included in a batch that timed out, it will be automatically retried"

    actual_message = Message.generate_message({:timeout, :retrying})
    assert expected_message == actual_message
  end

  test "generate try timeout message suggests `bors try`, not `bors r+`" do
    expected_message = "Timed out.\n\nFix if necessary, and then run `bors try` again."

    actual_message = Message.generate_message({:timeout, :try})
    assert expected_message == actual_message
  end

  test "generate try failure message suggests `bors try`, not `bors r+`" do
    expected_message =
      "Build failed:\n  * stat\n\nFix if necessary, and then run `bors try` again."

    example_statuses = [%{url: nil, identifier: "stat"}]
    actual_message = Message.generate_message({:try_failed, example_statuses})
    assert expected_message == actual_message
  end

  test "generate push failed (non fast-forward) message" do
    expected_message =
      "This PR was included in a batch that successfully built, but then failed to merge into main (it was a non-fast-forward update). It will be automatically retried."

    actual_message = Message.generate_message({:push_failed_non_ff, "main"})
    assert expected_message == actual_message
  end

  test "generate push failed (unknown) message" do
    expected_message = """
    This PR was included in a batch that successfully built, but then failed to merge into main. It will not be retried.

    Additional information:

    ```json
    Response status code: 500
    {"status": 500, "message": "Internal server error."}
    ```
    """

    actual_message =
      Message.generate_message(
        {:push_failed_unknown_failure, "main", 500,
         ~c'{"status": 500, "message": "Internal server error."}'}
      )

    assert expected_message == actual_message
  end

  test "generate merged into master message" do
    expected_message = "Pull request successfully merged into master.\n\nBuild succeeded:"
    actual_message = Message.generate_message({:merged, :squashed, "master", []})
    assert expected_message == actual_message
  end

  test "generate commit message" do
    expected_message = """
    Merge #1 #2

    1: Alpha r=r a=lag

    a

    2: Beta r=s a=leg

    b

    Co-authored-by: foo
    Co-authored-by: bar
    """

    patches = [
      %{
        patch: %{
          pr_xref: 1,
          title: "Alpha",
          body: "a",
          author: %{login: "lag"}
        },
        reviewer: "r"
      },
      %{
        patch: %{
          pr_xref: 2,
          title: "Beta",
          body: "b",
          author: %{login: "leg"}
        },
        reviewer: "s"
      }
    ]

    co_authors = ["foo", "bar"]
    actual_message = Message.generate_commit_message(patches, nil, co_authors)
    assert expected_message == actual_message
  end

  test "generate custom commit message" do
    expected_message = """
    merge: #1 PR

    1: Alpha r=r a=lag

    a

    Co-authored-by: foo
    Co-authored-by: bar
    """

    patches = [
      %{
        patch: %{
          pr_xref: 1,
          title: "Alpha",
          body: "a",
          author: %{login: "lag"}
        },
        reviewer: "r"
      }
    ]

    co_authors = ["foo", "bar"]

    actual_message =
      Message.generate_commit_message(patches, nil, co_authors, "merge: ${PR_REFS} PR")

    assert expected_message == actual_message
  end

  test "cut body" do
    assert "a" == Message.cut_body("abc", "b")
  end

  test "cut body with multiple matches" do
    assert "aa" == Message.cut_body("aabcbd", "b")
  end

  test "cut whole body" do
    assert "" == Message.cut_body("abc", "")
  end

  test "cut body with no match" do
    assert "ac" == Message.cut_body("ac", "b")
  end

  test "cut body with nil text" do
    assert "" == Message.cut_body(nil, "b")
  end

  test "cut body with phantom newline before start of string" do
    assert "" == Message.cut_body("---\n hey ignore me", "\n---")
  end

  test "cut commit message bodies" do
    expected_message = """
    Merge #1

    1: Synchronize background and foreground processing r=bill a=pea

    Fixes that annoying bug.

    Co-authored-by: foo
    """

    title = "Synchronize background and foreground processing"

    body = """
    Fixes that annoying bug.

    <!-- boilerplate follows -->

    Thank you for contributing to my awesome OSS project!
    To make sure your PR is accepted ASAP, make sure all of this
    stuff is done:

    - [ ] Run the linter
    - [ ] Run any new or changed tests
    - [ ] This PR fixes #___ (fill in if it exists)
    - [ ] Make sure your commit messages make sense
    """

    patches = [
      %{
        patch: %{
          pr_xref: 1,
          title: title,
          body: body,
          author: %{login: "pea"}
        },
        reviewer: "bill"
      }
    ]

    co_authors = ["foo"]

    actual_message =
      Message.generate_commit_message(
        patches,
        "\n\n<!-- boilerplate follows -->",
        co_authors
      )

    assert expected_message == actual_message
  end

  test "cut commit message bodies in squash commits" do
    expected_message = """
    Synchronize background and foreground processing (#1)

    Fixes that annoying bug.

    Co-authored-by: B <b@b>
    """

    title = "Synchronize background and foreground processing"

    # also test that whitespace is cut
    body = """
    Fixes that annoying bug.



    <!-- boilerplate follows -->

    Thank you for contributing to my awesome OSS project!
    To make sure your PR is accepted ASAP, make sure all of this
    stuff is done:

    - [ ] Run the linter
    - [ ] Run any new or changed tests
    - [ ] This PR fixes #___ (fill in if it exists)
    - [ ] Make sure your commit messages make sense
    """

    user_email = "a@a"
    user_name = "A"

    pr = %{
      number: 1,
      title: title,
      body: body
    }

    commits = [
      %{author_email: user_email, author_name: "A"},
      %{author_email: "b@b", author_name: "B"},
      %{author_email: user_email, author_name: "A"},
      %{author_email: "b@b", author_name: "B"}
    ]

    actual_message =
      Message.generate_squash_commit_message(
        pr,
        commits,
        user_email,
        user_name,
        "\n\n<!-- boilerplate follows -->"
      )

    assert expected_message == actual_message
  end

  test "commit message from squash commits contains both co-authored lines from PR body and commits" do
    expected_message = """
    Synchronize background and foreground processing (#1)

    Fixes that annoying bug.

    Co-authored-by: C <c@c>
    Co-authored-by: E <e@e>
    Co-authored-by: D <d@d>
    Co-authored-by: B <b@b>
    """

    title = "Synchronize background and foreground processing"

    # also test that extra whitespace which confuses GitHub gets stripped
    body = """
    Fixes that annoying bug.

    Co-authored-by: C <c@c>
    Co-authored-by: E <e@e>

    Co-authored-by: D <d@d>
    Co-authored-by: C <c@c>


    <!-- boilerplate follows -->

    Thank you for contributing to my awesome OSS project!
    To make sure your PR is accepted ASAP, make sure all of this
    stuff is done:

    - [ ] Run the linter
    - [ ] Run any new or changed tests
    - [ ] This PR fixes #___ (fill in if it exists)
    - [ ] Make sure your commit messages make sense
    """

    user_email = "a@a"
    user_name = "A"

    pr = %{
      number: 1,
      title: title,
      body: body
    }

    commits = [
      %{author_email: user_email, author_name: "A"},
      %{author_email: "b@b", author_name: "B"},
      %{author_email: user_email, author_name: "A"},
      %{author_email: "b@b", author_name: "B"},
      %{author_email: "e@e", author_name: "E"},
      %{author_email: user_email, author_name: "A"}
    ]

    actual_message =
      Message.generate_squash_commit_message(
        pr,
        commits,
        user_email,
        user_name,
        "\n\n<!-- boilerplate follows -->"
      )

    assert expected_message == actual_message
  end

  test "commit message from squash commits does not include co-authored-by lines for commits by PR author" do
    expected_message = """
    Synchronize background and foreground processing (#1)

    Fixes that annoying bug.

    Co-authored-by: C <c@c>
    Co-authored-by: E <e@e>
    Co-authored-by: D <d@d>
    """

    title = "Synchronize background and foreground processing"

    # also test that extra whitespace which confuses GitHub gets stripped
    body = """
    Fixes that annoying bug.

    Co-authored-by: C <c@c>
    Co-authored-by: E <e@e>

    Co-authored-by: D <d@d>
    Co-authored-by: C <c@c>


    <!-- boilerplate follows -->

    Thank you for contributing to my awesome OSS project!
    To make sure your PR is accepted ASAP, make sure all of this
    stuff is done:

    - [ ] Run the linter
    - [ ] Run any new or changed tests
    - [ ] This PR fixes #___ (fill in if it exists)
    - [ ] Make sure your commit messages make sense
    """

    user_email = "a@a"
    user_name = "A"

    pr = %{
      number: 1,
      title: title,
      body: body
    }

    commits = [
      %{author_email: user_email, author_name: "A"},
      %{author_email: "ab@ab", author_name: "A"},
      %{author_email: user_email, author_name: "A"},
      %{author_email: "a@a", author_name: "A A"},
      %{author_email: "e@e", author_name: "E"},
      %{author_email: user_email, author_name: "A"}
    ]

    actual_message =
      Message.generate_squash_commit_message(
        pr,
        commits,
        user_email,
        user_name,
        "\n\n<!-- boilerplate follows -->"
      )

    assert expected_message == actual_message
  end
end
