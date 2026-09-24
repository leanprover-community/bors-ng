defmodule BorsNG.CommandTest do
  use ExUnit.Case
  use ExUnit.Parameterized

  alias BorsNG.Command
  alias BorsNG.Database.Context.Logging
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.GitHub

  doctest BorsNG.Command

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    inst =
      %Installation{installation_xref: 91}
      |> Repo.insert!()

    proj =
      %Project{
        installation_id: inst.id,
        repo_xref: 14,
        staging_branch: "staging"
      }
      |> Repo.insert!()

    {:ok, inst: inst, proj: proj}
  end

  # bors.toml fixture with a delegation default. Tests that exercise the
  # no-`for=` path inject this into the ServerMock's `files` map so the
  # delegate command can read the default from the PR's base branch.
  defp delegation_toml(seconds \\ 24 * 60 * 60) do
    ~s(status = ["ci"]\n[delegation]\ndefault_expiry_sec = #{seconds}\n)
  end

  test "reject the empty string" do
    assert [] == Command.parse("")
    assert [] == Command.parse(nil)
  end

  test "reject strings without the phrase" do
    assert [] == Command.parse("doink!")
  end

  test "reject a string that merely starts out like a command" do
    assert [] == Command.parse("bors doink")
  end

  test "a command word running on into a longer word is not a command" do
    for comment <- [
          "bors merged this yesterday",
          "bors mergeable?",
          "bors merge-conflicts are fixed now",
          "bors cancelled it",
          "bors retrying now",
          "bors trying again",
          "bors tryout",
          "bors linked #12 already",
          "bors link-rot",
          "bors unlinked them",
          "bors stacked on #5",
          "bors pinged me",
          "bors single-handedly",
          "bors singles",
          "bros merged"
        ] do
      assert [] == Command.parse(comment), comment
    end
  end

  test "a command typed in the wrong case gets a correction" do
    assert [{:autocorrect, "r+"}] == Command.parse("bors R+")
    assert [{:autocorrect, "merge"}] == Command.parse("bors MERGE")
    assert [{:autocorrect, "p=5"}] == Command.parse("bors P=5")
    assert [{:autocorrect, "d+"}] == Command.parse("bors D+")
    assert [{:autocorrect, "link #2"}] == Command.parse("bors Link #2")
    # Only the command word changes case: `try` passes its argument as typed.
    assert [{:autocorrect, "r=Alice"}] == Command.parse("bors R=Alice")
    assert [{:autocorrect, "try --Layout"}] == Command.parse("bors TRY --Layout")
  end

  test "a command with a space before its + - or = gets a correction" do
    assert [{:autocorrect, "r+"}] == Command.parse("bors r +")
    assert [{:autocorrect, "p=5"}] == Command.parse("bors p = 5")
    assert [{:autocorrect, "r=alice"}] == Command.parse("bors r = alice")
    # Bare `d` would otherwise answer these with its own refusal.
    assert [{:autocorrect, "d+"}] == Command.parse("bors d +")
    assert [{:autocorrect, "d=alice"}] == Command.parse("bors d =alice")
    # `try -` builds `-`, so `Try -` is corrected to that, not to `try-`.
    assert [{:autocorrect, "try -"}] == Command.parse("bors Try -")
    assert [{:try, " -"}] == Command.parse("bors try -")
  end

  test "a command with no space after the colon gets a correction" do
    assert [{:autocorrect, "r+"}] == Command.parse("bors:r+")
    assert [{:autocorrect, "merge"}] == Command.parse("bors:Merge")
    assert [:activate] == Command.parse("bors: r+")
    assert [] == Command.parse("bors:doink")
    assert [] == Command.parse("bors:")
  end

  test "a correction is only offered for something bors would run" do
    assert [] == Command.parse("bors Doink")
    assert [] == Command.parse("bors Merged this")
    # Already a hint, and correcting the case would not change it.
    assert [{:malformed_args, :single}] == Command.parse("bors single On")

    assert [{:malformed_args, {:delegate, "d alice", ["alice"], []}}] ==
             Command.parse("bors d alice")

    # The existing `+r` corrections are unchanged.
    assert [{:autocorrect, "r+"}] == Command.parse("bors +r")
    assert [{:autocorrect, "r-"}] == Command.parse("bors -")
  end

  test "a miscased command among link arguments is refused like the command" do
    assert [{:link_malformed, :link, ["R+"]}] == Command.parse("bors link #1 R+")
  end

  # Punctuation is not part of the word, so `merge!` is not prose. It is
  # still something after the command, so it is refused, not ignored.
  test "punctuation after a command word is left over, not part of the word" do
    assert [{:malformed_args, {:leftover, "merge!", "merge", "!"}}] ==
             Command.parse("bors merge!")

    assert [{:malformed_args, {:leftover, "merge, please", "merge", ", please"}}] ==
             Command.parse("bors merge, please")

    assert [{:malformed_args, {:leftover, "ping?", "ping", "?"}}] == Command.parse("bors ping?")
    assert [:deactivate] == Command.parse("bors merge-")
    assert [:unlink] == Command.parse("bors link-")
    assert [{:link, [12]}] == Command.parse("bors link#12")
    assert [{:malformed_args, :single}] == Command.parse("bors single")
  end

  test "a command that takes nothing refuses whatever follows it" do
    for {comment, understood, rest} <- [
          {"bors r+ now", "r+", "now"},
          {"bors r+ thanks!", "r+", "thanks!"},
          {"bors r+!", "r+", "!"},
          {"bors merge queue is slow", "merge", "queue is slow"},
          {"bors r- now", "r-", "now"},
          {"bors merge- x", "merge-", "x"},
          {"bors cancel!", "cancel", "!"},
          {"bors try- now", "try-", "now"},
          {"bors retry (flaky)", "retry", "(flaky)"},
          # Only one space may separate `r+` from its modifier.
          {"bors r+  p=5", "r+", "p=5"}
        ] do
      "bors " <> typed = comment

      assert [{:malformed_args, {:leftover, typed, understood, rest}}] == Command.parse(comment),
             comment
    end
  end

  test "a command with an argument refuses whatever follows the argument" do
    for {comment, understood, rest} <- [
          {"bors p=5 r+", "p=5", "r+"},
          {"bors single on p=5", "single on", "p=5"},
          {"bors r+ single on p=5", "r+ single on", "p=5"},
          {"bors r+ p=5 single on", "r+ p=5", "single on"},
          {"bors merge p=5 now", "merge p=5", "now"},
          {"bors r=alice bob", "r=alice", "bob"},
          {"bors r=alice single on", "r=alice", "single on"},
          {"bors r=alice p=5 now", "r=alice p=5", "now"},
          {"bors merge=alice bob", "merge=alice", "bob"}
        ] do
      "bors " <> typed = comment

      assert [{:malformed_args, {:leftover, typed, understood, rest}}] == Command.parse(comment),
             comment
    end

    # A glued word is not an `on`.
    assert [{:malformed_args, :single}] == Command.parse("bors single onion")
  end

  test "merge takes the single modifier, as r+ does" do
    assert [{:set_is_single, true}, :activate] == Command.parse("bors merge single on")
    assert [{:set_is_single, false}, :activate] == Command.parse("bors merge single off")
  end

  test "try arguments are free text, so nothing after try is left over" do
    assert [{:try, " again later"}] == Command.parse("bors try again later")
  end

  test "a name that cannot be a GitHub login is refused before any lookup" do
    assert [{:malformed_args, {:bad_names, "r= p=5", ["p=5"]}}] == Command.parse("bors r= p=5")
    assert [{:malformed_args, {:bad_names, "r=a.b", ["a.b"]}}] == Command.parse("bors r=a.b")

    assert [{:malformed_args, {:bad_names, "d=alice p=5", ["p=5"]}}] ==
             Command.parse("bors d=alice p=5")

    assert [{:malformed_args, {:bad_names, "d=alice r+", ["r+"]}}] ==
             Command.parse("bors d=alice r+")

    assert [{:malformed_args, {:bad_names, "d-=alice for=24h", ["for=24h"]}}] ==
             Command.parse("bors d-=alice for=24h")

    assert :member ==
             Command.required_permission_level([
               {:malformed_args, {:bad_names, "d=alice p=5", ["p=5"]}}
             ])
  end

  test "delegate-= takes names separated by spaces, as delegate= does" do
    assert [{:undelegate_to, "alice"}, {:undelegate_to, "bob"}] ==
             Command.parse("bors d-=alice bob")

    assert [{:delegate_to, "alice"}, {:delegate_to, "bob"}] == Command.parse("bors d=alice bob")
  end

  test "unlink refuses anything after it" do
    assert [:unlink_with_args] == Command.parse("bors unlink now")
    assert [:unlink_with_args] == Command.parse("bors link- x")
  end

  test "a correction that is itself left over gets the leftover hint" do
    assert [{:malformed_args, {:leftover, "r+ now", "r+", "now"}}] ==
             Command.parse("bors R+ now")

    assert [{:malformed_args, {:leftover, "r+ now", "r+", "now"}}] ==
             Command.parse("bors:r+ now")
  end

  # The hint is gated like other hints, except that `ping` needs nothing.
  test "a leftover is member-gated unless its command needs no permission" do
    [ping_now] = Command.parse("bors ping now")
    [r_plus_now] = Command.parse("bors r+ now")

    assert :none == Command.required_permission_level([ping_now])
    assert :member == Command.required_permission_level([r_plus_now])
  end

  # The link-argument check asks the parser, so a word that is no longer a
  # command is tolerated like any other connective word.
  test "a run-on command word among link arguments is just a word" do
    assert [{:link, [1]}] == Command.parse("bors link #1 merged")
    assert [{:link_malformed, :link, ["merge"]}] == Command.parse("bors link #1 merge")
  end

  test "accept the bare command" do
    assert [{:try, ""}] == Command.parse("bors try")
    assert [:activate] == Command.parse("bors r+")
    assert [:activate] == Command.parse("bors merge")
    assert [:deactivate] == Command.parse("bors r-")
    assert [:deactivate] == Command.parse("bors merge-")
    assert [:deactivate] == Command.parse("bors cancel")
  end

  test "accept the case insensitive bare command" do
    assert [{:try, ""}] == Command.parse("Bors try")
    assert [:activate] == Command.parse("Bors r+")
    assert [:activate] == Command.parse("Bors merge")
    assert [:deactivate] == Command.parse("Bors r-")
    assert [:deactivate] == Command.parse("Bors merge-")
    assert [:deactivate] == Command.parse("Bors cancel")
  end

  test "accept the link command" do
    assert [{:link, [23, 55]}] == Command.parse("bors link #23 #55")
    assert [{:link, [23, 55]}] == Command.parse("bors link= #23, 55")
    assert [{:link, [23]}] == Command.parse("bors link 23")
    assert [{:link, []}] == Command.parse("bors link")
    assert [{:link, []}] == Command.parse("bors link nonsense")
  end

  test "accept the stack command" do
    assert [{:stack, [23]}] == Command.parse("bors stack #23")
    assert [{:stack, [23]}] == Command.parse("bors stack= 23")
    assert [{:stack, [23]}] == Command.parse("bors stack on #23")
    assert [{:stack, []}] == Command.parse("bors stack")
  end

  test "refuse references that cannot be read instead of dropping them" do
    assert [{:link_malformed, :link, ["#23abc"]}] == Command.parse("bors link #23abc #55")
    assert [{:link_malformed, :stack, ["23."]}] == Command.parse("bors stack 23.")
    assert [{:link_malformed, :link, ["r+"]}] == Command.parse("bors link #23 r+")
  end

  test "refuse references too large for a pull request number" do
    # pr_xref is a 32-bit column; parsing a bigger number would crash the
    # patch lookup inside the batcher.
    assert [{:link_malformed, :link, ["#99999999999"]}] ==
             Command.parse("bors link #99999999999")

    assert [{:link_malformed, :stack, ["2147483648"]}] ==
             Command.parse("bors stack 2147483648")

    assert [{:link, [2_147_483_647]}] == Command.parse("bors link #2147483647")
  end

  test "refuse other commands' arguments instead of reading numbers out of them" do
    assert [{:link_malformed, :link, ["p=5"]}] == Command.parse("bors link #23 p=5")
    assert [{:link_malformed, :stack, ["r=me"]}] == Command.parse("bors stack #2 r=me")
    assert [{:link_malformed, :link, ["single"]}] == Command.parse("bors link #23 single on")
    assert [{:link_malformed, :link, ["stack"]}] == Command.parse("bors link #1 stack #2")
  end

  test "refuse the short delegate forms and other key=value tokens too" do
    assert [{:link_malformed, :link, ["d=alice"]}] == Command.parse("bors link #1 d=alice")
    assert [{:link_malformed, :link, ["d+"]}] == Command.parse("bors link #1 d+")
    assert [{:link_malformed, :stack, ["d-"]}] == Command.parse("bors stack #1 d-")
    assert [{:link_malformed, :link, ["for=2w"]}] == Command.parse("bors link #1 for=2w")
    assert [{:link_malformed, :link, ["delegate"]}] == Command.parse("bors link #1 delegate")
  end

  test "accept the unlink command" do
    assert [:unlink] == Command.parse("bors unlink")
    assert [:unlink] == Command.parse("bors link-")
  end

  test "unlink with pull request numbers is refused, not partially obeyed" do
    assert [:unlink_with_args] == Command.parse("bors unlink #23")
    assert [:unlink_with_args] == Command.parse("bors link- 23")
  end

  test "link commands require project membership, not delegation" do
    assert :project_member == Command.required_permission_level([{:link, [1]}])
    assert :project_member == Command.required_permission_level([{:stack, [1]}])
    assert :project_member == Command.required_permission_level([:unlink])

    assert :project_member ==
             Command.required_permission_level([{:link_malformed, :link, ["x"]}])

    assert :project_member == Command.required_permission_level([:unlink_with_args])

    # Combined with a reviewer-level command, both requirements must hold.
    assert :project_reviewer == Command.required_permission_level([{:link, [1]}, :activate])
    assert :project_reviewer == Command.required_permission_level([:activate, :unlink])
    assert :project_member == Command.required_permission_level([{:link, [1]}, {:try, ""}])
  end

  test "accept single patch" do
    assert [{:set_is_single, true}, :activate] == Command.parse("bors r+ single on")
    assert [{:set_is_single, false}, :activate] == Command.parse("bors r+ single off")
    assert [{:set_is_single, true}] == Command.parse("bors single on")
    assert [{:set_is_single, false}] == Command.parse("bors single off")
  end

  test "do not parse single patch after try command" do
    assert [{:try, " single on"}] == Command.parse("bors try single on")
    assert [{:try, " single screwy"}] == Command.parse("bors try single screwy")
  end

  test "malformed priority and single arguments parse to a hint, not a crash" do
    assert [{:malformed_args, :priority}] == Command.parse("bors p=abc")
    assert [{:malformed_args, :priority}] == Command.parse("bors p=")
    assert [{:malformed_args, :single}] == Command.parse("bors single")
    assert [{:malformed_args, :single}] == Command.parse("bors single maybe")
  end

  test "a malformed modifier swallows its activation instead of dropping the modifier" do
    assert [{:malformed_args, :priority}] == Command.parse("bors r+ p=abc")
    assert [{:malformed_args, :priority}] == Command.parse("bors merge p=abc")
    assert [{:malformed_args, :priority}] == Command.parse("bors r=me p=abc")
    assert [{:malformed_args, :single}] == Command.parse("bors r+ single maybe")
  end

  test "the malformed-argument hint is member-gated, below the delegation merge gate" do
    assert :member == Command.required_permission_level([{:malformed_args, :priority}])
    assert :member == Command.required_permission_level([{:malformed_args, :single}])

    assert :member ==
             Command.required_permission_level([
               {:malformed_args, {:undelegate, "d- alice", ["alice"]}}
             ])
  end

  test "a priority outside the 32-bit column is refused with its own hint" do
    assert [{:set_priority, 2_147_483_647}] == Command.parse("bors p=2147483647")
    assert [{:set_priority, -2_147_483_648}] == Command.parse("bors p=-2147483648")
    assert [{:malformed_args, :priority_range}] == Command.parse("bors p=2147483648")
    assert [{:malformed_args, :priority_range}] == Command.parse("bors p=-2147483649")
    assert [{:malformed_args, :priority_range}] == Command.parse("bors p=99999999999")
    # A modifier that cannot be applied swallows its activation.
    assert [{:malformed_args, :priority_range}] == Command.parse("bors r+ p=99999999999")
    assert [{:malformed_args, :priority_range}] == Command.parse("bors merge p=99999999999")
    assert [{:malformed_args, :priority_range}] == Command.parse("bors r=me p=99999999999")
    assert :member == Command.required_permission_level([{:malformed_args, :priority_range}])
  end

  test "a priority with letters stuck to it is refused, not truncated" do
    assert [{:malformed_args, :priority}] == Command.parse("bors p=5abc")
    assert [{:malformed_args, :priority}] == Command.parse("bors p=5.5")
    assert [{:malformed_args, :priority}] == Command.parse("bors r+ p=5abc")
    assert [{:malformed_args, :priority}] == Command.parse("bors r=me p=5abc")
  end

  test "delegate+ with names is refused, not taken as delegating the author" do
    assert [{:malformed_args, {:delegate, "d+ alice", ["alice"], []}}] ==
             Command.parse("bors d+ alice")

    assert [
             {:malformed_args,
              {:delegate, "delegate+ @alice, @bob for=24h", ["alice", "bob"], ["for=24h"]}}
           ] == Command.parse("bors delegate+ @alice, @bob for=24h")

    assert [{:malformed_args, {:delegate, "d+ p=5", [], []}}] == Command.parse("bors d+ p=5")

    assert :member ==
             Command.required_permission_level([
               {:malformed_args, {:delegate, "d+ alice", ["alice"], []}}
             ])
  end

  test "bare delegate and d are delegate+" do
    assert [:delegate] == Command.parse("bors delegate")
    assert [:delegate] == Command.parse("bors d")
    assert [{:delegate, 86_400}] == Command.parse("bors delegate for=24h")
    assert [{:delegate, 1_209_600}] == Command.parse("bors d for=2w")
  end

  test "bare delegate with names is refused like delegate+ with names" do
    assert [{:malformed_args, {:delegate, "delegate alice", ["alice"], []}}] ==
             Command.parse("bors delegate alice")

    assert [{:malformed_args, {:delegate, "d alice", ["alice"], []}}] ==
             Command.parse("bors d alice")

    # The `to` of the natural sentence is not suggested as a login.
    assert [{:malformed_args, {:delegate, "delegate to alice", ["alice"], []}}] ==
             Command.parse("bors delegate to alice")
  end

  # `d` alone would otherwise read `bors does` as a command.
  test "bare delegate and d only end at a space or the end of the line" do
    for comment <- [
          "bors delegated this",
          "bors delegates",
          "bors delegation is on",
          "bors does this work",
          "bors d'oh",
          "bors d."
        ] do
      assert [] == Command.parse(comment), comment
    end
  end

  test "a = form with no names says what it needs" do
    for typed <- ~w(r= merge= d= d+= delegate= delegate+= d-= delegate-=) do
      assert [{:malformed_args, {:no_names, typed}}] == Command.parse("bors #{typed}"), typed
    end

    # `for=` is not a name.
    assert [{:malformed_args, {:no_names, "d="}}] == Command.parse("bors d= for=24h")

    assert :member ==
             Command.required_permission_level([{:malformed_args, {:no_names, "r="}}])
  end

  test "bare delegate- removes every delegation" do
    assert [:undelegate] == Command.parse("bors d-")
    assert [:undelegate] == Command.parse("bors delegate-")
    assert [:undelegate] == Command.parse("bors d-   ")
  end

  test "delegate- with arguments is refused, not taken as remove-all" do
    assert [{:malformed_args, {:undelegate, "d- alice", ["alice"]}}] ==
             Command.parse("bors d- alice")

    assert [{:malformed_args, {:undelegate, "delegate- @alice, @bob", ["alice", "bob"]}}] ==
             Command.parse("bors delegate- @alice, @bob")

    assert [{:malformed_args, {:undelegate, "d-alice", ["alice"]}}] ==
             Command.parse("bors d-alice")

    assert [{:malformed_args, {:undelegate, "d- dependabot[bot]", ["dependabot[bot]"]}}] ==
             Command.parse("bors d- dependabot[bot]")
  end

  test "delegate- with arguments that cannot be logins offers no names" do
    assert [{:malformed_args, {:undelegate, "d- for=24h", []}}] ==
             Command.parse("bors d- for=24h")

    assert [{:malformed_args, {:undelegate, "d- alice p=5", []}}] ==
             Command.parse("bors d- alice p=5")

    assert [{:malformed_args, {:undelegate, "d-!", []}}] == Command.parse("bors d-!")
  end

  test "accept priority" do
    assert [{:set_priority, 1}, :activate] == Command.parse("bors r+ p=1")
    assert [{:set_priority, 1}, :activate] == Command.parse("bors merge p=1")

    assert [{:set_priority, 1}, {:activate_by, "me"}] ==
             Command.parse("bors r=me p=1")

    assert [{:set_priority, 1}, {:activate_by, "me"}] ==
             Command.parse("bors merge=me p=1")

    assert [{:set_priority, 1}] == Command.parse("bors p=1")
  end

  test "accept priority case insensitive" do
    assert [{:set_priority, 1}, :activate] == Command.parse("Bors r+ p=1")
    assert [{:set_priority, 1}, :activate] == Command.parse("Bors merge p=1")

    assert [{:set_priority, 1}, {:activate_by, "me"}] ==
             Command.parse("Bors r=me p=1")

    assert [{:set_priority, 1}, {:activate_by, "me"}] ==
             Command.parse("Bors merge=me p=1")

    assert [{:set_priority, 1}] == Command.parse("Bors p=1")
  end

  test "accept negative priority" do
    assert [{:set_priority, -1}, :activate] == Command.parse("bors r+ p=-1")
    assert [{:set_priority, -1}, :activate] == Command.parse("bors merge p=-1")

    assert [{:set_priority, -1}, {:activate_by, "me"}] ==
             Command.parse("bors r=me p=-1")

    assert [{:set_priority, -1}, {:activate_by, "me"}] ==
             Command.parse("bors merge=me p=-1")

    assert [{:set_priority, -1}] == Command.parse("bors p=-1")
  end

  test "do not parse priority after try command" do
    assert [{:try, " p=1"}] == Command.parse("bors try p=1")
    assert [{:try, " p=screwy"}] == Command.parse("bors try p=screwy")
  end

  test "accept command with colon after it" do
    assert [{:try, ""}] == Command.parse("bors: try")
    assert [:activate] == Command.parse("bors: r+")
    assert [:activate] == Command.parse("bors: merge")
    assert [:deactivate] == Command.parse("bors: r-")
    assert [:deactivate] == Command.parse("bors: merge-")
    assert [:deactivate] == Command.parse("bors: cancel")
  end

  test "accept the try command with an argument" do
    assert [{:try, " -layout"}] == Command.parse("bors try -layout")
    assert [{:try, " --layout"}] == Command.parse("bors try --layout")
  end

  # Without the space, `try-cancel` would start a build of `-cancel` for
  # someone who meant `try-`.
  test "try arguments need a space after try" do
    assert [] == Command.parse("bors try-layout")
    assert [] == Command.parse("bors try-cancel")
    assert [] == Command.parse("bors try--")
    assert [:try_cancel] == Command.parse("bors try-")
  end

  test "accept more than one command in a single comment" do
    expected_1 = [
      {:try, ""},
      :deactivate
    ]

    command_1 = """
    bors try
    bors r-
    """

    assert expected_1 == Command.parse(command_1)

    expected_2 = [
      {:try, ""},
      :deactivate
    ]

    command_2 = """
    bors try
    bors merge-
    """

    assert expected_2 == Command.parse(command_2)
  end

  test "accept the try command with more argumentation" do
    assert [{:try, " --layout --script"}] ==
             Command.parse("bors try --layout --script")
  end

  test "do not accept the command with a prefix" do
    assert [] == Command.parse("Xbors tryZ")
  end

  test "accept bros with a valid command" do
    assert [:bros] == Command.parse("bros ping")
  end

  test "do not accept any bros without a valid command" do
    assert [] == Command.parse("bros talk")
  end

  test "command permissions" do
    assert :none == Command.required_permission_level([])
    assert :none == Command.required_permission_level([:ping])
    assert :member == Command.required_permission_level([{:try, ""}])
    assert :member == Command.required_permission_level([{:try, ""}, :ping])

    assert :reviewer ==
             Command.required_permission_level([:approve, {:try, ""}])

    assert :reviewer ==
             Command.required_permission_level([{:try, ""}, :approve])
  end

  test "running ping command should post comment", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    c = %Command{
      project: proj,
      commenter: nil,
      comment: "bors ping",
      pr_xref: 1
    }

    Command.run(c, :ping)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{},
               comments: %{1 => ["pong"]},
               statuses: %{}
             }
           }
  end

  test "running ping when commenter is not reviewer", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 1,
        login: "user"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors ping"]},
        statuses: %{},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    c = %Command{
      project: proj,
      commenter: commenter,
      comment: "bors ping",
      pr_xref: 1
    }

    Command.run(c)
  end

  test_with_params "delegate+ delegates to patch creator", %{proj: proj}, fn delegate_command ->
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 2,
        login: "pr_author"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors #{delegate_command}"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        is_admin: true,
        login: "repo_owner"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{
      user_id: user.id,
      project_id: proj.id
    })

    c = %Command{
      project: proj,
      commenter: user,
      comment: "bors #{delegate_command}",
      pr_xref: 1
    }

    Command.run(c)

    [p] = Repo.all(BorsNG.Database.UserPatchDelegation)
    p = Repo.preload(p, :user)
    assert p.user.user_xref == 2
  end do
    [
      {"delegate+"},
      {"d+"},
      # Bare `delegate` is `delegate+`, as bare `merge` is `r+`.
      {"delegate"},
      {"d"}
    ]
  end

  test "explicit-duration delegate also backfills a lingering forever-delegation",
       %{proj: proj} do
    # A pre-existing no-expiry ("forever") delegation should be stamped with the
    # bors.toml default whenever someone delegates on the patch — even when the
    # current command carries its own explicit `for=` duration. This pins that
    # reconcile_default_expiry runs on the explicit-duration path, not only the
    # no-`for=` path it used to be limited to.
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+ for=2w"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{1 => pr}
      }
    })

    {:ok, owner} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "repo_owner"})

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: owner.id, project_id: proj.id})

    # A lingering forever-delegation (no expiry) for a different user.
    {:ok, bob} = Repo.insert(%BorsNG.Database.User{user_xref: 99, login: "bob"})

    BorsNG.Database.Context.Permission.delegate(bob, patch, delegated_at_commit: "old")

    c = %Command{
      project: proj,
      commenter: owner,
      comment: "bors delegate+ for=2w",
      pr_xref: 1
    }

    Command.run(c)

    bob_delegation =
      Repo.get_by!(BorsNG.Database.UserPatchDelegation, user_id: bob.id, patch_id: patch.id)

    # Backfilled from forever to the toml default, despite the command's
    # explicit for=2w applying only to the new delegatee.
    refute is_nil(bob_delegation.expires_at)
  end

  test_with_params "delegate= delegates properly", %{proj: proj}, fn delegate_command ->
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 2,
        login: "pr_author"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors #{delegate_command}pr_author,reviewer"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        is_admin: true,
        login: "repo_owner"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 3,
        is_admin: false,
        login: "reviewer"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{
      user_id: user.id,
      project_id: proj.id
    })

    c = %Command{
      project: proj,
      commenter: user,
      comment: "bors #{delegate_command}pr_author,reviewer",
      pr_xref: 1
    }

    Command.run(c)

    [p1, p2] = Repo.all(BorsNG.Database.UserPatchDelegation)
    p1 = Repo.preload(p1, :user)
    assert p1.user.user_xref == 2
    p2 = Repo.preload(p2, :user)
    assert p2.user.user_xref == 3
  end do
    [
      {"delegate+="},
      {"delegate="},
      {"d+="},
      {"d="}
    ]
  end

  test_with_params "delegate- removes all delegations", %{proj: proj}, fn undelegate_command ->
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 2,
        login: "pr_author"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{
          1 => ["bors d+"],
          2 => ["bors d=reviewer"],
          3 => ["bors #{undelegate_command}"]
        },
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        is_admin: true,
        login: "repo_owner"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 3,
        is_admin: false,
        login: "reviewer"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{
      user_id: user.id,
      project_id: proj.id
    })

    c1 = %Command{
      project: proj,
      commenter: user,
      comment: "bors d+",
      pr_xref: 1
    }

    Command.run(c1)

    c2 = %Command{
      project: proj,
      commenter: user,
      comment: "bors d=reviewer",
      pr_xref: 1
    }

    Command.run(c2)

    [p1, p2] = Repo.all(BorsNG.Database.UserPatchDelegation)
    p1 = Repo.preload(p1, :user)
    assert p1.user.user_xref == 2
    p2 = Repo.preload(p2, :user)
    assert p2.user.user_xref == 3

    c3 = %Command{
      project: proj,
      commenter: user,
      comment: "bors #{undelegate_command}",
      pr_xref: 1
    }

    Command.run(c3)

    [] = Repo.all(BorsNG.Database.UserPatchDelegation)
  end do
    [
      {"delegate-"},
      {"d-"}
    ]
  end

  test_with_params "delegate-= removes delegations properly",
                   %{proj: proj},
                   fn undelegate_command ->
                     pr = %BorsNG.GitHub.Pr{
                       number: 1,
                       title: "Test",
                       body: "Mess",
                       state: :open,
                       base_ref: "master",
                       head_sha: "00000001",
                       head_ref: "update",
                       base_repo_id: 13,
                       head_repo_id: 13,
                       user: %{
                         id: 2,
                         login: "pr_author"
                       }
                     }

                     GitHub.ServerMock.put_state(%{
                       {{:installation, 91}, 14} => %{
                         branches: %{},
                         comments: %{
                           1 => ["bors d+"],
                           2 => ["bors d=reviewer"],
                           3 => ["bors #{undelegate_command}"]
                         },
                         statuses: %{},
                         files: %{"master" => %{"bors.toml" => delegation_toml()}},
                         pulls: %{
                           1 => pr
                         }
                       }
                     })

                     {:ok, user} =
                       Repo.insert(%BorsNG.Database.User{
                         user_xref: 1,
                         is_admin: true,
                         login: "repo_owner"
                       })

                     {:ok, _} =
                       Repo.insert(%BorsNG.Database.User{
                         user_xref: 3,
                         is_admin: false,
                         login: "reviewer1"
                       })

                     {:ok, _} =
                       Repo.insert(%BorsNG.Database.User{
                         user_xref: 4,
                         is_admin: false,
                         login: "reviewer2"
                       })

                     {:ok, _} =
                       Repo.insert(%BorsNG.Database.Patch{
                         project_id: proj.id,
                         pr_xref: 1,
                         commit: "N",
                         into_branch: "master"
                       })

                     Repo.insert(%BorsNG.Database.LinkUserProject{
                       user_id: user.id,
                       project_id: proj.id
                     })

                     c1 = %Command{
                       project: proj,
                       commenter: user,
                       comment: "bors d+",
                       pr_xref: 1
                     }

                     Command.run(c1)

                     c2 = %Command{
                       project: proj,
                       commenter: user,
                       comment: "bors d=reviewer1,reviewer2",
                       pr_xref: 1
                     }

                     Command.run(c2)

                     [p1, p2, p3] = Repo.all(BorsNG.Database.UserPatchDelegation)
                     p1 = Repo.preload(p1, :user)
                     assert p1.user.user_xref == 2
                     p2 = Repo.preload(p2, :user)
                     assert p2.user.user_xref == 3
                     p3 = Repo.preload(p3, :user)
                     assert p3.user.user_xref == 4

                     c3 = %Command{
                       project: proj,
                       commenter: user,
                       comment: "bors #{undelegate_command}pr_author,reviewer2",
                       pr_xref: 1
                     }

                     Command.run(c3)

                     [p4] = Repo.all(BorsNG.Database.UserPatchDelegation)
                     p4 = Repo.preload(p4, :user)
                     assert p4.user.user_xref == 3
                   end do
    [
      {"delegate-="},
      {"d-="}
    ]
  end

  # Removing a delegation never withdraws a standing approval (here: one held
  # for a bundle); the acknowledgment has to say so instead of implying the
  # approval is gone.
  defp undelegate_note_setup(proj) do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "repo_owner"})

    {:ok, delegate} =
      Repo.insert(%BorsNG.Database.User{user_xref: 2, is_admin: false, login: "pr_author"})

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master",
        open: true,
        bundle_reviewer: "pr_author"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{
      user_id: user.id,
      project_id: proj.id
    })

    Repo.insert!(%BorsNG.Database.UserPatchDelegation{
      user_id: delegate.id,
      patch_id: patch.id
    })

    user
  end

  defp mock_comments(pr_xref) do
    GitHub.ServerMock.get_state()
    |> get_in([{{:installation, 91}, 14}, :comments, pr_xref])
  end

  test "delegate- notes a held approval by a removed delegate", %{proj: proj} do
    user = undelegate_note_setup(proj)

    c = %Command{
      project: proj,
      commenter: user,
      comment: "bors delegate-",
      pr_xref: 1
    }

    Command.run(c)

    assert [] == Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "All delegations have been removed"))
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "still counts"))
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "bors r-"))
  end

  test "delegate-= notes the removed delegate's held approval", %{proj: proj} do
    user = undelegate_note_setup(proj)

    c = %Command{
      project: proj,
      commenter: user,
      comment: "bors d-=pr_author",
      pr_xref: 1
    }

    Command.run(c)

    assert [] == Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "no longer delegated to pr_author"))
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "still counts"))
  end

  test "delegate- has no held-approval note when nothing is held", %{proj: proj} do
    user = undelegate_note_setup(proj)

    # Clear the held approval; the delegation alone must not trigger the note.
    Repo.get_by!(BorsNG.Database.Patch, pr_xref: 1, project_id: proj.id)
    |> BorsNG.Database.Patch.changeset(%{bundle_reviewer: nil})
    |> Repo.update!()

    c = %Command{
      project: proj,
      commenter: user,
      comment: "bors delegate-",
      pr_xref: 1
    }

    Command.run(c)

    assert Enum.any?(mock_comments(1), &String.contains?(&1, "All delegations have been removed"))
    refute Enum.any?(mock_comments(1), &String.contains?(&1, "still counts"))
  end

  defp put_mock_users(users) do
    GitHub.ServerMock.get_state()
    |> Map.put(:users, users)
    |> GitHub.ServerMock.put_state()
  end

  test "delegate- with a name keeps every delegation and suggests delegate-=",
       %{proj: proj} do
    user = undelegate_note_setup(proj)

    Command.run(%Command{project: proj, commenter: user, comment: "bors d- pr_author", pr_xref: 1})

    assert [_] = Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "`bors d-=pr_author`"))
    refute Enum.any?(mock_comments(1), &String.contains?(&1, "All delegations have been removed"))
  end

  test "an out-of-range priority replies with the range and leaves the patch alone",
       %{proj: proj} do
    user = undelegate_note_setup(proj)

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors p=99999999999",
      pr_xref: 1
    })

    assert 0 == Repo.get_by!(BorsNG.Database.Patch, pr_xref: 1, project_id: proj.id).priority

    assert Enum.any?(
             mock_comments(1),
             &String.contains?(&1, "from -2147483648 to 2147483647")
           )
  end

  test "delegate+ with a name delegates nobody and suggests delegate=", %{proj: proj} do
    user = undelegate_note_setup(proj)
    Repo.delete_all(BorsNG.Database.UserPatchDelegation)

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors d+ pr_author for=24h",
      pr_xref: 1
    })

    assert [] == Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "`bors d=pr_author for=24h`"))
    refute Enum.any?(mock_comments(1), &String.contains?(&1, "can now approve"))
  end

  # `d-` works on a draft, so its refusal must too, rather than being folded
  # into the draft refusal.
  test "delegate- with a name gets its hint on a draft", %{proj: proj} do
    user = undelegate_note_setup(proj)

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors d- pr_author",
      pr_xref: 1,
      is_draft: true
    })

    assert [_] = Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "`bors d-=pr_author`"))
    refute Enum.any?(mock_comments(1), &String.contains?(&1, "is a draft"))
  end

  defp posted_correction?(text),
    do: Enum.any?(mock_comments(1) || [], &(&1 == "Did you mean `bors #{text}`?"))

  test "a reviewer is offered the correction", %{proj: proj} do
    user = undelegate_note_setup(proj)

    Command.run(%Command{project: proj, commenter: user, comment: "bors R+", pr_xref: 1})

    assert posted_correction?("r+")
  end

  # A delegate may run `r+` on this pull request, so they hear about it. The
  # delegation is untouched: the correction never reaches the merge-time gate.
  test "a delegate is offered a correction to r+", %{proj: proj} do
    undelegate_note_setup(proj)
    delegate = Repo.get_by!(BorsNG.Database.User, login: "pr_author")

    Command.run(%Command{project: proj, commenter: delegate, comment: "bors R+", pr_xref: 1})

    assert posted_correction?("r+")
    assert [_] = Repo.all(BorsNG.Database.UserPatchDelegation)
  end

  test "someone who could not run the command is not offered the correction",
       %{proj: proj} do
    undelegate_note_setup(proj)
    outsider = Repo.insert!(%BorsNG.Database.User{user_xref: 9, login: "outsider"})

    for comment <- ["bors R+", "bors r = alice", "bors +r", "bors:retry"] do
      Command.run(%Command{project: proj, commenter: outsider, comment: comment, pr_xref: 1})
    end

    assert [] == mock_comments(1)
  end

  test "a correction to a command anyone may run is offered to anyone", %{proj: proj} do
    undelegate_note_setup(proj)
    outsider = Repo.insert!(%BorsNG.Database.User{user_xref: 9, login: "outsider"})

    Command.run(%Command{project: proj, commenter: outsider, comment: "bors Ping", pr_xref: 1})

    assert posted_correction?("ping")
  end

  # `r-` works on a draft, so its refusal must too.
  test "r- with something after it gets its hint on a draft", %{proj: proj} do
    user = undelegate_note_setup(proj)

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors r- now",
      pr_xref: 1,
      is_draft: true
    })

    assert Enum.any?(mock_comments(1), &String.contains?(&1, "bors did not run `bors r- now`"))
    refute Enum.any?(mock_comments(1), &String.contains?(&1, "is a draft"))
  end

  # A token that cannot be a login never reaches GitHub, which would answer
  # "no such user" for it.
  test "delegating to something that cannot be a login delegates nobody", %{proj: proj} do
    user = undelegate_note_setup(proj)
    Repo.delete_all(BorsNG.Database.UserPatchDelegation)

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors d=pr_author p=5",
      pr_xref: 1
    })

    assert [] == Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "`p=5` cannot be a GitHub username"))
    refute Enum.any?(mock_comments(1), &String.contains?(&1, "no GitHub user"))
  end

  test "an unreadable for= delegates nobody instead of using the default", %{proj: proj} do
    user = undelegate_note_setup(proj)
    Repo.delete_all(BorsNG.Database.UserPatchDelegation)

    Command.run(%Command{project: proj, commenter: user, comment: "bors d+ for=24m", pr_xref: 1})

    assert [] == Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "it cannot read `for=24m`"))
    refute Enum.any?(mock_comments(1), &String.contains?(&1, "can now approve"))
  end

  # `d-=` works on a draft, so its hint must too.
  test "an empty delegate-= gets its hint on a draft", %{proj: proj} do
    user = undelegate_note_setup(proj)

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors d-=",
      pr_xref: 1,
      is_draft: true
    })

    assert [_] = Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "`bors d-=` needs the users"))
    refute Enum.any?(mock_comments(1), &String.contains?(&1, "is a draft"))
  end

  test "delegating to an unknown user says so instead of crashing", %{proj: proj} do
    user = undelegate_note_setup(proj)

    Command.run(%Command{project: proj, commenter: user, comment: "bors d=alcie", pr_xref: 1})

    assert [_] = Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "no GitHub user named `alcie`"))
  end

  test "undelegating an unknown user says so instead of crashing", %{proj: proj} do
    user = undelegate_note_setup(proj)

    Command.run(%Command{project: proj, commenter: user, comment: "bors d-=alcie", pr_xref: 1})

    assert [_] = Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "no GitHub user named `alcie`"))
  end

  # A typo refuses every delegation command in the comment, including the
  # `d-` that was meant to clear the way for the new names.
  test "one unknown login refuses every delegation command in the comment",
       %{proj: proj} do
    user = undelegate_note_setup(proj)
    Repo.insert!(%BorsNG.Database.User{user_xref: 3, login: "reviewer"})

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors d-\nbors d=reviewer,alcie,bbo",
      pr_xref: 1
    })

    [delegation] = Repo.all(BorsNG.Database.UserPatchDelegation) |> Repo.preload(:user)
    assert delegation.user.login == "pr_author"

    assert Enum.any?(
             mock_comments(1),
             &String.contains?(&1, "no GitHub users named `alcie`, `bbo`")
           )

    refute Enum.any?(mock_comments(1), &String.contains?(&1, "All delegations have been removed"))
  end

  test "a failed user lookup says so and changes nothing", %{proj: proj} do
    user = undelegate_note_setup(proj)
    put_mock_users(%{"alice" => :error})

    Command.run(%Command{project: proj, commenter: user, comment: "bors d=alice", pr_xref: 1})

    assert [_] = Repo.all(BorsNG.Database.UserPatchDelegation)
    assert Enum.any?(mock_comments(1), &String.contains?(&1, "could not look up `alice`"))
  end

  # Postgres compares logins case-sensitively, so `Reviewer` misses the
  # stored `reviewer`. GitHub's answer carries the same id, which must find
  # that row instead of inserting a duplicate.
  test "a login typed in another case delegates the stored user", %{proj: proj} do
    user = undelegate_note_setup(proj)
    reviewer = Repo.insert!(%BorsNG.Database.User{user_xref: 3, login: "reviewer"})
    put_mock_users(%{"Reviewer" => %GitHub.User{id: 3, login: "reviewer"}})

    Command.run(%Command{project: proj, commenter: user, comment: "bors d=Reviewer", pr_xref: 1})

    assert 3 == Repo.aggregate(BorsNG.Database.User, :count)

    assert Enum.any?(
             Repo.all(BorsNG.Database.UserPatchDelegation),
             &(&1.user_id == reviewer.id)
           )

    assert Enum.any?(mock_comments(1), &String.contains?(&1, "reviewer can now approve"))
  end

  test "retry fails for non-members", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 2,
        login: "pr_author"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    c = %Command{
      project: proj,
      commenter: commenter,
      comment: "bors ping",
      patch: patch,
      pr_xref: 1
    }

    Command.run(c)

    c = %Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      patch: patch,
      pr_xref: 1
    }

    Command.run(c)

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => [":lock:" <> _, _]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "retry does nothing useful after ping and posts nothing to retry message", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.LinkMemberProject{
        user_id: commenter.id,
        project_id: proj.id
      })

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors ping",
      patch: patch,
      pr_xref: 1
    })

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      patch: patch,
      pr_xref: 1
    })

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => ["Nothing to retry.", "pong"]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "retry does nothing after deactivate and posts nothing to retry message", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.LinkMemberProject{
        user_id: commenter.id,
        project_id: proj.id
      })

    # Seed command history directly to avoid permission checks and worker GenServers
    Logging.log_cmd(patch, commenter, :activate)
    Logging.log_cmd(patch, commenter, :deactivate)

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      patch: patch,
      pr_xref: 1
    })

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => ["Nothing to retry."]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "run ping does not require a GitHub PR fetch", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    c = %Command{
      project: proj,
      commenter: nil,
      comment: "bors ping",
      pr_xref: 1
    }

    Command.run(c)

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => ["pong"]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "retry posts nothing-to-retry when patch exists but no replayable history", %{proj: proj} do
    # Verifies retry handles the case where the patch is in the DB (but the
    # GitHub PR is unavailable) and there is no replayable prior command.
    # This is distinct from the next test where no patch exists at all.
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.LinkMemberProject{
        user_id: commenter.id,
        project_id: proj.id
      })

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      patch: patch,
      pr_xref: 1
    })

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => ["Nothing to retry."]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "member command exits cleanly when patch and GitHub PR are unavailable", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.LinkMemberProject{
        user_id: commenter.id,
        project_id: proj.id
      })

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      pr_xref: 1
    })

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => []}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "running bros command should post brofist", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    c = %Command{
      project: proj,
      commenter: nil,
      comment: "bros ping",
      pr_xref: 1
    }

    Command.run(c, :bros)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{},
               comments: %{1 => ["👊"]},
               statuses: %{}
             }
           }
  end

  test "command trigger is dynamically set by env" do
    old_env = System.get_env("COMMAND_TRIGGER")
    System.put_env("COMMAND_TRIGGER", "popo")

    assert [] == Command.parse("bors try")
    assert [] == Command.parse("bors r+")
    assert [] == Command.parse("bors merge")
    assert [] == Command.parse("bors r-")
    assert [] == Command.parse("bors merge-")
    assert [] == Command.parse("bors cancel")

    assert [{:try, ""}] == Command.parse("popo try")
    assert [:activate] == Command.parse("popo r+")
    assert [:activate] == Command.parse("popo merge")
    assert [:deactivate] == Command.parse("popo r-")
    assert [:deactivate] == Command.parse("popo merge-")
    assert [:deactivate] == Command.parse("popo cancel")

    if old_env do
      System.put_env("COMMAND_TRIGGER", old_env)
    else
      System.delete_env("COMMAND_TRIGGER")
    end
  end

  describe "delegation for= duration parsing" do
    test "delegate+ accepts for= duration" do
      assert [{:delegate, 86_400}] == Command.parse("bors delegate+ for=24h")
      assert [{:delegate, 86_400}] == Command.parse("bors d+ for=24h")
      assert [{:delegate, 604_800}] == Command.parse("bors delegate+ for=7d")
      assert [{:delegate, 1_209_600}] == Command.parse("bors d+ for=2w")
    end

    test "delegate+ without for= remains the bare command" do
      assert [:delegate] == Command.parse("bors delegate+")
      assert [:delegate] == Command.parse("bors d+")
    end

    test "delegate= accepts for= duration after username list" do
      assert [{:delegate_to, "alice", 86_400}] ==
               Command.parse("bors delegate=alice for=24h")

      assert [
               {:delegate_to, "alice", 86_400},
               {:delegate_to, "bob", 86_400}
             ] == Command.parse("bors d=alice,bob for=24h")
    end

    test "delegate= without for= preserves the original 2-tuple shape" do
      assert [{:delegate_to, "alice"}] == Command.parse("bors delegate=alice")

      assert [{:delegate_to, "alice"}, {:delegate_to, "bob"}] ==
               Command.parse("bors d=alice,bob")
    end

    # Falling back to the default expiry would grant something other than
    # what was asked for.
    test "refuses out-of-range or malformed durations" do
      for {comment, token} <- [
            # Too long (>90d cap)
            {"bors delegate+ for=100d", "for=100d"},
            # Zero
            {"bors delegate+ for=0h", "for=0h"},
            # Unrecognized unit
            {"bors delegate+ for=24m", "for=24m"},
            # Garbage
            {"bors delegate+ for=foo", "for=foo"},
            {"bors d+ for=", "for="},
            {"bors d=alice for=24m", "for=24m"},
            # Refused for the duration before the names are looked at.
            {"bors d+ alice for=24m", "for=24m"}
          ] do
        "bors " <> typed = comment
        assert [{:malformed_args, {:bad_for, typed, [token]}}] == Command.parse(comment), comment
      end
    end

    # Otherwise `for` and `24h` would be taken for logins, which GitHub may
    # well have.
    test "refuses a for typed with a space instead of =" do
      assert [{:malformed_args, {:bad_for, "d=alice for 24h", ["for"]}}] ==
               Command.parse("bors d=alice for 24h")

      assert [{:malformed_args, {:bad_for, "d+ for 24h", ["for"]}}] ==
               Command.parse("bors d+ for 24h")
    end

    test "for= token may appear anywhere in the argument list" do
      # for= in the middle
      assert [
               {:delegate_to, "alice", 86_400},
               {:delegate_to, "bob", 86_400}
             ] == Command.parse("bors d=alice for=24h bob")

      # for= at the very front
      assert [
               {:delegate_to, "alice", 86_400},
               {:delegate_to, "bob", 86_400}
             ] == Command.parse("bors d=for=24h alice,bob")

      # Mixed comma/space separators with for= mid-list
      assert [
               {:delegate_to, "alice", 86_400},
               {:delegate_to, "bob", 86_400}
             ] == Command.parse("bors d=alice,for=24h,bob")
    end

    # Picking one of two would be a guess.
    test "refuses more than one for=" do
      assert [{:malformed_args, {:repeated_for, "d=alice for=24h for=7d"}}] ==
               Command.parse("bors d=alice for=24h for=7d")

      assert [{:malformed_args, {:repeated_for, "d+ for=24h for=7d"}}] ==
               Command.parse("bors d+ for=24h for=7d")

      # An unreadable one is named, rather than the earlier one used.
      assert [{:malformed_args, {:bad_for, "d=alice for=24h for=garbage", ["for=garbage"]}}] ==
               Command.parse("bors d=alice for=24h for=garbage")
    end
  end

  test "delegate+ refuses when no for= and no bors.toml default", %{inst: inst} do
    proj_no_default =
      %Project{
        installation_id: inst.id,
        repo_xref: 15,
        staging_branch: "staging"
      }
      |> Repo.insert!()

    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 15} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj_no_default.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj_no_default.id})

    c = %Command{
      project: proj_no_default,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    }

    Command.run(c)

    assert [] == Repo.all(BorsNG.Database.UserPatchDelegation)
    state = GitHub.ServerMock.get_state()
    comments = get_in(state, [{{:installation, 91}, 15}, :comments, 1])

    assert Enum.any?(
             comments,
             &String.contains?(&1, "Delegation requires an explicit expiration")
           )
  end

  test "delegate+ uses bors.toml default when no for= given", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "headsha123",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    c = %Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    }

    Command.run(c)

    [d] = Repo.all(BorsNG.Database.UserPatchDelegation)
    refute is_nil(d.expires_at)
    # Syncer.sync_patch overwrites patch.commit with the PR's head_sha during run.
    assert d.delegated_at_commit == "00000001"
  end

  test "delegate+ echoes invalidate_on_paths in the success comment", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    toml = ~s"""
    status = ["ci"]
    [delegation]
    default_expiry_sec = #{24 * 60 * 60}
    invalidate_on_paths = ["Cargo.toml", ".github/**"]
    """

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => toml}},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "headsha123",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    })

    state = GitHub.ServerMock.get_state()
    comments = get_in(state, [{{:installation, 91}, 14}, :comments, 1])

    assert Enum.any?(comments, fn c ->
             String.contains?(c, "revoke this delegation") and
               String.contains?(c, "`Cargo.toml`") and
               String.contains?(c, "`.github/**`")
           end)
  end

  test "delegate+ omits the paths note when invalidate_on_paths is empty", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "headsha123",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    })

    state = GitHub.ServerMock.get_state()
    comments = get_in(state, [{{:installation, 91}, 14}, :comments, 1])

    refute Enum.any?(comments, &String.contains?(&1, "revoke this delegation"))
  end

  test "delegate+ describes the delegated scope and the too-many-files caveat", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    toml = ~s"""
    status = ["ci"]
    [delegation]
    default_expiry_sec = #{24 * 60 * 60}
    restrict_to_paths = ["src/**"]
    """

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => toml}},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "headsha123",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    })

    state = GitHub.ServerMock.get_state()
    comments = get_in(state, [{{:installation, 91}, 14}, :comments, 1])

    assert Enum.any?(comments, fn c ->
             String.contains?(c, "only covers changes within") and String.contains?(c, "`src/**`")
           end)

    assert Enum.any?(comments, &String.contains?(&1, "too many files"))
  end

  test "re-delegating the same user replaces expires_at", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "abc",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+ for=1h",
      pr_xref: 1
    })

    [d1] = Repo.all(BorsNG.Database.UserPatchDelegation)

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+ for=7d",
      pr_xref: 1
    })

    [d2] = Repo.all(BorsNG.Database.UserPatchDelegation)

    assert d2.id == d1.id
    assert NaiveDateTime.compare(d2.expires_at, d1.expires_at) == :gt
  end

  defp draft_setup(proj, opts \\ []) do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => ~s(status = ["ci"]\n)}}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "repo_owner"})

    {:ok, _patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master",
        open: true,
        is_draft: Keyword.get(opts, :is_draft, true)
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    user
  end

  defp run_on_draft(proj, user, comment, fields \\ []) do
    Command.run(
      struct(
        %Command{
          project: proj,
          commenter: user,
          comment: comment,
          pr_xref: 1
        },
        fields
      )
    )
  end

  test "a draft refuses r+ and says so", %{proj: proj} do
    user = draft_setup(proj)

    run_on_draft(proj, user, "bors r+", is_draft: true)

    assert [comment] = mock_comments(1)
    assert comment =~ "is a draft"
    assert comment =~ "`bors r+`"
    assert [] == Repo.all(BorsNG.Database.LinkPatchBatch)
  end

  test "a draft says nothing when the comment carries no command", %{proj: proj} do
    user = draft_setup(proj)

    run_on_draft(proj, user, "I will mark this ready and then ask bors to merge it",
      is_draft: true
    )

    assert [] == mock_comments(1)
  end

  test "a draft allows the commands that cannot lead to a merge", %{proj: proj} do
    user = draft_setup(proj)

    run_on_draft(proj, user, "bors ping", is_draft: true)

    assert ["pong"] == mock_comments(1)
  end

  test "a draft refuses the whole comment when any command is blocked", %{proj: proj} do
    user = draft_setup(proj)

    run_on_draft(proj, user, "bors ping\nbors r+", is_draft: true)

    # `ping` is allowed on its own, but a blocked command takes the whole
    # comment with it, the way a permission failure does. The refusal has to
    # say so, or it reads as though the `ping` ran.
    assert [comment] = mock_comments(1)
    assert comment =~ "`bors r+`"
    assert comment =~ "`bors ping` did not run either"
    refute comment =~ "pong"
  end

  # End-to-end counterpart to the naming tests in `message_test.exs`: the tag
  # the parser produces for `bors r-` is `:deactivate`, and a refusal that
  # echoed the tag would tell the author to run `bors deactivate`, which
  # parses to nothing.
  test "a draft names a dropped command as the author typed it", %{proj: proj} do
    user = draft_setup(proj)

    run_on_draft(proj, user, "bors r-\nbors r+", is_draft: true)

    assert [comment] = mock_comments(1)
    assert comment =~ "`bors r-` did not run either"
    refute comment =~ "bors deactivate"
  end

  test "a refused draft command is not logged, so retry cannot replay it", %{proj: proj} do
    user = draft_setup(proj)

    run_on_draft(proj, user, "bors r+", is_draft: true)

    patch = Repo.get_by!(BorsNG.Database.Patch, project_id: proj.id, pr_xref: 1)
    assert nil == Logging.most_recent_cmd(patch)
  end

  test "the draft refusal cannot be parsed as a command", %{proj: proj} do
    user = draft_setup(proj)

    run_on_draft(proj, user, "bors r+", is_draft: true)

    assert [comment] = mock_comments(1)
    assert [] == Command.parse(comment)
  end

  test "a draft is recognized from the synced patch when the caller does not say", %{proj: proj} do
    user = draft_setup(proj)

    # No `is_draft` and no `pr`: the gate falls back to the patch row.
    run_on_draft(proj, user, "bors r+")

    assert [comment] = mock_comments(1)
    assert comment =~ "is a draft"
  end

  test "an explicit not-a-draft flag wins over a stale patch row", %{proj: proj} do
    user = draft_setup(proj)

    # The patch row says draft; the live payload flag is fresher and wins.
    run_on_draft(proj, user, "bors ping", is_draft: false)

    assert ["pong"] == mock_comments(1)
  end

  test "a PR that is not a draft is unaffected", %{proj: proj} do
    user = draft_setup(proj, is_draft: false)

    run_on_draft(proj, user, "bors r+")

    # `r+` is the only command in this block that reaches the batcher, and
    # `Batcher.reviewed/3` is a cast. Left unsynchronized, the batcher picks it
    # up after this test's sandbox owner has exited, dies on the checked-in
    # connection, and the registry logs a rescued crash against a project row
    # that rolled back with the test. Flush the mailbox before asserting.
    _ = :sys.get_state(BorsNG.Worker.Batcher.Registry.get(proj.id))

    refute Enum.any?(mock_comments(1), &String.contains?(&1, "is a draft"))

    # The command ran: a refusal would neither log nor reach the batcher.
    patch = Repo.get_by!(BorsNG.Database.Patch, project_id: proj.id, pr_xref: 1)
    assert {%{login: "repo_owner"}, :activate} = Logging.most_recent_cmd(patch)
  end
end
