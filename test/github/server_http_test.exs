defmodule BorsNG.GitHub.ServerHttpTest do
  use ExUnit.Case, async: false

  defmodule ScenarioPlug do
    import Plug.Conn

    @status_path "/repositories/1/commits/sha/status"
    @checks_path "/repositories/1/commits/sha/check-runs"
    @scenario_key {__MODULE__, :scenario}
    @base_url_key {__MODULE__, :base_url}

    def init(opts), do: opts

    def set_scenario(scenario), do: :persistent_term.put(@scenario_key, scenario)
    def set_base_url(base_url), do: :persistent_term.put(@base_url_key, base_url)

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      scenario = :persistent_term.get(@scenario_key, :both_non_200)
      base_url = :persistent_term.get(@base_url_key, "http://localhost")

      case {scenario, conn.method, conn.request_path} do
        {:both_non_200, "GET", @status_path} ->
          reply(conn, 500, "oops")

        {:both_non_200, "GET", @checks_path} ->
          reply(conn, 500, "oops")

        {:malformed_status_json, "GET", @status_path} ->
          reply(conn, 200, "not json")

        {:malformed_status_json, "GET", @checks_path} ->
          reply(conn, 200, ~s({"check_runs":[]}))

        {:statuses_non_200_checks_ok, "GET", @status_path} ->
          reply(conn, 500, "oops")

        {:statuses_non_200_checks_ok, "GET", @checks_path} ->
          reply(conn, 200, ~s({"check_runs":[{"name":"check-only","conclusion":"success"}]}))

        {:statuses_ok_checks_non_200, "GET", @status_path} ->
          reply(conn, 200, ~s({"statuses":[{"context":"status-only","state":"success"}]}))

        {:statuses_ok_checks_non_200, "GET", @checks_path} ->
          reply(conn, 500, "oops")

        {:checks_pagination, "GET", @status_path} ->
          reply(conn, 500, "oops")

        {:checks_pagination, "GET", @checks_path} ->
          case conn.params["page"] do
            "2" ->
              reply(conn, 200, ~s({"check_runs":[{"name":"second-page","conclusion":"failure"}]}))

            _ ->
              next = "<#{base_url}/repositories/1/commits/sha/check-runs?page=2>; rel=\"next\""

              reply(
                conn,
                200,
                ~s({"check_runs":[{"name":"first-page","conclusion":"success"}]}),
                [{"link", next}]
              )
          end

        _ ->
          reply(conn, 404, "not found")
      end
    end

    defp reply(conn, status, body, headers \\ []) do
      conn =
        Enum.reduce(headers, conn, fn {k, v}, c ->
          put_resp_header(c, k, v)
        end)

      resp(conn, status, body)
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)
    ref = make_ref()

    {:ok, _pid} =
      Plug.Cowboy.http(
        ScenarioPlug,
        [],
        port: 0,
        ref: ref
      )

    port = :ranch.get_port(ref)
    base_url = "http://localhost:#{port}"
    original_api_root = Application.get_env(:bors, :api_github_root)

    Application.put_env(:bors, :api_github_root, base_url)
    ScenarioPlug.set_base_url(base_url)
    ScenarioPlug.set_scenario(:both_non_200)

    on_exit(fn ->
      Application.put_env(:bors, :api_github_root, original_api_root)
      Plug.Cowboy.shutdown(ref)
    end)

    :ok
  end

  test "get_commit_status returns empty map when GitHub returns non-200" do
    ScenarioPlug.set_scenario(:both_non_200)

    assert {:ok, %{}} = get_commit_status()
  end

  test "get_commit_status still raises for malformed JSON in a 200 response" do
    ScenarioPlug.set_scenario(:malformed_status_json)

    assert_raise Jason.DecodeError, fn ->
      get_commit_status()
    end
  end

  test "get_commit_status keeps checks when statuses endpoint is non-200" do
    ScenarioPlug.set_scenario(:statuses_non_200_checks_ok)

    assert {:ok, statuses} = get_commit_status()
    assert Map.has_key?(statuses, "check-only")
  end

  test "get_commit_status keeps statuses when checks endpoint is non-200" do
    ScenarioPlug.set_scenario(:statuses_ok_checks_non_200)

    assert {:ok, statuses} = get_commit_status()
    assert Map.has_key?(statuses, "status-only")
  end

  test "get_commit_status follows pagination links for check-runs" do
    ScenarioPlug.set_scenario(:checks_pagination)

    assert {:ok, statuses} = get_commit_status()
    assert Map.has_key?(statuses, "first-page")
    assert Map.has_key?(statuses, "second-page")
  end

  defp get_commit_status do
    BorsNG.GitHub.Server.do_handle_call(
      :get_commit_status,
      {{:raw, "token"}, 1},
      {"sha"}
    )
  end
end
