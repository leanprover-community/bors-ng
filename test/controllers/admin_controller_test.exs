defmodule BorsNG.AdminControllerTest do
  use BorsNG.ConnCase

  alias BorsNG.Database.Repo
  alias BorsNG.Database.User

  setup do
    # The mock GitHub login authenticates as user_xref 23; pre-create that
    # user as an admin so the requests reach the admin-only routes.
    user =
      Repo.insert!(%User{
        user_xref: 23,
        login: "ghost",
        is_admin: true
      })

    {:ok, user: user}
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

  test "need to log in to see this", %{conn: conn} do
    conn = get(conn, "/admin/crashes?days=1")
    assert html_response(conn, 302) =~ "auth"
  end

  test "shows the crashes for a valid days parameter", %{conn: conn} do
    conn = login(conn)
    conn = get(conn, "/admin/crashes?days=7")

    assert html_response(conn, 200) =~ "Crashes in last 7 days"
  end

  test "returns 400 for a non-integer days parameter", %{conn: conn} do
    conn = login(conn)
    conn = get(conn, "/admin/crashes?days=abc")

    assert response(conn, 400)
  end

  test "returns 400 when the days parameter is missing", %{conn: conn} do
    conn = login(conn)
    conn = get(conn, "/admin/crashes")

    assert response(conn, 400)
  end
end
