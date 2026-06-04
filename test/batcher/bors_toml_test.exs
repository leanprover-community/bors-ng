defmodule BatcherBorsTomlTest do
  use ExUnit.Case, async: true

  alias BorsNG.Worker.Batcher.BorsToml

  test "does not accept an empty config file" do
    r = BorsToml.new("")
    assert r == {:error, :empty_config}
  end

  test "accepts a config file with just labels" do
    {:ok, toml} = BorsToml.new(~s/block_labels = ["l1"]/)

    assert toml == %BorsToml{
             pr_status: [],
             status: [],
             block_labels: ["l1"],
             timeout_sec: 3600
           }
  end

  test "can parse a single status code" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]/)
    assert toml.status == ["exl"]
  end

  test "can parse two status codes" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl", "exm"]/)
    assert toml.status == ["exl", "exm"]
  end

  test "has a default timeout" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]/)
    assert is_integer(toml.timeout_sec)
  end

  test "can parse a custom timeout" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]\ntimeout_sec = 1/)
    assert toml.timeout_sec == 1
  end

  test "can parse a custom timeout with hyphen" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]\ntimeout-sec = 2/)
    assert toml.timeout_sec == 2
  end

  test "can parse committer details" do
    {:ok, toml} =
      BorsToml.new(~s/status = ["exl"]\n[committer]\nname = "BORS"\nemail = "bors@ex.com"/)

    assert toml.committer.name == "BORS"
    assert toml.committer.email == "bors@ex.com"
  end

  test "defaults committer details to nil" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]/)
    assert is_nil(toml.committer)
  end

  test "defaults cut_body_after to nil" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]/)
    assert is_nil(toml.cut_body_after)
  end

  test "recognizes a parse failure" do
    r = BorsToml.new(~s/status = "/)
    assert r == {:error, :parse_failed}
  end

  test "recognizes an invalid timeout" do
    r = BorsToml.new(~s/status = []\ntimeout_sec = "3 days"/)
    assert r == {:error, :timeout_sec}
  end

  test "recognizes an invalid status" do
    r = BorsToml.new(~s/status = "exl"/)
    assert r == {:error, :status}
  end

  test "recognizes a duplicate status" do
    r = BorsToml.new(~s/status = ["exl", "exl"]/)
    assert r == {:error, :status}
  end

  test "recognizes a duplicate PR status" do
    r = BorsToml.new(~s/status = ["exl"]\npr_status = ["exl", "exl"]/)
    assert r == {:error, :pr_status}
  end

  test "recognizes an invalid cut_body_after" do
    r = BorsToml.new(~s/cut_body_after = 13/)
    assert r == {:error, :cut_body_after}
  end

  test "requires committer email if name provided" do
    r = BorsToml.new(~s/status = ["exl"]\n[committer]\nname = "BORS!"/)
    assert r == {:error, :committer_details}
  end

  test "requires committer name if email provided" do
    r = BorsToml.new(~s/status = ["exl"]\n[committer]\nemail = "bors@ex.com"/)
    assert r == {:error, :committer_details}
  end

  test "up_to_date_approvals can be set to true " do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]\nup_to_date_approvals = true/)
    assert toml.up_to_date_approvals == true
  end

  test "defaults delegation_default_expiry_sec to nil" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]/)
    assert is_nil(toml.delegation_default_expiry_sec)
  end

  test "parses [delegation] default_expiry_sec" do
    {:ok, toml} =
      BorsToml.new(~s/status = ["exl"]\n[delegation]\ndefault_expiry_sec = 86400/)

    assert toml.delegation_default_expiry_sec == 86_400
  end

  test "rejects non-integer [delegation] default_expiry_sec" do
    r = BorsToml.new(~s/status = ["exl"]\n[delegation]\ndefault_expiry_sec = "24h"/)
    assert r == {:error, :delegation_default_expiry_sec}
  end

  test "rejects non-positive [delegation] default_expiry_sec" do
    r = BorsToml.new(~s/status = ["exl"]\n[delegation]\ndefault_expiry_sec = 0/)
    assert r == {:error, :delegation_default_expiry_sec}
  end

  test "rejects [delegation] default_expiry_sec above the 90-day cap" do
    too_big = BorsNG.Command.delegation_max_duration_sec() + 1

    r =
      BorsToml.new(~s/status = ["exl"]\n[delegation]\ndefault_expiry_sec = #{too_big}/)

    assert r == {:error, :delegation_default_expiry_sec}
  end

  test "rejects a non-table [delegation] value" do
    r = BorsToml.new(~s/status = ["exl"]\ndelegation = "nope"/)
    assert r == {:error, :delegation_default_expiry_sec}
  end

  test "defaults delegation_invalidate_on_paths to []" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]/)
    assert toml.delegation_invalidate_on_paths == []
  end

  test "parses delegation.invalidate_on_paths" do
    cfg = ~s"""
    status = ["exl"]
    [delegation]
    invalidate_on_paths = ["Cargo.toml", ".github/**", "src/critical/*.rs"]
    """

    {:ok, toml} = BorsToml.new(cfg)

    assert toml.delegation_invalidate_on_paths == [
             "Cargo.toml",
             ".github/**",
             "src/critical/*.rs"
           ]
  end

  test "rejects non-list delegation.invalidate_on_paths" do
    r = BorsToml.new(~s/status = ["exl"]\n[delegation]\ninvalidate_on_paths = "Cargo.toml"/)
    assert r == {:error, :delegation_invalidate_on_paths}
  end

  test "rejects non-string elements in delegation.invalidate_on_paths" do
    r = BorsToml.new(~s/status = ["exl"]\n[delegation]\ninvalidate_on_paths = ["ok", 42]/)
    assert r == {:error, :delegation_invalidate_on_paths}
  end

  test "defaults delegation_restrict_to_paths to []" do
    {:ok, toml} = BorsToml.new(~s/status = ["exl"]/)
    assert toml.delegation_restrict_to_paths == []
  end

  test "parses delegation.restrict_to_paths" do
    cfg = ~s"""
    status = ["exl"]
    [delegation]
    restrict_to_paths = ["src/**", "tests/**"]
    """

    {:ok, toml} = BorsToml.new(cfg)

    assert toml.delegation_restrict_to_paths == ["src/**", "tests/**"]
  end

  test "parses delegation.restrict_to_paths alongside invalidate_on_paths" do
    cfg = ~s"""
    status = ["exl"]
    [delegation]
    restrict_to_paths = ["src/**"]
    invalidate_on_paths = ["src/crypto.rs"]
    """

    {:ok, toml} = BorsToml.new(cfg)

    assert toml.delegation_restrict_to_paths == ["src/**"]
    assert toml.delegation_invalidate_on_paths == ["src/crypto.rs"]
  end

  test "rejects non-list delegation.restrict_to_paths" do
    r = BorsToml.new(~s/status = ["exl"]\n[delegation]\nrestrict_to_paths = "src"/)
    assert r == {:error, :delegation_restrict_to_paths}
  end

  test "rejects non-string elements in delegation.restrict_to_paths" do
    r = BorsToml.new(~s/status = ["exl"]\n[delegation]\nrestrict_to_paths = ["ok", 42]/)
    assert r == {:error, :delegation_restrict_to_paths}
  end

  test "rejects an uncompilable glob in delegation.invalidate_on_paths" do
    # `:glob.matches/2` raises badarg on a non-terminated character class; reject
    # it at parse time so the synchronous merge-time gate can't crash on it.
    r =
      BorsToml.new(~S"""
      status = ["exl"]
      [delegation]
      invalidate_on_paths = ["src/["]
      """)

    assert r == {:error, :delegation_invalidate_on_paths}
  end

  test "rejects an uncompilable glob in delegation.restrict_to_paths" do
    r =
      BorsToml.new(~S"""
      status = ["exl"]
      [delegation]
      restrict_to_paths = ["src/["]
      """)

    assert r == {:error, :delegation_restrict_to_paths}
  end

  test "accepts valid glob patterns in the delegation path lists" do
    {:ok, toml} =
      BorsToml.new(~S"""
      status = ["exl"]
      [delegation]
      restrict_to_paths = ["src/**/*.rs", "a?b"]
      """)

    assert toml.delegation_restrict_to_paths == ["src/**/*.rs", "a?b"]
  end
end
