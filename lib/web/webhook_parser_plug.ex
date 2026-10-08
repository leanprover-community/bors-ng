defmodule BorsNG.WebhookParserPlug do
  @moduledoc """
  Parse the GitHub webhook payload (as JSON) and verify the HMAC-SHA1 signature.
  """

  import Plug.Conn

  def init(options) do
    options
  end

  def call(conn, options) do
    if conn.path_info == ["webhook", "github"] do
      key = Keyword.get_lazy(options, :secret, &configured_secret/0)
      run(conn, options, key)
    else
      conn
    end
  end

  # Read when a webhook arrives, not when the endpoint compiles, since a build
  # (such as a Docker image) doesn't have GITHUB_WEBHOOK_SECRET. Without any
  # config (the test environment) there is no secret to check against; config
  # whose secret is unset or blank raises instead.
  defp configured_secret do
    case Application.fetch_env(:bors, __MODULE__) do
      :error ->
        nil

      {:ok, config} ->
        case config |> Confex.Resolver.resolve!() |> Keyword.get(:webhook_secret) do
          secret when is_binary(secret) and secret != "" -> secret
          _ -> raise ArgumentError, "the webhook secret (GITHUB_WEBHOOK_SECRET) is not set"
        end
    end
  end

  def run(conn, _options, nil) do
    conn
  end

  def run(conn, _options, key) do
    {:ok, body, _} = read_body(conn)

    signature =
      case get_req_header(conn, "x-hub-signature") do
        ["sha1=" <> signature | []] ->
          {:ok, signature} = Base.decode16(signature, case: :lower)
          signature

        x ->
          x
      end

    hmac = :crypto.mac(:hmac, :sha, key, body)

    case hmac do
      ^signature ->
        %Plug.Conn{conn | body_params: Jason.decode!(body)}

      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(401, "Invalid signature")
        |> halt
    end
  end
end
