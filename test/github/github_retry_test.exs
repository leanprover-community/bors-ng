defmodule BorsNG.GitHubRetryTest do
  use ExUnit.Case

  alias BorsNG.GitHub

  setup do
    old_timeout = Application.get_env(:bors, :api_github_timeout)
    Application.put_env(:bors, :api_github_timeout, 10)

    on_exit(fn ->
      Application.put_env(:bors, :api_github_timeout, old_timeout)
    end)

    :ok
  end

  test "get_file returns timeout error instead of crashing caller when GitHub server is stalled" do
    :sys.suspend(BorsNG.GitHub)

    on_exit(fn ->
      :sys.resume(BorsNG.GitHub)
    end)

    assert {:error, :github_call_timeout, :get_file} =
             GitHub.get_file({{:installation, 91}, 14}, "deadbeef", "bors.toml")
  end

  test "get_pr returns timeout error instead of crashing caller when GitHub server is stalled" do
    :sys.suspend(BorsNG.GitHub)

    on_exit(fn ->
      :sys.resume(BorsNG.GitHub)
    end)

    assert {:error, :github_call_timeout, :get_pr} = GitHub.get_pr({{:installation, 91}, 14}, 1)
  end

  test "get_pr_files returns timeout error instead of crashing caller when GitHub server is stalled" do
    :sys.suspend(BorsNG.GitHub)

    on_exit(fn ->
      :sys.resume(BorsNG.GitHub)
    end)

    assert {:error, :github_call_timeout, :get_pr_files} =
             GitHub.get_pr_files({{:installation, 91}, 14}, 1)
  end

  test "get_file! remains non-crashing when call times out" do
    :sys.suspend(BorsNG.GitHub)

    on_exit(fn ->
      :sys.resume(BorsNG.GitHub)
    end)

    assert nil == GitHub.get_file!({{:installation, 91}, 14}, "deadbeef", "bors.toml")
  end

  test "wrappers return server unavailable errors when GitHub server name is not registered" do
    github_pid = Process.whereis(BorsNG.GitHub)
    true = Process.unregister(BorsNG.GitHub)

    on_exit(fn ->
      if is_pid(github_pid) and Process.alive?(github_pid) and
           is_nil(Process.whereis(BorsNG.GitHub)) do
        Process.register(github_pid, BorsNG.GitHub)
      end
    end)

    assert {:error, :github_server_unavailable, :get_file} =
             GitHub.get_file({{:installation, 91}, 14}, "deadbeef", "bors.toml")

    assert {:error, :github_server_unavailable, :get_pr} =
             GitHub.get_pr({{:installation, 91}, 14}, 1)
  end
end
