defmodule BorsNG.Worker.Batcher.GetBorsTomlTest do
  @moduledoc """
  Tests for the `bors.toml` inference fallback.

  A repo with no `bors.toml` gets its status list inferred from whichever CI
  config files it carries. That path builds a `BorsToml` struct directly, so it
  does not get `BorsToml.new/1`'s validation — including its rejection of a
  duplicated `status` list. Several filenames infer the *same* status, so the
  inferred list has to be deduped here or `Batcher.setup_statuses/2` violates
  `statuses_identifier_batch_id_index` on the second insert.
  """
  use ExUnit.Case

  alias BorsNG.GitHub
  alias BorsNG.Worker.Batcher.GetBorsToml

  @conn {{:installation, 94}, 32}

  defp put_files(files) do
    GitHub.ServerMock.put_state(%{@conn => %{files: %{"master" => files}}})
  end

  test "infers nothing when the repo carries no recognized config" do
    put_files(%{"README.md" => ""})
    assert {:error, :fetch_failed} = GetBorsToml.get(@conn, "master")
  end

  test "infers one status per recognized config" do
    put_files(%{".travis.yml" => "", ".semaphore/semaphore.yml" => ""})

    assert {:ok, toml} = GetBorsToml.get(@conn, "master")

    assert Enum.sort(toml.status) == [
             "continuous-integration/semaphoreci",
             "continuous-integration/travis-ci/push"
           ]
  end

  test "both AppVeyor config names infer the status only once" do
    # A rename whose old file was never deleted. `.appveyor.yml` and
    # `appveyor.yml` map to the same status.
    put_files(%{".appveyor.yml" => "", "appveyor.yml" => ""})

    assert {:ok, toml} = GetBorsToml.get(@conn, "master")
    assert toml.status == ["continuous-integration/appveyor/branch"]
  end

  test "the four Codeship config names infer the status only once" do
    put_files(%{
      "jet-steps.yml" => "",
      "jet-steps.json" => "",
      "codeship-steps.yml" => "",
      "codeship-steps.json" => ""
    })

    assert {:ok, toml} = GetBorsToml.get(@conn, "master")
    assert toml.status == ["continuous-integration/codeship"]
  end

  test "a duplicate-inferring repo still yields a usable list alongside others" do
    put_files(%{".travis.yml" => "", "jet-steps.yml" => "", "codeship-steps.json" => ""})

    assert {:ok, toml} = GetBorsToml.get(@conn, "master")

    assert Enum.sort(toml.status) == [
             "continuous-integration/codeship",
             "continuous-integration/travis-ci/push"
           ]

    assert toml.status == Enum.uniq(toml.status)
  end

  test "a real bors.toml still rejects a duplicated status list" do
    # The validated path already refuses this; the dedupe above must not be
    # read as making duplicates acceptable in a hand-written config.
    GitHub.ServerMock.put_state(%{
      @conn => %{files: %{"master" => %{"bors.toml" => ~s/status = ["ci", "ci"]\n/}}}
    })

    assert {:error, :status} = GetBorsToml.get(@conn, "master")
  end
end
