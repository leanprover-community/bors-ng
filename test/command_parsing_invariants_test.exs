defmodule BorsNG.CommandParsingInvariantsTest do
  @moduledoc """
  The invariants in COMMAND_PARSING.md, checked across a corpus of lines. A
  change that breaks one fails here even if no test of its own command does.
  Add a line to a corpus whenever a new command or a new way to mistype one
  comes up.
  """

  use ExUnit.Case, async: true

  alias BorsNG.Command
  alias BorsNG.Worker.Batcher.Message

  # Lines that are attempts at a command, well or badly formed. Each must
  # read as the commands it spells or as a reply saying why not.
  @attempts [
    "bors r+",
    "bors r+ now",
    "bors r+!",
    "bors R+",
    "bors R+ now",
    "bors +r",
    "bors +r now",
    "bors r +",
    "bors:r+",
    "bors:r+ now",
    "bors merge",
    "bors merge!",
    "bors merge queue is slow",
    "bors merge single on",
    "bors r-",
    "bors r- now",
    "bors merge- x",
    "bors cancel!",
    "bors try",
    "bors try --layout",
    "bors try-",
    "bors try- now",
    "bors ping",
    "bors ping now",
    "bors retry",
    "bors retry (flaky)",
    "bors p=5",
    "bors p=abc",
    "bors p=5abc",
    "bors p=99999999999",
    "bors p=5 r+",
    "bors p = 5",
    "bors single on",
    "bors single",
    "bors single maybe",
    "bors single on p=5",
    "bors r+ single on",
    "bors r+ single on p=5",
    "bors r+ p=5",
    "bors r+ p=abc",
    "bors r+ p=5 single on",
    "bors r=alice",
    "bors r=alice, bob",
    "bors r=alice bob",
    "bors r=alice p=5",
    "bors r=alice p=5 now",
    "bors r= p=5",
    "bors r=",
    "bors merge=",
    "bors delegate",
    "bors d",
    "bors d alice",
    "bors delegate to alice",
    "bors d+",
    "bors d+ for=24h",
    "bors d+ for=24m",
    "bors d+ for 24h",
    "bors d+ alice",
    "bors d+ for=24h for=7d",
    "bors d=alice",
    "bors d=alice bob",
    "bors d=alice for=24h",
    "bors d=alice for=100d",
    "bors d=alice p=5",
    "bors d=",
    "bors d= for=24h",
    "bors d +",
    "bors d =alice",
    "bors d-",
    "bors d- alice",
    "bors d- for=24h",
    "bors d-=alice",
    "bors d-=alice bob",
    "bors d-=alice for=24h",
    "bors d-=",
    "bors delegate-= @alice",
    "bors link #2",
    "bors link #1 R+",
    "bors link #1 p=5",
    "bors stack #2",
    "bors unlink",
    "bors unlink now",
    "bors link- #3"
  ]

  # Lines that start with the trigger but are sentences about bors, or a
  # command word run into a longer one. None may read as anything.
  @prose [
    "bors doink",
    "bors is slow today",
    "bors merged this yesterday",
    "bors mergeable?",
    "bors merge-conflicts are fixed",
    "bors cancelled it",
    "bors retrying now",
    "bors trying again",
    "bors try-cancel",
    "bors linked #12 already",
    "bors link-rot",
    "bors unlinked them",
    "bors stacked on #5",
    "bors pinged me",
    "bors single-handedly",
    "bors delegated this",
    "bors delegation is on",
    "bors does this work",
    "bors d'oh",
    "bors Merged this",
    "bors +rebase",
    "bros doink"
  ]

  defp hint?({:malformed_args, _}), do: true
  defp hint?({:link_malformed, _, _}), do: true
  defp hint?(:unlink_with_args), do: true
  defp hint?({:autocorrect, _}), do: true
  defp hint?(_), do: false

  test "every attempt at a command reads as something" do
    for line <- @attempts do
      assert Command.parse(line) != [], "#{inspect(line)} was silently ignored"
    end
  end

  test "a sentence that starts with the trigger reads as nothing" do
    for line <- @prose do
      assert [] == Command.parse(line), "#{inspect(line)} read as a command"
    end
  end

  # The joke trigger answers with a fist bump and never runs what follows,
  # however many commands the line spells or how `bros` is capitalized.
  test "a line under the bros trigger never runs" do
    for "bors " <> command <- @attempts, trigger <- ["bros", "Bros", "BROS"] do
      line = "#{trigger} #{command}"
      assert Command.parse(line) in [[], [:bros]], "#{inspect(line)} ran a command"
    end
  end

  # A refused line runs nothing from that line: a bad modifier swallows the
  # command it modifies rather than being dropped from it.
  test "a line reads as commands or as replies, never both" do
    for line <- @attempts do
      cmds = Command.parse(line)

      assert Enum.all?(cmds, &hint?/1) or not Enum.any?(cmds, &hint?/1),
             "#{inspect(line)} mixes commands and refusals: #{inspect(cmds)}"
    end
  end

  test "every refusal opens by naming the command as typed" do
    for line <- @attempts, {:malformed_args, hint} <- Command.parse(line) do
      typed = elem(hint, 1)
      assert is_binary(typed), "#{inspect(line)}: #{inspect(hint)} carries no typed command"
      msg = Message.generate_message({:malformed_args, hint})

      assert String.starts_with?(msg, ":-1: bors did not run `bors #{typed}`"),
             "#{inspect(line)}: #{msg}"
    end
  end

  # bors reads its own comments, so a reply that parsed as a command would
  # run it, or answer itself forever.
  test "no reply to an attempt reads as a command" do
    for line <- @attempts, {:malformed_args, _} = hint <- Command.parse(line) do
      msg = Message.generate_message(hint)
      assert [] == Command.parse(msg), "#{inspect(line)}: #{msg}"

      draft = Message.generate_message({:draft_refused, [hint], []})
      assert [] == Command.parse(draft), "#{inspect(line)}: #{draft}"
    end
  end

  # A refusal must never reach `DelegationInvalidator.verify_for_merge/2`,
  # which revokes as a side effect, so no hint may need `:reviewer`.
  test "no reply is gated at reviewer level" do
    for line <- @attempts, cmd <- Command.parse(line), hint?(cmd) do
      level = Command.required_permission_level([cmd])

      assert level in [:none, :member, :project_member],
             "#{inspect(line)}: #{inspect(cmd)} needs #{inspect(level)}"
    end
  end

  # Named as typed in a draft refusal, a hint can be run again and get the
  # hint again, rather than the command it was mistaken for.
  test "a draft refusal names a refused command as typed" do
    for line <- @attempts, {:malformed_args, hint} <- Command.parse(line) do
      msg = Message.generate_message({:draft_refused, [{:malformed_args, hint}], []})
      assert msg =~ "`bors #{elem(hint, 1)}`", "#{inspect(line)}: #{msg}"
    end
  end
end
