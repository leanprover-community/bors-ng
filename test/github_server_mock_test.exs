defmodule BorsNG.GitHub.ServerMockTest do
  use ExUnit.Case

  alias BorsNG.GitHub
  alias BorsNG.GitHub.ServerMock

  doctest BorsNG.GitHub.ServerMock

  describe "labels" do
    @conn {{:installation, 91}, 14}

    setup do
      ServerMock.put_state(%{
        @conn => %{
          labels: %{1 => ["existing"]}
        }
      })

      :ok
    end

    test "add_labels adds a label without duplicating" do
      assert :ok = GitHub.add_labels(@conn, 1, ["ready-to-merge"])
      # Adding a label that's already present is idempotent.
      assert :ok = GitHub.add_labels(@conn, 1, ["existing"])

      labels = GitHub.get_labels!(@conn, 1)
      assert "ready-to-merge" in labels
      assert Enum.count(labels, &(&1 == "existing")) == 1
    end

    test "add_labels works when the issue has no labels yet" do
      assert :ok = GitHub.add_labels(@conn, 2, ["delegated"])
      assert GitHub.get_labels!(@conn, 2) == ["delegated"]
    end

    test "add_labels with an empty list is a no-op" do
      assert :ok = GitHub.add_labels(@conn, 1, [])
      assert GitHub.get_labels!(@conn, 1) == ["existing"]
    end

    test "remove_label removes a present label" do
      assert :ok = GitHub.remove_label(@conn, 1, "existing")
      assert GitHub.get_labels!(@conn, 1) == []
    end

    test "remove_label is a no-op for an absent label" do
      assert :ok = GitHub.remove_label(@conn, 1, "not-there")
      assert GitHub.get_labels!(@conn, 1) == ["existing"]
    end
  end

  describe "list_issues_by_label" do
    @conn {{:installation, 91}, 14}

    setup do
      ServerMock.put_state(%{
        @conn => %{
          labels: %{
            1 => ["ready-to-merge", "delegated"],
            2 => ["ready-to-merge"],
            3 => ["other"]
          }
        }
      })

      :ok
    end

    test "returns each matching issue with its full label set" do
      assert {:ok, issues} = GitHub.list_issues_by_label(@conn, "ready-to-merge")

      assert Enum.sort(issues) == [
               {1, ["ready-to-merge", "delegated"]},
               {2, ["ready-to-merge"]}
             ]
    end

    test "returns an empty list when no issue carries the label" do
      assert {:ok, []} = GitHub.list_issues_by_label(@conn, "nonexistent")
    end
  end
end
