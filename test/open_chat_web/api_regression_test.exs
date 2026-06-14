defmodule OpenChatWeb.ApiRegressionTest do
  use OpenChat.HttpCase, async: false

  test "auth, admin, route fallback, and CORS failures are explicit" do
    conn = conn(:get, "/health") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body == "ok"

    conn = conn(:get, "/v3.0/users") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 401
    assert json(conn)["error"]["code"] == "ERR_NO_AUTH"

    conn =
      conn(:post, "/v3/users", Jason.encode!(%{"uid" => "mallory"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("apikey", "wrong-key")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 403
    assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"

    conn = admin_conn(:post, "/v3/admin/users/auth", %{})
    assert conn.status == 400
    assert json(conn)["error"]["code"] == "MISSING_PARAMETERS"

    conn = conn(:get, "/v3.0/does-not-exist") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 404
    assert json(conn)["error"]["code"] == "ERR_ROUTE_NOT_FOUND"

    conn = conn(:delete, "/v3.0/me") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 401
    assert json(conn)["error"]["code"] == "ERR_NO_AUTH"

    conn = conn(:options, "/v3.0/users") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 204
    assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "blank configured admin api key does not open admin routes" do
    old_api_key = Application.get_env(:open_chat, :api_key)
    Application.put_env(:open_chat, :api_key, "")

    on_exit(fn ->
      Application.put_env(:open_chat, :api_key, old_api_key)
    end)

    conn =
      conn(:post, "/v3/users", Jason.encode!(%{"uid" => "blank-key-admin"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 403
    assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"
  end

  test "CORS origin allowlist can be restricted" do
    old_allowed_origins = Application.get_env(:open_chat, :cors_allowed_origins)
    Application.put_env(:open_chat, :cors_allowed_origins, "https://chat.example")

    on_exit(fn ->
      Application.put_env(:open_chat, :cors_allowed_origins, old_allowed_origins)
    end)

    allowed =
      conn(:options, "/v3.0/users")
      |> Plug.Conn.put_req_header("origin", "https://chat.example")
      |> OpenChatWeb.Endpoint.call([])

    assert allowed.status == 204

    assert Plug.Conn.get_resp_header(allowed, "access-control-allow-origin") == [
             "https://chat.example"
           ]

    assert Plug.Conn.get_resp_header(allowed, "x-content-type-options") == ["nosniff"]
    assert Plug.Conn.get_resp_header(allowed, "x-frame-options") == ["DENY"]
    assert Plug.Conn.get_resp_header(allowed, "referrer-policy") == ["no-referrer"]

    denied =
      conn(:options, "/v3.0/users")
      |> Plug.Conn.put_req_header("origin", "https://evil.example")
      |> OpenChatWeb.Endpoint.call([])

    assert denied.status == 204
    assert Plug.Conn.get_resp_header(denied, "access-control-allow-origin") == []
  end

  test "REST message mutations propagate SDK resource header to socket deviceId" do
    assert {:ok, _} = OpenChat.PubSub.subscribe({:user, "alice"})
    assert {:ok, _} = OpenChat.PubSub.subscribe({:user, "bob"})

    on_exit(fn ->
      OpenChat.PubSub.unsubscribe({:user, "alice"})
      OpenChat.PubSub.unsubscribe({:user, "bob"})
    end)

    conn =
      conn(
        :post,
        "/v3.0/messages",
        Jason.encode!(%{
          "receiver" => "bob",
          "receiverType" => "user",
          "data" => %{"text" => "resource header"}
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authtoken", "uid:alice")
      |> Plug.Conn.put_req_header("resource", "rn-session-123")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 201
    message = json(conn)["data"]

    assert_receive {:comet_event,
                    %{
                      "type" => "message",
                      "deviceId" => "rn-session-123",
                      "body" => %{"id" => id}
                    }}

    assert id == message["id"]

    conn =
      conn(
        :post,
        "/v3.0/messages/#{message["id"]}/reactions/%F0%9F%91%8D",
        Jason.encode!(%{})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authtoken", "uid:bob")
      |> Plug.Conn.put_req_header("resource", "web-session-456")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 200

    assert_receive {:comet_event,
                    %{
                      "type" => "message",
                      "deviceId" => "web-session-456",
                      "body" => %{"category" => "action"}
                    }}

    assert_receive {:comet_event,
                    %{
                      "type" => "reaction",
                      "deviceId" => "web-session-456",
                      "body" => %{"messageId" => ^id}
                    }}
  end

  test "user admin and client routes support search, pagination, update, delete, and reactivation" do
    for uid <- ["test-a", "test-b", "test-c"] do
      assert admin_conn(:post, "/v3/users", %{"uid" => uid, "name" => "Search #{uid}"}).status ==
               201
    end

    conn = auth_conn(:get, "/v3.0/users?search=test-&limit=2&page=2")
    assert [%{"uid" => "test-c"}] = json(conn)["data"]

    conn =
      admin_conn(:put, "/v3/users/test-a", %{
        "name" => "Test A Updated",
        "metadata" => Jason.encode!(%{"avatarId" => "12"})
      })

    assert conn.status == 200
    assert json(conn)["data"]["metadata"] == %{"avatarId" => "12"}

    conn = auth_conn(:get, "/v3.0/users/test-a")
    assert json(conn)["data"]["name"] == "Test A Updated"

    assert admin_conn(:delete, "/v3/users/test-a").status == 200
    assert admin_conn(:put, "/v3/users", %{"uidsToActivate" => ["test-a"]}).status == 200

    conn = auth_conn(:get, "/v3.0/users/test-a")
    assert json(conn)["data"]["status"] == "available"
  end

  test "group APIs enforce join rules, scope filters, and admin-only single member mutations" do
    assert admin_conn(:post, "/v3/groups", %{
             "guid" => "api-private",
             "type" => "private"
           }).status == 201

    conn = auth_conn(:post, "/v3.0/groups/api-private/members", %{}, "uid:alice")
    assert conn.status == 400
    assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"

    create_password =
      admin_conn(:post, "/v3/groups", %{
        "guid" => "api-password",
        "type" => "password",
        "password" => "secret"
      })

    assert create_password.status == 201
    refute Map.has_key?(json(create_password)["data"], "password")

    get_password = auth_conn(:get, "/v3.0/groups/api-password", %{}, "uid:alice")
    assert get_password.status == 200
    refute Map.has_key?(json(get_password)["data"], "password")

    conn = auth_conn(:post, "/v3.0/groups/api-password/members", %{"password" => "wrong"})
    assert conn.status == 400
    assert json(conn)["error"]["code"] == "INVALID_PASSWORD"

    conn = auth_conn(:post, "/v3.0/groups/api-password/members", %{"password" => "secret"})
    assert conn.status == 200
    assert json(conn)["data"]["hasJoined"] == true
    refute Map.has_key?(json(conn)["data"], "password")

    assert admin_conn(:post, "/v3/groups", %{"guid" => "api-scopes", "type" => "public"}).status ==
             201

    assert admin_conn(:post, "/v3/groups/api-scopes/members", %{
             "participants" => ["alice"],
             "moderators" => ["bob"],
             "admins" => ["carol"]
           }).status == 200

    conn = admin_conn(:get, "/v3/groups/api-scopes/members?scope=admin,moderator")

    assert Enum.map(json(conn)["data"], &{&1["uid"], &1["scope"]}) == [
             {"bob", "moderator"},
             {"carol", "admin"}
           ]

    conn =
      conn(:delete, "/v3/groups/api-scopes/members/bob")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 403

    assert admin_conn(:delete, "/v3/groups/api-scopes/members/bob").status == 200

    assert admin_conn(:put, "/v3/groups/api-scopes/members/bob", %{"scope" => "moderator"}).status ==
             200

    assert admin_conn(:post, "/v3/groups", %{"guid" => "api-delete", "name" => "Delete Me"}).status ==
             201

    assert admin_conn(:post, "/v3/groups/api-delete/members", %{"participants" => ["alice"]}).status ==
             200

    assert auth_conn(
             :post,
             "/v3.0/messages",
             %{
               "receiver" => "api-delete",
               "receiverType" => "group",
               "data" => %{"text" => "delete group message"}
             },
             "uid:alice"
           ).status == 201

    assert admin_conn(:delete, "/v3/groups/api-delete").status == 200

    conn = auth_conn(:get, "/v3.0/groups/api-delete")
    assert conn.status == 404
    assert json(conn)["error"]["code"] == "ERR_GUID_NOT_FOUND"

    conn = auth_conn(:get, "/v3.0/groups/api-delete/messages", %{}, "uid:alice")
    assert conn.status == 400
    assert json(conn)["error"]["code"] == "ERR_NOT_A_MEMBER"
  end

  test "text message metadata is exposed for the Hangout history converter" do
    room = "api-metadata-room"

    assert admin_conn(:post, "/v3/groups", %{"guid" => room, "type" => "public"}).status == 201
    assert auth_conn(:post, "/v3.0/groups/#{room}/members", %{}, "uid:alice").status == 200

    metadata = %{
      "recipientUuid" => room,
      "chatMessage" => %{
        "uuid" => "api-metadata-chat-uuid",
        "message" => "metadata text",
        "type" => "user",
        "userName" => "Alice",
        "userUuid" => "alice"
      }
    }

    conn =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => room,
        "receiverType" => "group",
        "type" => "text",
        "category" => "message",
        "data" => %{
          "text" => "metadata text",
          "metadata" => metadata
        }
      })

    assert conn.status == 201
    sent = json(conn)["data"]
    assert get_in(sent, ["data", "metadata", "chatMessage", "message"]) == "metadata text"
    assert get_in(sent, ["metadata", "chatMessage", "message"]) == "metadata text"

    conn =
      auth_conn(
        :get,
        "/v3.0/groups/#{room}/messages?limit=10&timestamp=#{System.system_time(:millisecond)}",
        %{},
        "uid:alice"
      )

    assert conn.status == 200
    [history] = json(conn)["data"]
    assert get_in(history, ["data", "metadata", "chatMessage", "message"]) == "metadata text"
    assert get_in(history, ["metadata", "chatMessage", "message"]) == "metadata text"
  end

  test "group member write APIs require owner or moderator privileges for user tokens" do
    assert admin_conn(:post, "/v3/groups", %{
             "guid" => "api-member-security",
             "type" => "public",
             "ownerUid" => "api-owner"
           }).status == 201

    assert admin_conn(:post, "/v3/groups/api-member-security/members", %{
             "participants" => ["api-participant"],
             "moderators" => ["api-moderator"]
           }).status == 200

    conn =
      auth_conn(
        :put,
        "/v3.0/groups/api-member-security/members",
        %{"uids" => ["api-victim"], "scope" => "admin"},
        "uid:api-participant"
      )

    assert conn.status == 403
    assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"

    conn = admin_conn(:get, "/v3/groups/api-member-security/members?scope=admin")
    refute Enum.any?(json(conn)["data"], &(&1["uid"] == "api-victim"))

    conn =
      auth_conn(
        :put,
        "/v3.0/groups/api-member-security/members",
        %{"uids" => ["api-owner-added"], "scope" => "participant"},
        "uid:api-owner"
      )

    assert conn.status == 200

    conn =
      auth_conn(
        :put,
        "/v3.0/groups/api-member-security/members",
        %{"uids" => ["api-mod-added"], "scope" => "participant"},
        "uid:api-moderator"
      )

    assert conn.status == 200

    conn = admin_conn(:get, "/v3/groups/api-member-security/members")
    uids = Enum.map(json(conn)["data"], & &1["uid"])
    assert "api-owner-added" in uids
    assert "api-mod-added" in uids
  end

  test "message APIs cover errors, thread fetches, muid lookup, cursor metadata, and unread rewind" do
    conn = auth_conn(:post, "/v3.0/messages", %{"receiverType" => "user"})
    assert conn.status == 400
    assert json(conn)["error"]["code"] == "MISSING_PARAMETERS"

    parent =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "muid" => "api-muid",
        "type" => "text",
        "data" => %{"text" => "parent"}
      })
      |> json()
      |> get_in(["data"])

    reply =
      auth_conn(
        :post,
        "/v3.0/messages/#{parent["id"]}/thread",
        %{
          "receiver" => "alice",
          "receiverType" => "user",
          "type" => "text",
          "data" => %{"text" => "reply"}
        },
        "uid:bob"
      )
      |> json()
      |> get_in(["data"])

    conn = auth_conn(:get, "/v3.0/messages/#{parent["id"]}/thread", %{}, "uid:alice")
    assert [%{"id" => reply_id}] = json(conn)["data"]
    assert reply_id == reply["id"]

    conn = auth_conn(:get, "/v3.0/user/messages/api-muid")
    assert json(conn)["data"]["id"] == parent["id"]

    conn = auth_conn(:get, "/v3.0/users/alice/messages?limit=1", %{}, "uid:bob")
    assert [%{"id" => fetched_id}] = json(conn)["data"]
    assert fetched_id == reply["id"]
    assert get_in(json(conn), ["meta", "cursor", "id"]) == reply["id"]

    assert auth_conn(
             :post,
             "/v3.0/users/alice/conversation/read",
             %{"messageId" => parent["id"]},
             "uid:bob"
           ).status == 200

    conn =
      auth_conn(
        :delete,
        "/v3.0/users/alice/conversation/read",
        %{"messageId" => parent["id"]},
        "uid:bob"
      )

    assert get_in(json(conn), ["data", "conversation", "lastReadMessageId"]) == "0"

    conn = auth_conn(:get, "/v3.0/messages?receiverType=user&unread=1&count=1", %{}, "uid:bob")
    assert [%{"entityId" => "alice", "count" => 1}] = json(conn)["data"]
  end

  test "message history wire order matches CometChat fetchPrevious expectations" do
    sent =
      for text <- ["wire order a", "wire order b", "wire order c"] do
        auth_conn(:post, "/v3.0/messages", %{
          "receiver" => "bob",
          "receiverType" => "user",
          "type" => "text",
          "data" => %{"text" => text}
        })
        |> json()
        |> get_in(["data"])
      end

    [first, second, third] = sent

    conn =
      auth_conn(
        :get,
        "/v3.0/users/alice/messages?limit=10&timestamp=#{System.system_time(:millisecond)}",
        %{},
        "uid:bob"
      )

    assert Enum.map(json(conn)["data"], &get_in(&1, ["data", "text"])) == [
             "wire order a",
             "wire order b",
             "wire order c"
           ]

    assert get_in(json(conn), ["meta", "cursor", "id"]) == first["id"]

    conn = auth_conn(:get, "/v3.0/users/alice/messages?limit=2", %{}, "uid:bob")

    assert Enum.map(json(conn)["data"], &get_in(&1, ["data", "text"])) == [
             "wire order b",
             "wire order c"
           ]

    assert get_in(json(conn), ["meta", "cursor", "id"]) == second["id"]
    assert get_in(json(conn), ["meta", "pagination", "total_pages"]) == 2

    conn =
      auth_conn(
        :get,
        "/v3.0/users/alice/messages?limit=2&id=#{second["id"]}",
        %{},
        "uid:bob"
      )

    assert Enum.map(json(conn)["data"], &get_in(&1, ["data", "text"])) == [
             "wire order a"
           ]

    assert get_in(json(conn), ["meta", "pagination", "total_pages"]) == 1
    assert third["id"] > second["id"]
  end

  test "message read, thread, reaction, and receipt APIs enforce participant privacy" do
    parent =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "muid" => "api-private-muid",
        "data" => %{"text" => "private"}
      })
      |> json()
      |> get_in(["data"])

    for {method, path, body} <- [
          {:get, "/v3.0/messages/#{parent["id"]}", %{}},
          {:get, "/v3.0/user/messages/api-private-muid", %{}},
          {:get, "/v3.0/messages/#{parent["id"]}/thread", %{}},
          {:get, "/v3.0/messages/#{parent["id"]}/reactions", %{}},
          {:post, "/v3.0/messages/#{parent["id"]}/reactions/%F0%9F%91%8D", %{}},
          {:post, "/v3.0/users/alice/conversation/read", %{"messageId" => parent["id"]}},
          {:post, "/v3.0/users/alice/conversation/delivered", %{"messageId" => parent["id"]}}
        ] do
      conn = auth_conn(method, path, body, "uid:carol")
      assert conn.status == 403
      assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"
    end

    conn =
      auth_conn(
        :post,
        "/v3.0/messages/#{parent["id"]}/thread",
        %{
          "receiver" => "alice",
          "receiverType" => "user",
          "data" => %{"text" => "bad thread"}
        },
        "uid:carol"
      )

    assert conn.status == 403
    assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"

    assert auth_conn(:get, "/v3.0/messages/#{parent["id"]}", %{}, "uid:bob").status == 200
  end

  test "conversation APIs forbid group nonmembers and mismatched receipt targets" do
    assert admin_conn(:post, "/v3/groups", %{
             "guid" => "api-policy-room",
             "type" => "public"
           }).status == 201

    assert admin_conn(:post, "/v3/groups/api-policy-room/members", %{
             "participants" => ["alice", "bob"]
           }).status == 200

    group_message =
      auth_conn(
        :post,
        "/v3.0/messages",
        %{
          "receiver" => "api-policy-room",
          "receiverType" => "group",
          "data" => %{"text" => "group-private"}
        },
        "uid:alice"
      )
      |> json()
      |> get_in(["data"])

    for {method, path, body} <- [
          {:get, "/v3.0/groups/api-policy-room/conversation", %{}},
          {:delete, "/v3.0/groups/api-policy-room/conversation", %{}},
          {:post, "/v3.0/groups/api-policy-room/conversation/read",
           %{"messageId" => group_message["id"]}},
          {:delete, "/v3.0/groups/api-policy-room/conversation/read",
           %{"messageId" => group_message["id"]}},
          {:post, "/v3.0/groups/api-policy-room/conversation/delivered",
           %{"messageId" => group_message["id"]}}
        ] do
      conn = auth_conn(method, path, body, "uid:carol")
      assert conn.status == 403
      assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"
    end

    assert auth_conn(:get, "/v3.0/groups/api-policy-room/conversation", %{}, "uid:bob").status ==
             200

    direct_message =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "direct-private"}
      })
      |> json()
      |> get_in(["data"])

    for {method, path} <- [
          {:post, "/v3.0/users/carol/conversation/read"},
          {:delete, "/v3.0/users/carol/conversation/read"},
          {:post, "/v3.0/users/carol/conversation/delivered"}
        ] do
      conn = auth_conn(method, path, %{"messageId" => direct_message["id"]}, "uid:alice")
      assert conn.status == 403
      assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"
    end
  end

  test "native and extension reaction routes support list, filter, add, and remove" do
    message =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "reactable"}
      })
      |> json()
      |> get_in(["data"])

    conn =
      auth_conn(:post, "/v3.0/messages/#{message["id"]}/reactions/%F0%9F%91%8D", %{}, "uid:bob")

    assert [%{"reaction" => "👍", "count" => 1}] =
             get_in(json(conn), ["data", "data", "reactions"])

    assert get_in(json(conn), [
             "data",
             "data",
             "metadata",
             "@injected",
             "extensions",
             "reactions",
             "👍",
             "bob",
             "name"
           ]) == "Bob Example"

    conn = auth_conn(:get, "/v3.0/messages/#{message["id"]}/reactions", %{}, "uid:bob")
    assert [%{"uid" => "bob", "reaction" => "👍", "reactedByMe" => true}] = json(conn)["data"]

    for reaction <- ["😎", "🎉"] do
      auth_conn(
        :post,
        "/v3.0/messages/#{message["id"]}/reactions/#{URI.encode(reaction)}",
        %{},
        "uid:bob"
      )
    end

    conn = auth_conn(:get, "/v3.0/messages/#{message["id"]}/reactions?limit=2", %{}, "uid:bob")
    first_page = json(conn)
    assert length(first_page["data"]) == 2
    assert get_in(first_page, ["meta", "previous", "cursorField"]) == "id"

    cursor = get_in(first_page, ["meta", "previous", "cursorValue"])

    conn =
      auth_conn(
        :get,
        "/v3.0/messages/#{message["id"]}/reactions?limit=2&cursorField=id&cursorValue=#{cursor}&cursorAffix=prepend",
        %{},
        "uid:bob"
      )

    second_page = json(conn)
    assert [%{}] = second_page["data"]
    second_cursor = get_in(second_page, ["meta", "previous", "cursorValue"])

    conn =
      auth_conn(
        :get,
        "/v3.0/messages/#{message["id"]}/reactions?limit=2&cursorField=id&cursorValue=#{second_cursor}&cursorAffix=prepend",
        %{},
        "uid:bob"
      )

    assert json(conn)["data"] == []

    conn =
      auth_conn(
        :get,
        "/v3.0/messages/#{message["id"]}/reactions?limit=2&cursorAffix=append",
        %{},
        "uid:bob"
      )

    append_first = json(conn)
    assert length(append_first["data"]) == 2
    append_cursor = get_in(append_first, ["meta", "next", "cursorValue"])

    conn =
      auth_conn(
        :get,
        "/v3.0/messages/#{message["id"]}/reactions?limit=2&cursorField=id&cursorValue=#{append_cursor}&cursorAffix=append",
        %{},
        "uid:bob"
      )

    assert [%{}] = json(conn)["data"]

    for reaction <- ["😎", "🎉"] do
      auth_conn(
        :delete,
        "/v3.0/messages/#{message["id"]}/reactions/#{URI.encode(reaction)}",
        %{},
        "uid:bob"
      )
    end

    conn =
      auth_conn(
        :post,
        "/v3.0/extensions/reactions/v1/react",
        %{
          "messageId" => message["id"],
          "reaction" => "🔥",
          "action" => "add"
        },
        "uid:alice"
      )

    assert Enum.any?(get_in(json(conn), ["data", "data", "reactions"]), &(&1["reaction"] == "🔥"))

    conn =
      auth_conn(
        :post,
        "/v3.0/extensions/reactions/v1/react",
        %{
          "messageId" => message["id"],
          "reaction" => "🔥",
          "action" => "remove"
        },
        "uid:alice"
      )

    refute Enum.any?(get_in(json(conn), ["data", "data", "reactions"]), &(&1["reaction"] == "🔥"))

    conn =
      auth_conn(
        :post,
        "/v3.0/extensions/reactions/v1/react",
        %{
          "msgId" => message["id"],
          "emoji" => "🎧"
        },
        "uid:alice"
      )

    assert Enum.any?(get_in(json(conn), ["data", "data", "reactions"]), &(&1["reaction"] == "🎧"))

    conn =
      auth_conn(
        :post,
        "/v3.0/extensions/reactions/v1/react",
        %{
          "msgId" => message["id"],
          "emoji" => "🎧"
        },
        "uid:alice"
      )

    refute Enum.any?(get_in(json(conn), ["data", "data", "reactions"]), &(&1["reaction"] == "🎧"))

    conn =
      auth_conn(:delete, "/v3.0/messages/#{message["id"]}/reactions/%F0%9F%91%8D", %{}, "uid:bob")

    assert get_in(json(conn), ["data", "data", "reactions"]) == []

    conn =
      auth_conn(
        :post,
        "/v3.0/messages/#{message["id"]}/reactions/%F0%9F%91%8D",
        %{},
        "uid:carol"
      )

    assert conn.status == 403
    assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"
  end

  test "reaction reactedAt cursors do not skip same-second ties" do
    wait_for_next_second()

    message =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "same second reactions"}
      })
      |> json()
      |> get_in(["data"])

    for reaction <- ["red", "green", "blue"] do
      assert auth_conn(
               :post,
               "/v3.0/messages/#{message["id"]}/reactions/#{reaction}",
               %{},
               "uid:bob"
             ).status == 200
    end

    conn =
      auth_conn(
        :get,
        "/v3.0/messages/#{message["id"]}/reactions?limit=10&cursorField=reactedAt",
        %{},
        "uid:bob"
      )

    all_rows = json(conn)["data"]
    assert length(all_rows) == 3
    assert [_same_second] = all_rows |> Enum.map(& &1["reactedAt"]) |> Enum.uniq()

    conn =
      auth_conn(
        :get,
        "/v3.0/messages/#{message["id"]}/reactions?limit=2&cursorField=reactedAt",
        %{},
        "uid:bob"
      )

    first_page = json(conn)
    assert length(first_page["data"]) == 2
    cursor = get_in(first_page, ["meta", "previous"])
    assert cursor["cursorField"] == "reactedAt"
    assert is_integer(cursor["cursorId"])

    conn =
      auth_conn(
        :get,
        "/v3.0/messages/#{message["id"]}/reactions?limit=2&cursorField=reactedAt&cursorValue=#{cursor["cursorValue"]}&cursorId=#{cursor["cursorId"]}&cursorAffix=prepend",
        %{},
        "uid:bob"
      )

    second_page = json(conn)
    assert length(second_page["data"]) == 1

    paged_ids =
      (first_page["data"] ++ second_page["data"])
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    all_ids = all_rows |> Enum.map(& &1["id"]) |> Enum.sort()
    assert paged_ids == all_ids
  end

  test "media upload route stores files, serves them, and returns 404 for missing media" do
    old_upload_dir = Application.get_env(:open_chat, :upload_dir)
    old_upload_max_bytes = Application.get_env(:open_chat, :upload_max_bytes)

    upload_dir =
      Path.join(System.tmp_dir!(), "open-chat-api-test-#{System.unique_integer([:positive])}")

    source_path =
      Path.join(
        System.tmp_dir!(),
        "open-chat-api-source-#{System.unique_integer([:positive])}.txt"
      )

    File.mkdir_p!(upload_dir)
    File.write!(source_path, "uploaded text")
    Application.put_env(:open_chat, :upload_dir, upload_dir)
    Application.put_env(:open_chat, :upload_max_bytes, 1_000)

    on_exit(fn ->
      Application.put_env(:open_chat, :upload_dir, old_upload_dir)
      Application.put_env(:open_chat, :upload_max_bytes, old_upload_max_bytes)
      File.rm_rf!(upload_dir)
      File.rm(source_path)
    end)

    conn =
      conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "caption" => "uploaded caption",
        "file" => %Plug.Upload{
          path: source_path,
          filename: "note.txt",
          content_type: "text/plain"
        }
      })
      |> Plug.Conn.put_req_header("authtoken", "uid:alice")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 201
    attachment = json(conn)["data"]["data"]["attachments"] |> List.first()
    assert attachment["mimeType"] == "text/plain"
    assert attachment["name"] == "note.txt"
    assert attachment["url"] =~ ~r(^/media/)
    refute attachment["url"] =~ "note"

    media_path = URI.parse(attachment["url"]).path
    conn = conn(:get, "/v3.0#{media_path}") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body == "uploaded text"

    conn = conn(:get, "/v3.0/media/missing.txt") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 404
    assert json(conn)["error"]["code"] == "ERR_MEDIA_NOT_FOUND"

    uploaded_filename = Path.basename(media_path)
    unsafe_media = "..%2F#{uploaded_filename}"
    conn = conn(:get, "/v3.0/media/#{unsafe_media}") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 404
    assert json(conn)["error"]["code"] == "ERR_MEDIA_NOT_FOUND"

    conn =
      conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "file" => %Plug.Upload{
          path: source_path,
          filename: "blocked.exe",
          content_type: "application/x-msdownload"
        }
      })
      |> Plug.Conn.put_req_header("authtoken", "uid:alice")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 400
    assert json(conn)["error"]["code"] == "ERR_UPLOAD_TYPE_NOT_ALLOWED"

    Application.put_env(:open_chat, :upload_max_bytes, 4)

    conn =
      conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "file" => %Plug.Upload{
          path: source_path,
          filename: "too-large.txt",
          content_type: "text/plain"
        }
      })
      |> Plug.Conn.put_req_header("authtoken", "uid:alice")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 400
    assert json(conn)["error"]["code"] == "ERR_UPLOAD_TOO_LARGE"
  end

  test "media upload route stores S3-backed files behind signed URLs only" do
    old_media_storage = Application.get_env(:open_chat, :media_storage)
    old_s3_bucket = Application.get_env(:open_chat, :s3_bucket)
    old_s3_client = Application.get_env(:open_chat, :s3_client)
    old_s3_ttl = Application.get_env(:open_chat, :s3_presigned_url_ttl_seconds)
    old_public_media_base_url = Application.get_env(:open_chat, :public_media_base_url)

    source_path =
      Path.join(
        System.tmp_dir!(),
        "open-chat-api-s3-source-#{System.unique_integer([:positive])}.png"
      )

    File.write!(source_path, "s3 image bytes")
    OpenChat.MockS3.reset()
    Application.put_env(:open_chat, :media_storage, "s3")
    Application.put_env(:open_chat, :s3_bucket, "openchat-api-test-uploads")
    Application.put_env(:open_chat, :s3_client, OpenChat.MockS3)
    Application.put_env(:open_chat, :s3_presigned_url_ttl_seconds, 1200)
    Application.put_env(:open_chat, :public_media_base_url, "https://openchat.example")

    on_exit(fn ->
      Application.put_env(:open_chat, :media_storage, old_media_storage)
      Application.put_env(:open_chat, :s3_bucket, old_s3_bucket)
      Application.put_env(:open_chat, :s3_client, old_s3_client)
      Application.put_env(:open_chat, :s3_presigned_url_ttl_seconds, old_s3_ttl)
      Application.put_env(:open_chat, :public_media_base_url, old_public_media_base_url)
      OpenChat.MockS3.reset()
      File.rm(source_path)
    end)

    conn =
      conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "file" => %Plug.Upload{
          path: source_path,
          filename: "photo.png",
          content_type: "image/png"
        }
      })
      |> Plug.Conn.put_req_header("authtoken", "uid:alice")
      |> OpenChatWeb.Endpoint.call([])

    assert conn.status == 201
    attachment = json(conn)["data"]["data"]["attachments"] |> List.first()
    uri = URI.parse(attachment["url"])
    assert uri.host == "openchat-api-test-uploads.s3.test"
    assert Path.basename(uri.path) =~ ~r/^[A-Za-z0-9_-]+-upload\.png$/
    refute uri.path =~ "photo"
    assert uri.query =~ "X-Amz-Expires=1200"
    assert uri.query =~ "X-Amz-Signature=mock"

    conn = conn(:get, "/v3.0/media/#{Path.basename(uri.path)}") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 404
    assert json(conn)["error"]["code"] == "ERR_MEDIA_NOT_FOUND"
  end

  test "settings, JWT, user sessions, and logout token revocation routes work together" do
    conn = conn(:get, "/v3.0/settings") |> OpenChatWeb.Endpoint.call([])
    assert conn.status == 200
    assert get_in(json(conn), ["data", "CHAT_API_VERSION"]) == "v3.0"

    token =
      admin_conn(:post, "/v3/users/session-user/auth_tokens")
      |> json()
      |> get_in(["data", "authToken"])

    conn = auth_conn(:post, "/v3.0/me/jwt", %{}, token)
    assert conn.status == 200
    jwt = json(conn)["data"]["jwt"]
    refute String.ends_with?(jwt, ".unsigned")

    conn = auth_conn(:get, "/v3.0/me", %{}, jwt)
    assert json(conn)["data"]["uid"] == "session-user"

    conn = auth_conn(:post, "/v3.0/user_sessions", %{"deviceId" => "ios-1"}, token)
    assert json(conn)["data"]["uid"] == "session-user"
    assert json(conn)["data"]["sessionId"] == "ios-1"

    assert auth_conn(:delete, "/v3.0/me", %{}, token).status == 200

    conn = auth_conn(:get, "/v3.0/me", %{}, token)
    assert conn.status == 401
    assert json(conn)["error"]["code"] == "ERR_NO_AUTH"
  end

  test "group search, banned-user search, block directions, conversation hiding, and delivered routes return SDK shapes" do
    for guid <- ["api-list-a", "api-list-b", "api-other"] do
      assert admin_conn(:post, "/v3/groups", %{"guid" => guid, "name" => guid}).status == 201
    end

    conn = auth_conn(:get, "/v3.0/groups?search=api-list&limit=1&page=2")
    assert [%{"guid" => "api-list-b"}] = json(conn)["data"]

    assert admin_conn(:post, "/v3/groups/api-list-a/bannedusers/bob").status == 200
    assert admin_conn(:post, "/v3/groups/api-list-a/bannedusers/carol").status == 200

    assert admin_conn(:post, "/v3/groups/api-list-a/members", %{"participants" => ["alice"]}).status ==
             200

    conn = admin_conn(:get, "/v3/groups/api-list-a/bannedusers?search=bo")
    assert [%{"uid" => "bob"}] = json(conn)["data"]

    assert auth_conn(:post, "/v3.0/blockedusers", %{"blockedUids" => ["bob"]}, "uid:alice").status ==
             200

    assert auth_conn(:post, "/v3.0/blockedusers", %{"blockedUids" => ["alice"]}, "uid:bob").status ==
             200

    conn = auth_conn(:get, "/v3.0/blockedusers?direction=hasBlockedMe", %{}, "uid:alice")
    assert [%{"uid" => "bob", "hasBlockedMe" => true}] = json(conn)["data"]

    message =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "hide this conversation"}
      })
      |> json()
      |> get_in(["data"])

    conn =
      auth_conn(
        :post,
        "/v3.0/users/alice/conversation/delivered",
        %{"messageId" => message["id"]},
        "uid:bob"
      )

    assert conn.status == 200
    assert json(conn)["data"]["conversationId"] == "user_alice_bob"
    assert json(conn)["data"]["messageId"] == to_string(message["id"])
    assert is_integer(json(conn)["data"]["deliveredAt"])

    conn = auth_conn(:get, "/v3.0/users/alice/conversation", %{}, "uid:bob")
    assert json(conn)["data"]["lastDeliveredMessageId"] == to_string(message["id"])

    group_message =
      auth_conn(
        :post,
        "/v3.0/messages",
        %{
          "receiver" => "api-list-a",
          "receiverType" => "group",
          "data" => %{"text" => "group delivered"}
        },
        "uid:alice"
      )
      |> json()
      |> get_in(["data"])

    conn =
      auth_conn(
        :post,
        "/v3.0/groups/api-list-a/conversation/delivered",
        %{"messageId" => group_message["id"]},
        "uid:alice"
      )

    assert conn.status == 200
    assert json(conn)["data"]["conversationId"] == "group_api-list-a"

    conn = auth_conn(:delete, "/v3.0/users/bob/conversation", %{}, "uid:alice")
    assert conn.status == 200
    assert json(conn)["data"]["messageId"] == to_string(message["id"])

    conn = auth_conn(:get, "/v3.0/conversations?conversationType=user", %{}, "uid:alice")
    refute Enum.any?(json(conn)["data"], &(get_in(&1, ["conversationWith", "uid"]) == "bob"))

    conn = auth_conn(:get, "/v3.0/conversations?conversationType=user", %{}, "uid:bob")
    assert Enum.any?(json(conn)["data"], &(get_in(&1, ["conversationWith", "uid"]) == "alice"))

    assert auth_conn(
             :post,
             "/v3.0/messages",
             %{
               "receiver" => "alice",
               "receiverType" => "user",
               "data" => %{"text" => "visible again"}
             },
             "uid:bob"
           ).status == 201

    conn = auth_conn(:get, "/v3.0/conversations?conversationType=user", %{}, "uid:alice")
    assert Enum.any?(json(conn)["data"], &(get_in(&1, ["conversationWith", "uid"]) == "bob"))

    assert auth_conn(:delete, "/v3.0/groups/api-list-a/conversation", %{}, "uid:alice").status ==
             200
  end

  test "missing message and extension parameter paths return explicit API errors" do
    conn = auth_conn(:get, "/v3.0/messages/404")
    assert conn.status == 404
    assert json(conn)["error"]["code"] == "ERR_MESSAGE_NOT_FOUND"

    conn = auth_conn(:get, "/v3.0/user/messages/not-a-muid")
    assert conn.status == 404
    assert json(conn)["error"]["code"] == "ERR_MESSAGE_NOT_FOUND"

    conn = auth_conn(:put, "/v3.0/messages/404", %{"data" => %{"text" => "nope"}})
    assert conn.status == 400
    assert json(conn)["error"]["code"] == "ERR_MESSAGE_NOT_FOUND"

    conn = auth_conn(:delete, "/v3.0/messages/404")
    assert conn.status == 400
    assert json(conn)["error"]["code"] == "ERR_MESSAGE_NOT_FOUND"

    conn = auth_conn(:post, "/v3.0/messages/404/reactions/%F0%9F%91%8D")
    assert conn.status == 400
    assert json(conn)["error"]["code"] == "ERR_MESSAGE_NOT_FOUND"

    conn = auth_conn(:post, "/v3.0/extensions/reactions/v1/react", %{"reaction" => "👍"})
    assert conn.status == 400
    assert json(conn)["error"]["details"] == %{"parameter" => "messageId"}

    conn = auth_conn(:post, "/v3.0/extensions/reactions/v1/react", %{"messageId" => "1"})
    assert conn.status == 400
    assert json(conn)["error"]["details"] == %{"parameter" => "reaction"}
  end

  test "message mutation APIs forbid non-senders and allow full-access API key deletes" do
    conn =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "owned by alice"}
      })

    assert conn.status == 201
    message = json(conn)["data"]

    conn =
      auth_conn(
        :put,
        "/v3.0/messages/#{message["id"]}",
        %{"data" => %{"text" => "bob edit"}},
        "uid:bob"
      )

    assert conn.status == 403
    assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"

    conn = auth_conn(:delete, "/v3.0/messages/#{message["id"]}", %{}, "uid:bob")
    assert conn.status == 403
    assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"

    conn = admin_conn(:delete, "/v3/messages/#{message["id"]}")
    assert conn.status == 200
    assert get_in(json(conn), ["data", "data", "action"]) == "deleted"
  end

  test "API-key moderation can edit without auth token and rejects bad API keys" do
    conn =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "before admin edit"}
      })

    assert conn.status == 201
    message = json(conn)["data"]

    conn =
      conn(:put, "/v3/messages/#{message["id"]}", Jason.encode!(%{"data" => %{"text" => "bad"}}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("apikey", "not-the-key")
      |> Endpoint.call([])

    assert conn.status == 403
    assert json(conn)["error"]["code"] == "ERR_FORBIDDEN"

    conn =
      admin_conn(:put, "/v3/messages/#{message["id"]}", %{
        "data" => %{"text" => "after admin edit"}
      })

    assert conn.status == 200
    action = json(conn)["data"]
    assert action["sender"] == "system"
    assert action["data"]["action"] == "edited"

    assert get_in(action, ["data", "entities", "on", "entity", "data", "text"]) ==
             "after admin edit"
  end

  test "group message mutation APIs allow room moderators and owners only" do
    assert admin_conn(:post, "/v3/groups", %{
             "guid" => "api-secure-room",
             "type" => "public",
             "ownerUid" => "api-owner"
           }).status == 201

    assert admin_conn(:post, "/v3/groups/api-secure-room/members", %{
             "participants" => ["alice", "bob"],
             "moderators" => ["api-mod"],
             "admins" => ["api-admin"]
           }).status == 200

    assert admin_conn(:put, "/v3/groups/api-secure-room/members/api-co-owner", %{
             "scope" => "coOwner"
           }).status == 200

    conn =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "api-secure-room",
        "receiverType" => "group",
        "data" => %{"text" => "group moderation"}
      })

    assert conn.status == 201
    message = json(conn)["data"]

    conn = auth_conn(:delete, "/v3.0/messages/#{message["id"]}", %{}, "uid:bob")
    assert conn.status == 403

    conn =
      auth_conn(
        :put,
        "/v3.0/messages/#{message["id"]}",
        %{"data" => %{"text" => "moderator edit"}},
        "uid:api-mod"
      )

    assert conn.status == 200
    assert get_in(json(conn), ["data", "data", "action"]) == "edited"
    action = json(conn)["data"]

    assert auth_conn(:delete, "/v3.0/messages/#{action["id"]}", %{}, "uid:api-owner").status ==
             200

    conn =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "api-secure-room",
        "receiverType" => "group",
        "data" => %{"text" => "group moderation 2"}
      })

    second = json(conn)["data"]

    assert auth_conn(:delete, "/v3.0/messages/#{second["id"]}", %{}, "uid:api-admin").status ==
             200

    conn =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "api-secure-room",
        "receiverType" => "group",
        "data" => %{"text" => "group moderation 3"}
      })

    third = json(conn)["data"]
    assert auth_conn(:delete, "/v3.0/messages/#{third["id"]}", %{}, "uid:api-owner").status == 200

    conn =
      auth_conn(:post, "/v3.0/messages", %{
        "receiver" => "api-secure-room",
        "receiverType" => "group",
        "data" => %{"text" => "group moderation 4"}
      })

    fourth = json(conn)["data"]

    assert auth_conn(:delete, "/v3.0/messages/#{fourth["id"]}", %{}, "uid:api-co-owner").status ==
             200
  end

  test "TTFM socket admin-POST text message: data.metadata.chatMessage envelope and <@uid:>/<consumableId:> mentions round-trip" do
    # Mirrors hangout/socket/src/initializers/cometChat.ts postSongMessage and
    # postConsumableMessage. The admin POST to /v3/messages embeds a domain payload
    # in data.metadata.chatMessage and uses <@uid:xxx>/<consumableId:yyy> mentions
    # inside the visible text. OpenChat must accept this shape and return it
    # verbatim through the user-facing fetch route so snowy converters can parse it.
    room = "ttfm-socket-room"

    assert admin_conn(:post, "/v3/groups", %{
             "guid" => room,
             "type" => "public",
             "ownerUid" => "room-owner"
           }).status == 201

    assert auth_conn(:post, "/v3.0/groups/#{room}/members", %{}, "uid:alice").status in [200, 201]

    assert auth_conn(:post, "/v3.0/groups/#{room}/members", %{}, "uid:room-owner").status in [
             200,
             201
           ]

    text =
      "<@uid:alice> played <consumableId:c-456>"

    chat_message_envelope = %{
      "type" => "room",
      "songs" => [
        %{
          "type" => "ChatMusicInfo",
          "song" => %{"spotifyId" => "sp-12345", "title" => "Hangout Anthem"}
        }
      ],
      "consumable" => %{"id" => "c-456", "kind" => "takeover"}
    }

    body = %{
      "type" => "text",
      "receiverType" => "group",
      "category" => "message",
      "receiver" => room,
      "data" => %{
        "text" => text,
        "metadata" => %{"chatMessage" => chat_message_envelope}
      }
    }

    conn = admin_conn(:post, "/v3/messages", body)
    assert conn.status in [200, 201]

    sent = json(conn)["data"]
    assert sent["receiver"] == room
    assert sent["data"]["text"] == text

    assert get_in(sent, ["data", "metadata", "chatMessage", "songs"]) ==
             chat_message_envelope["songs"]

    assert get_in(sent, ["data", "metadata", "chatMessage", "consumable"]) ==
             chat_message_envelope["consumable"]

    # Member fetches the same message via the SDK-shaped GET route and the wire
    # round-trips unchanged — mentions intact, envelope intact.
    fetch_conn = auth_conn(:get, "/v3.0/groups/#{room}/messages?limit=10", %{}, "uid:alice")
    assert fetch_conn.status == 200
    [fetched | _rest] = json(fetch_conn)["data"]
    assert fetched["data"]["text"] == text
    assert get_in(fetched, ["data", "metadata", "chatMessage", "type"]) == "room"

    assert get_in(fetched, ["data", "metadata", "chatMessage", "songs"]) ==
             chat_message_envelope["songs"]

    delete_conn = auth_conn(:delete, "/v3.0/messages/#{sent["id"]}", %{}, "uid:room-owner")
    assert delete_conn.status == 200
    assert get_in(json(delete_conn), ["data", "data", "action"]) == "deleted"
  end

  test "history and live payloads do not expose malformed legacy media messages to the SDK" do
    room = "ttfm-legacy-media-room"
    assert admin_conn(:post, "/v3/groups", %{"guid" => room, "type" => "public"}).status == 201
    assert auth_conn(:post, "/v3.0/groups/#{room}/members", %{}, "uid:alice").status in [200, 201]
    assert auth_conn(:post, "/v3.0/groups/#{room}/members", %{}, "uid:bob").status in [200, 201]

    assert {:ok, _subscription} = OpenChat.PubSub.subscribe({:user, "bob"})

    conn =
      admin_conn(:post, "/v3/messages", %{
        "sender" => "alice",
        "receiver" => room,
        "receiverType" => "group",
        "category" => "message",
        "type" => "image",
        "data" => %{
          "metadata" => %{
            "chatMessage" => %{
              "message" => "",
              "media" => %{"name" => "missing-upload.png", "type" => "image/png"}
            }
          }
        }
      })

    assert conn.status in [200, 201]
    sent = json(conn)["data"]
    assert sent["type"] == "text"
    assert get_in(sent, ["data", "text"]) == "missing-upload.png"
    refute Map.has_key?(sent["data"], "attachments")

    assert_receive {:comet_event, event}
    assert get_in(event, ["body", "type"]) == "text"
    assert get_in(event, ["body", "data", "text"]) == "missing-upload.png"

    fetch_conn = auth_conn(:get, "/v3.0/groups/#{room}/messages?limit=10", %{}, "uid:bob")
    assert fetch_conn.status == 200
    [fetched | _rest] = json(fetch_conn)["data"]
    assert fetched["id"] == sent["id"]
    assert fetched["type"] == "text"
    assert get_in(fetched, ["data", "text"]) == "missing-upload.png"
    refute Map.has_key?(fetched["data"], "attachments")
  end

  test "user-service admin flow: create user, mint auth token, /me round-trips, then delete via admin" do
    # Mirrors hangout/user-service/src/comet-chat/comet-chat.service.ts createCometChatUser
    # + createAuthToken + isAuthTokenValid + downstream cleanup. Each step uses the same
    # endpoint shape the production service hits against the real CometChat API.
    create =
      admin_conn(:post, "/v3/users", %{
        "uid" => "ttfm-user-svc-1",
        "name" => "TTFM User One",
        "role" => "default",
        "metadata" => Jason.encode!(%{"avatarId" => "av-1", "color" => "#abcdef"})
      })

    assert create.status == 201
    assert json(create)["data"]["uid"] == "ttfm-user-svc-1"

    mint = admin_conn(:post, "/v3/users/ttfm-user-svc-1/auth_tokens")
    assert mint.status == 200
    token = json(mint)["data"]["authToken"]
    assert is_binary(token)
    assert String.length(token) > 0

    me = auth_conn(:get, "/v3.0/me", %{}, token)
    assert me.status == 200
    assert json(me)["data"]["uid"] == "ttfm-user-svc-1"

    update =
      admin_conn(:put, "/v3/users/ttfm-user-svc-1", %{
        "name" => "TTFM User Renamed",
        "metadata" => Jason.encode!(%{"avatarId" => "av-2", "color" => "#fedcba"})
      })

    assert update.status == 200
    assert json(update)["data"]["name"] == "TTFM User Renamed"

    revoke = admin_conn(:delete, "/v3/admin/users/auth/#{token}")
    assert revoke.status == 200

    stale = auth_conn(:get, "/v3.0/me", %{}, token)
    assert stale.status == 401
  end

  test "user-service deactivate/reactivate flow keeps cached auth token behavior compatible" do
    # Mirrors user-service deactivateCometChatUser/reactivateCometChatUser. The
    # service stores auth tokens in its own DB, so deactivation must reject that
    # cached token, and reactivation must make the same token valid again.
    uid = "ttfm-reactivate-user"

    create =
      admin_conn(:post, "/v3/users", %{
        "uid" => uid,
        "name" => "TTFM Reactivate",
        "metadata" => Jason.encode!(%{"avatarId" => "av-react", "color" => "#13579b"})
      })

    assert create.status == 201
    assert get_in(json(create), ["data", "metadata", "avatarId"]) == "av-react"

    mint = admin_conn(:post, "/v3/users/#{uid}/auth_tokens")
    assert mint.status == 200
    token = get_in(json(mint), ["data", "authToken"])

    assert auth_conn(:get, "/v3.0/me", %{}, token).status == 200

    deactivate = admin_conn(:delete, "/v3/users/#{uid}", %{"permanent" => false})
    assert deactivate.status == 200

    deactivated_me = auth_conn(:get, "/v3.0/me", %{}, token)
    assert deactivated_me.status == 401
    assert json(deactivated_me)["error"]["code"] == "ERR_NO_AUTH"

    reactivate = admin_conn(:put, "/v3/users", %{"uidsToActivate" => [uid]})
    assert reactivate.status == 200
    assert get_in(json(reactivate), ["data", "success", uid, "success"]) == true

    me = auth_conn(:get, "/v3.0/me", %{}, token)
    assert me.status == 200
    assert get_in(json(me), ["data", "uid"]) == uid
    assert get_in(json(me), ["data", "metadata", "color"]) == "#13579b"
  end

  test "rooms-service admin flow: create group, set scopes (admins+moderators+participants), list by scope, ban/unban" do
    # Mirrors hangout/rooms-service/src/comet-chat/comet-chat.service.ts createGroupForRoom,
    # setUsersScope, getUsersWithScope, banUser, unBanUser, deleteRoomConversation.
    room = "ttfm-rooms-svc-1"

    create =
      admin_conn(:post, "/v3/groups", %{
        "guid" => room,
        "name" => "da:#{room}",
        "type" => "public"
      })

    assert create.status == 201

    scope_payload = %{
      "admins" => ["rooms-admin-1"],
      "moderators" => ["rooms-mod-1", "rooms-mod-2"],
      "participants" => ["rooms-participant-1"]
    }

    scopes = admin_conn(:post, "/v3/groups/#{room}/members", scope_payload)
    assert scopes.status == 200

    list = admin_conn(:get, "/v3/groups/#{room}/members?scope=admin,moderator")
    assert list.status == 200

    member_uids =
      json(list)["data"]
      |> Enum.map(& &1["uid"])
      |> Enum.sort()

    assert "rooms-admin-1" in member_uids
    assert "rooms-mod-1" in member_uids
    assert "rooms-mod-2" in member_uids
    refute "rooms-participant-1" in member_uids

    ban = admin_conn(:post, "/v3/groups/#{room}/bannedusers/rooms-bad-actor")
    assert ban.status == 200

    banned = admin_conn(:get, "/v3/groups/#{room}/bannedusers")
    assert banned.status == 200
    assert Enum.any?(json(banned)["data"], &(&1["uid"] == "rooms-bad-actor"))

    unban = admin_conn(:delete, "/v3/groups/#{room}/bannedusers/rooms-bad-actor")
    assert unban.status == 200

    # rooms-service deleteRoomConversation hits DELETE /v3/conversations/:guid.
    cleanup = admin_conn(:delete, "/v3/conversations/#{room}")
    assert cleanup.status == 200

    deleted = admin_conn(:delete, "/v3/groups/#{room}")
    assert deleted.status == 200
  end

  test "rooms-service deleteRoomConversation clears group history without deleting room or members" do
    # Mirrors rooms-service deleteRoomConversation(roomUuid), which calls
    # DELETE /v3/conversations/:roomUuid instead of the canonical group_<guid>
    # conversation id. OpenChat must accept that alias and keep the room usable.
    room = "ttfm-rooms-clean-1"

    assert admin_conn(:post, "/v3/groups", %{
             "guid" => room,
             "name" => "da:#{room}",
             "type" => "public"
           }).status == 201

    assert admin_conn(:post, "/v3/groups/#{room}/members", %{
             "participants" => ["alice", "bob"]
           }).status == 200

    first =
      auth_conn(
        :post,
        "/v3.0/messages",
        %{
          "receiver" => room,
          "receiverType" => "group",
          "type" => "text",
          "category" => "message",
          "data" => %{"text" => "before room cleanup"}
        },
        "uid:alice"
      )

    assert first.status == 201

    history_before = auth_conn(:get, "/v3.0/groups/#{room}/messages?limit=10", %{}, "uid:bob")

    assert Enum.any?(
             json(history_before)["data"],
             &(get_in(&1, ["data", "text"]) == "before room cleanup")
           )

    conversations_before =
      auth_conn(:get, "/v3.0/conversations?conversationType=group", %{}, "uid:bob")

    assert Enum.any?(
             json(conversations_before)["data"],
             &(get_in(&1, ["conversationWith", "guid"]) == room)
           )

    cleanup = admin_conn(:delete, "/v3/conversations/#{room}")
    assert cleanup.status == 200
    assert get_in(json(cleanup), ["data", "conversationId"]) == room

    history_after = auth_conn(:get, "/v3.0/groups/#{room}/messages?limit=10", %{}, "uid:bob")
    assert history_after.status == 200
    assert json(history_after)["data"] == []

    group = auth_conn(:get, "/v3.0/groups/#{room}", %{}, "uid:bob")
    assert group.status == 200
    assert get_in(json(group), ["data", "guid"]) == room

    members = admin_conn(:get, "/v3/groups/#{room}/members")
    assert members.status == 200
    assert Enum.map(json(members)["data"], & &1["uid"]) |> Enum.sort() == ["alice", "bob"]

    second =
      auth_conn(
        :post,
        "/v3.0/messages",
        %{
          "receiver" => room,
          "receiverType" => "group",
          "type" => "text",
          "category" => "message",
          "data" => %{"text" => "after room cleanup"}
        },
        "uid:bob"
      )

    assert second.status == 201

    history_reused = auth_conn(:get, "/v3.0/groups/#{room}/messages?limit=10", %{}, "uid:alice")

    assert Enum.map(json(history_reused)["data"], &get_in(&1, ["data", "text"])) == [
             "after room cleanup"
           ]
  end

  test "socket remove-group-member: admin DELETE /v3/groups/:guid/members/:uid succeeds and is idempotent on 404" do
    # Mirrors hangout/socket/src/initializers/cometChat.ts removeGroupMember which
    # tolerates a 404 (already not a member) without escalating.
    room = "ttfm-socket-room-2"
    assert admin_conn(:post, "/v3/groups", %{"guid" => room, "type" => "public"}).status == 201

    assert admin_conn(:post, "/v3/groups/#{room}/members", %{"participants" => ["socket-user-1"]}).status ==
             200

    removed = admin_conn(:delete, "/v3/groups/#{room}/members/socket-user-1")
    assert removed.status == 200

    # Removing the same user twice does not crash — the production socket initializer
    # explicitly suppresses captureException when status != 404, so 200 OR 404 here is
    # fine. OpenChat returns 200 with success=true even when the user is already gone.
    second = admin_conn(:delete, "/v3/groups/#{room}/members/socket-user-1")
    assert second.status in [200, 404]
  end

  defp wait_for_next_second do
    current = OpenChat.Time.now()

    Stream.repeatedly(fn ->
      Process.sleep(5)
      OpenChat.Time.now()
    end)
    |> Enum.find(&(&1 != current))
  end
end
