defmodule OpenChatWeb.ApiExtendedTest do
  use OpenChat.HttpCase, async: false

  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "user search via API" do
    Store.upsert_user(%{"uid" => "search_1", "name" => "FindMe"})
    Store.upsert_user(%{"uid" => "search_2", "name" => "Other"})

    conn = auth_conn(:get, "/v3.0/users?search=FindMe", %{}, "uid:alice")
    assert conn.status == 200
    users = json(conn)["data"]
    assert length(users) == 1
    assert List.first(users)["name"] == "FindMe"
  end

  test "group search via API" do
    Store.upsert_group(%{"guid" => "search_g1", "name" => "HiddenGroup"})

    conn = auth_conn(:get, "/v3.0/groups?search=Hidden", %{}, "uid:alice")
    assert conn.status == 200
    groups = json(conn)["data"]
    assert length(groups) == 1
    assert List.first(groups)["name"] == "HiddenGroup"
  end

  test "DELETE /me revokes token" do
    {:ok, %{"authToken" => token}} = Store.create_auth_token("carol")

    conn = auth_conn(:delete, "/v3.0/me", %{}, token)
    assert conn.status == 200

    # Try to use it again
    conn = auth_conn(:get, "/v3.0/me", %{}, token)
    assert conn.status == 401
  end

  test "POST /user_sessions returns session info" do
    conn = auth_conn(:post, "/v3.0/user_sessions", %{"deviceId" => "device_123"}, "uid:alice")
    assert conn.status == 200
    body = json(conn)["data"]
    assert body["uid"] == "alice"
    assert body["sessionId"] == "device_123"
  end

  test "PUT /users activates users" do
    Store.delete_user("bob")
    {:ok, user} = Store.get_user("bob")
    assert user["deactivatedAt"]

    conn = admin_conn(:put, "/v3/users", %{"uidsToActivate" => ["bob"]})
    assert conn.status == 200

    {:ok, user} = Store.get_user("bob")
    refute user["deactivatedAt"]
  end

  test "GET /health returns ok" do
    conn = conn(:get, "/health") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "GET /settings returns settings" do
    conn = conn(:get, "/v3.0/settings") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 200
    body = json(conn)["data"]
    assert body["CHAT_API_VERSION"] == "v3.0"
  end
end
