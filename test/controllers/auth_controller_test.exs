defmodule BorsNG.AuthControllerTest do
  use BorsNG.ConnCase

  alias BorsNG.Database.Repo
  alias BorsNG.Database.User

  setup do
    # The mock GitHub login authenticates as "space", user_xref 23.
    space = Repo.insert!(%User{user_xref: 23, login: "space"})
    ada = Repo.insert!(%User{user_xref: 42, login: "ada"})

    {:ok, space: space, ada: ada}
  end

  def login(conn) do
    conn = get(conn, auth_path(conn, :index, "github"))
    assert html_response(conn, 302) =~ "MOCK_GITHUB_AUTHORIZE_URL"

    conn =
      get(
        conn,
        auth_path(
          conn,
          :callback,
          "github",
          %{"code" => "MOCK_GITHUB_AUTHORIZE_CODE"}
        )
      )

    html_response(conn, 302)
    conn
  end

  defp assert_signed_out(conn) do
    assert redirected_to(conn) == "/auth/github"

    for key <- [:current_user, :current_user_xref, :avatar_url, :github_access_token] do
      assert is_nil(get_session(conn, key)), "#{key} is still in the session"
    end
  end

  test "a login stores the user's row and GitHub user ID", %{conn: conn, space: space} do
    conn = login(conn)
    assert get_session(conn, :current_user) == space.id
    assert get_session(conn, :current_user_xref) == 23

    conn = get(conn, "/repositories")
    assert html_response(conn, 200) =~ "space ▾"
  end

  test "a session whose row belongs to another GitHub user is signed out", %{
    conn: conn,
    ada: ada
  } do
    # As after a restore: the cookie names space's GitHub user, but the row
    # ID it got is ada's in this database.
    conn =
      conn
      |> init_test_session(
        current_user: ada.id,
        current_user_xref: 23,
        avatar_url: "https://example.com/space.png",
        github_access_token: "token"
      )
      |> get("/repositories")

    assert_signed_out(conn)
    assert get_session(conn, :auth_redirect_to) == "/repositories"
  end

  test "a session without a GitHub user ID is signed out", %{conn: conn, space: space} do
    conn =
      conn
      |> init_test_session(current_user: space.id, avatar_url: "https://example.com/space.png")
      |> get("/repositories")

    assert_signed_out(conn)
  end

  test "a session whose row is gone is signed out", %{conn: conn, space: space} do
    conn =
      conn
      |> init_test_session(current_user: space.id + 1000, current_user_xref: 23)
      |> get("/repositories")

    assert_signed_out(conn)
  end

  test "logging in again after being signed out names the right row", %{
    conn: conn,
    space: space,
    ada: ada
  } do
    conn =
      conn
      |> init_test_session(current_user: ada.id, current_user_xref: 23)
      |> get("/repositories")

    assert_signed_out(conn)

    conn = login(conn)
    assert get_session(conn, :current_user) == space.id

    conn = get(conn, "/repositories")
    assert html_response(conn, 200) =~ "space ▾"
  end
end
