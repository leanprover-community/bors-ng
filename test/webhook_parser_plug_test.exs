defmodule BorsNG.WebhookParserPlugTest do
  # Changes the application and system environment, so not async.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias BorsNG.WebhookParserPlug

  @env_var "BORS_TEST_WEBHOOK_SECRET"
  @body ~s({"action":"opened"})

  setup do
    previous = Application.fetch_env(:bors, WebhookParserPlug)
    Application.put_env(:bors, WebhookParserPlug, webhook_secret: {:system, @env_var})
    System.put_env(@env_var, "s3cret")

    on_exit(fn ->
      System.delete_env(@env_var)

      case previous do
        {:ok, config} -> Application.put_env(:bors, WebhookParserPlug, config)
        :error -> Application.delete_env(:bors, WebhookParserPlug)
      end
    end)
  end

  defp webhook(signature_header) do
    conn = conn(:post, "/webhook/github", @body)

    case signature_header do
      nil -> conn
      header -> put_req_header(conn, "x-hub-signature", header)
    end
    |> WebhookParserPlug.call(WebhookParserPlug.init([]))
  end

  defp sign(key, body) do
    "sha1=" <> Base.encode16(:crypto.mac(:hmac, :sha, key, body), case: :lower)
  end

  test "reads the secret when the request arrives" do
    conn = webhook(sign("s3cret", @body))
    refute conn.halted
    assert conn.body_params == %{"action" => "opened"}
  end

  test "refuses a wrong signature" do
    conn = webhook(sign("guess", @body))
    assert conn.halted
    assert conn.status == 401
  end

  test "refuses a request without a signature" do
    conn = webhook(nil)
    assert conn.halted
    assert conn.status == 401
  end

  test "raises when the secret is configured but not set" do
    System.delete_env(@env_var)
    assert_raise ArgumentError, fn -> webhook(sign("", @body)) end
  end

  test "raises when the secret is blank" do
    System.put_env(@env_var, "")
    assert_raise ArgumentError, fn -> webhook(sign("", @body)) end
  end

  test "checks nothing when there is no config, as in tests" do
    Application.delete_env(:bors, WebhookParserPlug)
    refute webhook(nil).halted
  end

  test "leaves other paths alone" do
    System.delete_env(@env_var)

    conn =
      conn(:post, "/repositories", @body)
      |> WebhookParserPlug.call(WebhookParserPlug.init([]))

    refute conn.halted
  end
end
