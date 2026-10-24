defmodule BorsNG.UserSocketTest do
  use BorsNG.ChannelCase

  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
  alias BorsNG.UserSocket

  test "connects with a token signed for the user" do
    user = Repo.insert!(%User{user_xref: 23, login: "space"})
    token = Phoenix.Token.sign(@endpoint, "channel:current_user", user.id)

    assert {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert socket.assigns.user.id == user.id
  end

  test "refuses a token it didn't sign" do
    assert :error = connect(UserSocket, %{"token" => "not-a-token"})
  end

  # A query string such as `?token[]=x` makes the token a list. plug_crypto
  # before 2.2.1 raised a FunctionClauseError for it, whose stack frame holds
  # the endpoint's secret key base, so the error log would show it.
  test "refuses a token that isn't a string" do
    assert :error = connect(UserSocket, %{"token" => ["x"]})
    assert :error = connect(UserSocket, %{"token" => %{"a" => "b"}})
  end
end
