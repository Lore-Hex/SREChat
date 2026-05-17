defmodule OpenChatWeb.ApiTest do
  use OpenChat.HttpCase, async: false

  test "CometChat login(authToken) wire contract: PUT /me" do
    conn = auth_conn(:put, "/v3.0/me", %{}, "uid:alice")
    assert conn.status == 200
    body = json(conn)
    assert body["data"]["uid"] == "alice"
    assert body["data"]["settings"]["CHAT_API_VERSION"] == "v3.0"
    assert body["data"]["settings"]["CHAT_HOST"] == "localhost"
  end

  test "auth accepts standard bearer tokens" do
    conn =
      conn(:get, "/v3.0/me")
      |> Plug.Conn.put_req_header("authorization", "Bearer uid:alice")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 200
    assert json(conn)["data"]["uid"] == "alice"
  end

  test "admin token generation then login" do
    conn = admin_conn(:post, "/v3/users/dave/auth_tokens")
    assert conn.status == 200
    token = json(conn)["data"]["authToken"]
    assert is_binary(token)

    conn = auth_conn(:get, "/v3.0/me", %{}, token)
    assert json(conn)["data"]["uid"] == "dave"
  end

  test "send text message, fetch previous, conversations, unread counts, mark read" do
    conn =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "type" => "text",
        "category" => "message",
        "data" => %{"text" => "hello from HTTP"}
      })

    assert conn.status in [200, 201]
    msg = json(conn)["data"]
    assert msg["data"]["text"] == "hello from HTTP"

    conn = auth_conn(:get, "/v3.0/users/alice/messages?limit=10", %{}, "uid:bob")
    assert [fetched] = json(conn)["data"]
    assert fetched["id"] == msg["id"]

    conn = auth_conn(:get, "/v3.0/messages?receiverType=user&unread=1&count=1", %{}, "uid:bob")
    assert [%{"entityId" => "alice", "count" => 1}] = json(conn)["data"]

    conn =
      auth_conn(
        :post,
        "/v3.0/users/alice/conversation/read",
        %{"messageId" => msg["id"]},
        "uid:bob"
      )

    assert conn.status == 200

    conn = auth_conn(:get, "/v3.0/conversations?conversationType=user", %{}, "uid:bob")

    assert [%{"conversationWith" => %{"uid" => "alice"}, "unreadMessageCount" => 0}] =
             json(conn)["data"]
  end

  test "DM history endpoint can hold a short SDK websocket grace period" do
    with_open_chat_env(%{dm_history_connect_grace_ms: 25}, fn ->
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "type" => "text",
        "category" => "message",
        "data" => %{"text" => "history grace"}
      })

      {elapsed_us, conn} =
        :timer.tc(fn -> auth_conn(:get, "/v3.0/users/alice/messages?limit=10", %{}, "uid:bob") end)

      assert conn.status == 200
      assert [%{"data" => %{"text" => "history grace"}}] = json(conn)["data"]
      assert elapsed_us >= 20_000
    end)
  end

  test "admin v3 routes cover TTFM server-side CometChat calls" do
    assert admin_conn(:post, "/v3/users", %{
             "uid" => "dj-1",
             "name" => "DJ One",
             "metadata" => Jason.encode!(%{"avatarId" => "10", "color" => "red"})
           }).status == 201

    assert admin_conn(:put, "/v3/users/dj-1", %{
             "name" => "DJ 1",
             "metadata" => Jason.encode!(%{"avatarId" => "11", "color" => "blue"})
           }).status == 200

    assert admin_conn(:post, "/v3/groups", %{
             "guid" => "room-1",
             "name" => "da:room-1",
             "type" => "public"
           }).status == 201

    conn =
      admin_conn(:post, "/v3/groups/room-1/members", %{
        "admins" => ["dj-1"],
        "participants" => ["alice"]
      })

    assert conn.status == 200
    assert json(conn)["data"]["uid"] == "alice" or json(conn)["data"]["uid"] == "dj-1"

    conn = admin_conn(:get, "/v3/groups/room-1/members?scope=admin,moderator")
    assert [%{"uid" => "dj-1", "role" => "admin", "scope" => "admin"}] = json(conn)["data"]

    conn =
      admin_conn(:post, "/v3/messages", %{
        "receiver" => "room-1",
        "receiverType" => "group",
        "type" => "text",
        "category" => "message",
        "data" => %{"text" => "server song"}
      })

    assert conn.status == 201
    assert json(conn)["data"]["sender"] == "system"

    assert admin_conn(:post, "/v3/groups/room-1/bannedusers/alice").status == 200
    assert [%{"uid" => "alice"}] = json(admin_conn(:get, "/v3/groups/room-1/bannedusers"))["data"]
    assert admin_conn(:delete, "/v3/groups/room-1/bannedusers/alice").status == 200
    assert admin_conn(:delete, "/v3/groups/room-1/members/dj-1").status == 200
    assert admin_conn(:delete, "/v3/conversations/room-1").status == 200
    assert admin_conn(:delete, "/v3/users/dj-1", %{"permanent" => false}).status == 200
    assert admin_conn(:put, "/v3/users", %{"uidsToActivate" => ["dj-1"]}).status == 200
  end

  test "join group and fetch group messages" do
    conn = auth_conn(:post, "/v3.0/groups/lobby/members", %{}, "uid:alice")
    assert json(conn)["data"]["guid"] == "lobby"

    conn =
      auth_conn(
        :post,
        "/v3.0/messages",
        %{
          "receiver" => "lobby",
          "receiverType" => "group",
          "type" => "text",
          "data" => %{"text" => "group hello"}
        },
        "uid:alice"
      )

    assert conn.status in [200, 201]

    conn = auth_conn(:get, "/v3.0/groups/lobby/messages?limit=10", %{}, "uid:alice")
    assert [%{"data" => %{"text" => "group hello"}}] = json(conn)["data"]
  end

  test "block, get block status, list blocked users, and unblock" do
    conn = auth_conn(:post, "/v3.0/blockedusers", %{"blockedUids" => ["bob"]}, "uid:alice")
    assert conn.status == 200
    assert json(conn)["data"]["bob"]["success"]

    conn = auth_conn(:get, "/v3.0/users/bob", %{}, "uid:alice")
    assert json(conn)["data"]["blockedByMe"] == true
    assert json(conn)["data"]["hasBlockedMe"] == false

    conn = auth_conn(:get, "/v3.0/users/alice", %{}, "uid:bob")
    assert json(conn)["data"]["blockedByMe"] == false
    assert json(conn)["data"]["hasBlockedMe"] == true

    conn =
      auth_conn(:get, "/v3.0/blockedusers?direction=blockedByMe&per_page=100", %{}, "uid:alice")

    assert [%{"uid" => "bob", "blockedByMe" => true}] = json(conn)["data"]
    assert get_in(json(conn), ["meta", "pagination", "total"]) == 1

    conn = auth_conn(:delete, "/v3.0/blockedusers", %{"blockedUids" => ["bob"]}, "uid:alice")
    assert conn.status == 200

    conn =
      auth_conn(:get, "/v3.0/blockedusers?direction=blockedByMe&per_page=100", %{}, "uid:alice")

    assert json(conn)["data"] == []
  end

  test "custom message, reaction extension fallback, edit and delete" do
    conn =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "type" => "custom",
        "category" => "message",
        "data" => %{"customData" => %{"type" => "poll"}}
      })

    msg = json(conn)["data"]

    conn = auth_conn(:post, "/v3.0/messages/#{msg["id"]}/reactions/%F0%9F%91%8D", %{}, "uid:bob")
    reacted = json(conn)["data"]
    assert [%{"reaction" => "👍", "count" => 1}] = reacted["data"]["reactions"]

    conn =
      auth_conn(:put, "/v3.0/messages/#{msg["id"]}", %{
        "data" => %{"customData" => %{"type" => "poll-edited"}}
      })

    action = json(conn)["data"]
    assert action["category"] == "action"
    assert action["data"]["action"] == "edited"

    conn = auth_conn(:delete, "/v3.0/messages/#{msg["id"]}")
    action = json(conn)["data"]
    assert action["data"]["action"] == "deleted"
  end

  defp with_open_chat_env(overrides, fun) do
    previous =
      Map.new(overrides, fn {key, _value} ->
        {key, Application.get_env(:open_chat, key)}
      end)

    Enum.each(overrides, fn {key, value} ->
      Application.put_env(:open_chat, key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:open_chat, key)
        {key, value} -> Application.put_env(:open_chat, key, value)
      end)
    end
  end
end
