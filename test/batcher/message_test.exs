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

  test "generate bundle messages" do
    assert Message.generate_message({:linked, [1, 2]}) =~ "linked bundle: #1, #2"
    assert Message.generate_message(:unlinked) =~ "no longer linked"
    stacked = Message.generate_message({:stacked, 2, 1, "https://github.com/o/r/compare/a...b"})
    assert stacked =~ "#2 is now stacked on #1"
    assert stacked =~ "[#2's own changes](https://github.com/o/r/compare/a...b)"
    assert Message.generate_message({:link_error, {:not_rebased, 5}}) =~ "Rebase it onto #5"

    assert Message.generate_message({:link_error, {:stack_reversed, 5, 2}}) =~
             "Comment `bors stack #2` on #5 instead"

    assert Message.generate_message({:link_error, {:malformed_refs, :link, ["#2x"]}}) =~
             "Could not read `#2x` in `bors link`"

    assert Message.generate_message({:link_error, :unlink_args}) =~
             "takes nothing after it"

    assert Message.generate_message({:unlinked, :fresh_approval_needed}) =~
             "no longer linked. The approval it held"

    assert Message.generate_message(:try_ignores_bundle) =~
             "without the rest of its bundle"

    assert Message.generate_message({:bundle_last_unapproved, :awaiting_review}) =~
             "once this pull request gets `bors r+`"

    assert Message.generate_message({:bundle_last_unapproved, :draft}) =~
             "leaves draft"

    assert Message.generate_message({:bundle_last_unapproved, :closed}) =~
             "Reopen it"

    assert Message.generate_message({:stack_stale, 2, 1}) =~ "#2 contains the current head of #1"
    assert Message.generate_message({:retargeted, "master"}) =~ "base branch to `master`"

    assert Message.generate_message({:stack_retarget_failed, 7}) =~
             "could not change the base branch of #7"

    assert Message.generate_message({:base_restored, "feature-a"}) =~
             "restored this pull request's base branch to `feature-a`"

    assert Message.generate_message({:base_restore_failed, "feature-a"}) =~
             "could not restore this pull request's base branch to `feature-a`"

    assert Message.generate_message({:bundle_waiting, [7]}) =~
             "Waiting for approval (`bors r+`) of: #7"

    assert Message.generate_message({:bundle_held, 7}) =~
             "Waiting on #7 before the bundle can queue"

    assert Message.generate_message({:bundle_pulled, 7, :closed}) =~ "#7, which was closed"
    assert Message.generate_message({:bundle_pulled, 7, :push}) =~ "#7, which was pushed to"

    assert Message.generate_message({:bundle_pulled, 7, :draft}) =~
             "#7, which was converted to draft"

    assert Message.generate_message({:bundle_pulled, 7, :requested}) =~ "#7, which was canceled"

    bundle_failed =
      Message.generate_message({:bundle_failed, [3, 7], [%{url: nil, identifier: "ci"}]})

    assert bundle_failed =~ "Build failed:"
    assert bundle_failed =~ "* ci"
    assert bundle_failed =~ "(#3, #7)"
    assert bundle_failed =~ "left the queue"
    assert bundle_failed =~ "run `bors r+` on each member"

    bundle_conflict = Message.generate_message({:bundle_conflict, [3, 7]})

    assert bundle_conflict =~ "Merge conflict."
    assert bundle_conflict =~ "(#3, #7)"
    assert bundle_conflict =~ "conflict with each other"
    assert bundle_conflict =~ "bors unlink"
    assert bundle_conflict =~ "run `bors r+` on each member"

    for reason <- [
          :nothing_to_link,
          :not_found,
          :closed,
          :branch_mismatch,
          :in_batch,
          :stack_usage,
          :self_stack,
          :cycle,
          :cannot_infer
        ] do
      message = Message.generate_message({:link_error, reason})
      assert is_binary(message)
      assert message =~ ":-1:"
    end
  end

  test "bundle-status messages link to the bundle page; others do not" do
    for message <- [
          {:linked, [1, 2]},
          {:stacked, 2, 1, "https://github.com/o/r/compare/a...b"},
          {:bundle_waiting, [7]},
          {:bundle_held, 7},
          {:bundle_last_unapproved, :awaiting_review},
          {:bundle_pulled, 7, :closed},
          {:bundle_failed, [3, 7], []},
          {:bundle_conflict, [3, 7]},
          {:bundle_timeout, [3, 7]},
          {:stack_stale, 2, 1},
          {:stack_retarget_failed, 7},
          {:retargeted, "master"},
          :try_ignores_bundle
        ] do
      assert Message.links_to_bundle?(message), "expected #{inspect(message)} to link"
    end

    for message <- [
          :unlinked,
          {:unlinked, :fresh_approval_needed},
          {:link_error, :closed},
          {:base_restored, "feature-a"},
          {:base_restore_failed, "feature-a"},
          {:preflight, :ok},
          {:canceled, :failed, :push}
        ] do
      refute Message.links_to_bundle?(message), "expected #{inspect(message)} not to link"
    end
  end

  test "bundle link footer" do
    assert Message.bundle_link_footer(nil) == ""

    assert Message.bundle_link_footer("http://localhost/bundles/42") ==
             "\n\n[View this bundle in bors](http://localhost/bundles/42) (sign in with GitHub to view)."
  end

  test "generate_message/2 appends the footer only to bundle-page messages" do
    url = "http://localhost/bundles/42"
    footer = Message.bundle_link_footer(url)

    assert Message.generate_message({:linked, [1, 2]}, url) ==
             Message.generate_message({:linked, [1, 2]}) <> footer

    assert Message.generate_message(:try_ignores_bundle, url) ==
             Message.generate_message(:try_ignores_bundle) <> footer

    # Non-bundle messages pass through unchanged, even with a url.
    assert Message.generate_message(:unlinked, url) == Message.generate_message(:unlinked)

    # A nil url appends nothing.
    assert Message.generate_message({:linked, [1, 2]}, nil) ==
             Message.generate_message({:linked, [1, 2]})
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

  test "the draft refusal says so when an allowed command was dropped with it" do
    msg = Message.generate_message({:draft_refused, [:activate], [{:try, ""}]})

    assert msg =~ "`bors r+`"
    assert msg =~ "`bors try` did not run either"
    assert msg =~ "stops the whole comment"
  end

  test "the draft refusal stays quiet about dropped commands when there were none" do
    refute Message.generate_message({:draft_refused, [:activate], []}) =~ "did not run either"
  end

  test "generate draft refusal message" do
    msg = Message.generate_message({:draft_refused, [:activate], []})

    assert msg =~ "is a draft"
    assert msg =~ "`bors r+`"
    assert msg =~ "Mark it ready for review"
  end

  test "the draft refusal names each blocked command the way it was typed" do
    msg =
      Message.generate_message(
        {:draft_refused, [{:set_priority, 10}, {:activate_by, "alice"}, {:delegate_to, "bob"}],
         []}
      )

    assert msg =~ "`bors p=10`"
    assert msg =~ "`bors r=alice`"
    assert msg =~ "`bors delegate=bob`"
  end

  test "the draft refusal names a repeated command once" do
    msg = Message.generate_message({:draft_refused, [:activate, :activate], []})

    assert ["`bors r+`"] == Regex.scan(~r/`bors r\+`/, msg) |> Enum.map(&hd/1)
  end

  # Every unrecognized command is blocked, so one added later reaches the
  # message with no name clause of its own. It must not raise.
  test "the draft refusal names an unrecognized command instead of raising" do
    assert Message.generate_message({:draft_refused, [{:future_cmd, "x"}], []}) =~
             "`bors future_cmd`"

    assert Message.generate_message({:draft_refused, [:future_cmd], []}) =~ "`bors future_cmd`"
  end

  # bors parses its own comments, so a refusal that parsed as a command would
  # make a draft PR answer itself forever.
  test "the dropped-batch notice cannot be parsed as a bors command" do
    msg = Message.generate_message(:draft_dropped_from_batch)

    assert msg =~ "left the queue without merging because it is a draft"
    assert [] == BorsNG.Command.parse(msg)
  end

  test "the dropped-before-batch notice cannot be parsed as a bors command" do
    msg = Message.generate_message(:draft_dropped_before_batch)

    assert msg =~ "left the queue without building because it is a draft"
    assert [] == BorsNG.Command.parse(msg)
  end

  test "the draft refusal cannot be parsed as a bors command" do
    for cmds <- [
          [:activate],
          [{:activate_by, "alice"}, {:set_priority, 10}],
          [:retry],
          [{:link, [2]}],
          [{:delegate_to, "bob"}]
        ] do
      assert [] == BorsNG.Command.parse(Message.generate_message({:draft_refused, cmds, []}))
    end
  end

  # The "did not run either" list is the one the reader is told to run again,
  # so every name in it has to be text bors can parse. These five tags do not
  # spell their own command, and all five are commands `draft_blocked?/1`
  # allows on a draft, so `also_dropped` is exactly where they turn up.
  test "the draft refusal names dropped commands the way they are typed" do
    for {cmd, typed, parses_to} <- [
          {:deactivate, "r-", :deactivate},
          {:try_cancel, "try-", :try_cancel},
          {:undelegate, "delegate-", :undelegate},
          {{:undelegate_to, "bob"}, "delegate-=bob", {:undelegate_to, "bob"}},
          # Refused for its arguments. Named as typed, so running it again
          # gets the hint instead of removing every delegation.
          {{:malformed_args, {:undelegate, "d- bob", ["bob"]}}, "d- bob",
           {:malformed_args, {:undelegate, "d- bob", ["bob"]}}},
          # `unlink #3` is refused *because* of the arguments, so the text to
          # run again is bare `unlink`, which parses back to `:unlink`.
          {:unlink_with_args, "unlink", :unlink}
        ] do
      msg = Message.generate_message({:draft_refused, [:activate], [cmd]})

      assert msg =~ "`bors #{typed}` did not run either",
             "#{inspect(cmd)} should be named `bors #{typed}`, got: #{msg}"

      # Whatever name it hands back has to be text the parser accepts, or the
      # "run the command again" instruction sends the author in a circle.
      assert [parses_to] == BorsNG.Command.parse("bors #{typed}")
    end
  end

  # `:autocorrect` is bors guessing at a typo and `:bros` is the alternate
  # trigger, so neither is a command anyone can re-run by name. Naming the
  # autocorrect would print its suggestion — for `bors +r` that is the very
  # `bors r+` the sentence before it just refused.
  test "the draft refusal leaves pseudo-commands out of the dropped list" do
    for cmd <- [{:autocorrect, "r+"}, :bros] do
      msg = Message.generate_message({:draft_refused, [:activate], [cmd]})

      refute msg =~ "did not run either"
      refute msg =~ "`bors autocorrect`"
      refute msg =~ "`bors bros`"
    end
  end

  test "the delegate- refusal suggests delegate-= with the names" do
    msg =
      Message.generate_message(
        {:malformed_args, {:undelegate, "d- alice, bob", ["alice", "bob"]}}
      )

    assert msg =~ "`bors d-=alice,bob`"
    assert msg =~ "just `bors d-`"

    msg = Message.generate_message({:malformed_args, {:undelegate, "delegate- alice", ["alice"]}})

    assert msg =~ "`bors delegate-=alice`"
    assert msg =~ "just `bors delegate-`"
  end

  test "the delegate- refusal without names gives an example" do
    msg = Message.generate_message({:malformed_args, {:undelegate, "d- for=24h", []}})

    assert msg =~ "`bors d-=alice,bob`"
    refute msg =~ "d-=for=24h"
  end

  test "the delegation refusals name each login" do
    assert Message.generate_message({:delegation_refused, :unknown_users, ["alcie"]}) =~
             "no GitHub user named `alcie`"

    assert Message.generate_message({:delegation_refused, :unknown_users, ["alcie", "bbo"]}) =~
             "no GitHub users named `alcie`, `bbo`"

    assert Message.generate_message({:delegation_refused, :lookup_failed, ["alice"]}) =~
             "could not look up `alice`"
  end

  test "the delegation refusals cannot be parsed as a bors command" do
    for msg <- [
          {:malformed_args, {:undelegate, "d- alice", ["alice"]}},
          {:malformed_args, {:undelegate, "d-!", []}},
          {:malformed_args, {:delegate, "d+ alice for=24h", ["alice"], ["for=24h"]}},
          {:malformed_args, {:delegate, "d+ p=5", [], []}},
          {:malformed_args, {:priority_range, "p=99999999999"}},
          {:delegation_refused, :unknown_users, ["alcie"]},
          {:delegation_refused, :lookup_failed, ["alice"]}
        ] do
      assert [] == BorsNG.Command.parse(Message.generate_message(msg))
    end
  end

  test "the delegate+ refusal suggests delegate= and keeps the for=" do
    msg =
      Message.generate_message(
        {:malformed_args, {:delegate, "d+ alice, bob for=24h", ["alice", "bob"], ["for=24h"]}}
      )

    assert msg =~ "`bors d=alice,bob for=24h`"
    assert msg =~ "just `bors d+ for=24h`"

    msg =
      Message.generate_message({:malformed_args, {:delegate, "delegate+ alice", ["alice"], []}})

    assert msg =~ "`bors delegate=alice`"
    assert msg =~ "just `bors delegate+`"
  end

  test "the delegate+ refusal names bare delegate and d as typed" do
    msg =
      Message.generate_message({:malformed_args, {:delegate, "delegate alice", ["alice"], []}})

    assert msg =~ "`bors delegate` delegates the PR author"
    assert msg =~ "`bors delegate=alice`"
    assert msg =~ "just `bors delegate`."

    msg = Message.generate_message({:malformed_args, {:delegate, "d alice", ["alice"], []}})

    assert msg =~ "`bors d` delegates the PR author"
    assert msg =~ "`bors d=alice`"
  end

  test "the empty = hints say what each form needs" do
    msg = Message.generate_message({:malformed_args, {:no_names, "r="}})
    assert msg =~ "`bors r=alice`"
    assert msg =~ "`bors r+`"

    msg = Message.generate_message({:malformed_args, {:no_names, "merge="}})
    assert msg =~ "`bors merge=alice`"
    assert msg =~ "`bors merge`"

    msg = Message.generate_message({:malformed_args, {:no_names, "delegate+="}})
    assert msg =~ "`bors delegate+=alice,bob`"
    assert msg =~ "`bors delegate+`"

    msg = Message.generate_message({:malformed_args, {:no_names, "d-="}})
    assert msg =~ "`bors d-=alice`"
    assert msg =~ "`bors d-`"
  end

  test "the empty = hints cannot be parsed as a bors command" do
    for typed <- ~w(r= merge= d= d+= delegate= delegate+= d-= delegate-=) do
      assert [] ==
               BorsNG.Command.parse(
                 Message.generate_message({:malformed_args, {:no_names, typed}})
               )
    end
  end

  test "the draft refusal names an empty = form the way it was typed" do
    msg = Message.generate_message({:draft_refused, [{:malformed_args, {:no_names, "r="}}], []})

    assert msg =~ "`bors r=`"
  end

  test "the leftover hint says what was run, what was not, and what to do" do
    msg = Message.generate_message({:malformed_args, {:leftover, "r- now", "r-", "now"}})

    assert msg =~ "bors did not run `bors r- now`"
    assert msg =~ "`bors r-` takes nothing after it, but `now` followed"
    assert msg =~ "Reply with just `bors r-`"
    refute msg =~ "commas"
  end

  # `r=alice bob` most likely meant two reviewers.
  test "the leftover hint after names points at commas" do
    msg =
      Message.generate_message({:malformed_args, {:leftover, "r=alice bob", "r=alice", "bob"}})

    assert msg =~ "`bors r=alice,bob`"

    msg =
      Message.generate_message(
        {:malformed_args, {:leftover, "merge=alice bob", "merge=alice", "bob"}}
      )

    assert msg =~ "`bors merge=alice,bob`"

    # The example keeps what followed the names.
    msg =
      Message.generate_message(
        {:malformed_args, {:leftover, "d=alice for=24h bob", "d=alice for=24h", "bob"}}
      )

    assert msg =~ "`bors d=alice,bob for=24h`"

    # Only a leftover that could be a name gets the hint.
    msg = Message.generate_message({:malformed_args, {:leftover, "r=alice !", "r=alice", "!"}})
    refute msg =~ "commas"

    msg = Message.generate_message({:malformed_args, {:leftover, "r- now", "r-", "now"}})
    refute msg =~ "commas"
  end

  test "the bad-name hint for a for= among the names says where it goes" do
    msg =
      Message.generate_message({:malformed_args, {:bad_names, "d=for=24h alice", ["for=24h"]}})

    assert msg =~ "Put `for=` after the names, e.g. `bors d=alice,bob for=24h`."
  end

  test "the bad-name hint names each token" do
    assert Message.generate_message({:malformed_args, {:bad_names, "d=alice p=5", ["p=5"]}}) =~
             "`p=5` cannot be a GitHub username."

    assert Message.generate_message({:malformed_args, {:bad_names, "d=p=5 r+", ["p=5", "r+"]}}) =~
             "`p=5`, `r+` cannot be GitHub usernames."
  end

  test "the leftover and bad-name hints cannot be parsed as a bors command" do
    for msg <- [
          {:malformed_args, {:leftover, "r- now", "r-", "now"}},
          {:malformed_args, {:leftover, "r=alice bob", "r=alice", "bob"}},
          {:malformed_args, {:bad_names, "d=alice p=5", ["p=5"]}}
        ] do
      assert [] == BorsNG.Command.parse(Message.generate_message(msg))
    end
  end

  test "the draft refusal names a leftover the way it was typed" do
    msg =
      Message.generate_message(
        {:draft_refused, [{:malformed_args, {:leftover, "r+ now", "r+", "now"}}], []}
      )

    assert msg =~ "`bors r+ now`"
  end

  test "the for= hints name the token and give the range" do
    msg = Message.generate_message({:malformed_args, {:bad_for, "d+ for=24m", ["for=24m"]}})

    assert msg =~ "bors did not run `bors d+ for=24m`"
    assert msg =~ "it cannot read `for=24m`"
    assert msg =~ "up to `for=90d`"

    assert Message.generate_message({:malformed_args, {:repeated_for, "d+ for=1h for=2h"}}) =~
             "more than one `for=`"
  end

  test "the for= hints cannot be parsed as a bors command" do
    for msg <- [
          {:malformed_args, {:bad_for, "d+ for=24m", ["for=24m"]}},
          {:malformed_args, {:repeated_for, "d+ for=1h for=2h"}}
        ] do
      assert [] == BorsNG.Command.parse(Message.generate_message(msg))
    end
  end

  test "the delegate+ refusal without names gives an example" do
    msg = Message.generate_message({:malformed_args, {:delegate, "d+ p=5", [], []}})

    assert msg =~ "`bors d=alice,bob`"
    refute msg =~ "d=p=5"
  end

  test "the priority range hint gives the range" do
    assert Message.generate_message({:malformed_args, {:priority_range, "p=99999999999"}}) =~
             "from -2147483648 to 2147483647"
  end

  # Unlike `d-`, `d+` is blocked on a draft, so its refusal lands in the
  # blocked list. Named as typed, so running it again gets the hint.
  test "the draft refusal names a refused delegate+ and p= the way they were typed" do
    msg =
      Message.generate_message(
        {:draft_refused,
         [
           {:malformed_args, {:delegate, "d+ bob", ["bob"], []}},
           {:malformed_args, {:priority_range, "p=99999999999"}}
         ], []}
      )

    assert msg =~ "`bors d+ bob`"
    assert msg =~ "`bors p=99999999999`"
  end

  test "a pseudo-command does not hide a real dropped command beside it" do
    msg =
      Message.generate_message({:draft_refused, [:activate], [{:autocorrect, "r+"}, :deactivate]})

    assert msg =~ "`bors r-` did not run either"
  end
end
