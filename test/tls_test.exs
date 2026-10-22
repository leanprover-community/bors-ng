defmodule BorsNG.TLSTest do
  # The OAuth test sets the app's environment.
  use ExUnit.Case, async: false

  require Record

  alias BorsNG.TLS

  Record.defrecordp(:cert, Record.extract(:cert, from_lib: "public_key/include/public_key.hrl"))

  test "the options trust the system's store" do
    opts = TLS.hackney_ssl_options()
    assert opts[:cacerts] == :public_key.cacerts_get()
    assert opts[:partial_chain] == (&TLS.partial_chain/1)
  end

  test "requests use them over HTTP/1.1, on pooled connections" do
    opts = TLS.hackney_options()
    assert opts[:ssl_options] == TLS.hackney_ssl_options()
    assert opts[:protocols] == [:http1]
    assert opts[:ssl_pooling] == true
  end

  test "hackney replaces its certifi defaults with them, and keeps its hostname check" do
    opts = :hackney_ssl.ssl_opts(~c"api.github.com", ssl_options: TLS.hackney_ssl_options())

    assert opts[:cacerts] == :public_key.cacerts_get()
    assert opts[:partial_chain] == (&TLS.partial_chain/1)
    assert opts[:verify] == :verify_peer

    assert {:verify_fun, {_, [check_hostname: ~c"api.github.com"]}} =
             List.keyfind(opts, :verify_fun, 0)

    assert opts[:server_name_indication] == ~c"api.github.com"
  end

  test "a chain that includes a root of the system's store is anchored there" do
    [cert(der: root) | _] = :public_key.cacerts_get()
    %{cert: leaf} = :public_key.pkix_test_root_cert(~c"leaf", [])

    assert TLS.partial_chain([leaf, root]) == {:trusted_ca, root}
    assert TLS.partial_chain([root, leaf]) == {:trusted_ca, root}
  end

  test "a chain with no key from the system's store is unknown" do
    %{cert: leaf} = :public_key.pkix_test_root_cert(~c"leaf", [])
    %{cert: other} = :public_key.pkix_test_root_cert(~c"other", [])

    assert TLS.partial_chain([leaf, other]) == :unknown_ca
  end

  test "the OAuth client's requests use the options" do
    Application.put_env(:bors, BorsNG.GitHub.OAuth2, client_id: "id", client_secret: "secret")
    on_exit(fn -> Application.delete_env(:bors, BorsNG.GitHub.OAuth2) end)

    request_opts = BorsNG.GitHub.OAuth2.client().request_opts

    assert Keyword.take(request_opts, Keyword.keys(TLS.hackney_options())) ==
             TLS.hackney_options()
  end
end
