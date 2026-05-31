defmodule OpenChat.RestCompatTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias OpenChat.Store
  alias OpenChatWeb.Endpoint

  setup do
    Store.reset!()
    :ok
  end

  test "legacy generic direct-message listing filters sender before limit" do
    {:ok, %{"authToken" => bot_token}} = Store.create_auth_token("bot")

    {:ok, inbound} =
      Store.send_message("alice", %{
        "receiver" => "bot",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "command"}
      })

    {:ok, _reply} =
      Store.send_message("bot", %{
        "receiver" => "alice",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "reply"}
      })

    response =
      get_json(
        "/v3.0/messages?receiverType=user&sender=alice&limit=1&hideDeleted=0",
        bot_token
      )

    assert response.status == 200
    assert %{"data" => [message]} = decode(response)
    assert to_s(message["id"]) == to_s(inbound["id"])
    assert message["sender"] == "alice"
  end

  test "legacy generic direct-message listing cannot read conversations without the caller" do
    {:ok, %{"authToken" => bot_token}} = Store.create_auth_token("bot")

    {:ok, _private} =
      Store.send_message("alice", %{
        "receiver" => "charlie",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "not for bot"}
      })

    response = get_json("/v3.0/messages?receiverType=user&sender=alice&limit=10", bot_token)

    assert response.status == 200
    assert %{"data" => []} = decode(response)
  end

  test "legacy generic group listing still enforces group read permissions" do
    {:ok, %{"authToken" => outsider_token}} = Store.create_auth_token("outsider")
    assert {:ok, _group} = Store.upsert_group(%{"guid" => "private-room", "type" => "private"})
    assert {:ok, _members} = Store.add_group_members("private-room", ["alice"])

    {:ok, _message} =
      Store.send_message("alice", %{
        "receiver" => "private-room",
        "receiverType" => "group",
        "type" => "text",
        "data" => %{"text" => "members only"}
      })

    response =
      get_json(
        "/v3.0/messages?receiverType=group&receiver=private-room&limit=10",
        outsider_token
      )

    assert response.status == 400
    assert %{"error" => %{"code" => "ERR_NOT_A_MEMBER"}} = decode(response)
  end

  test "legacy message interactions endpoint marks the inferred conversation read" do
    {:ok, %{"authToken" => bot_token}} = Store.create_auth_token("bot")

    {:ok, inbound} =
      Store.send_message("alice", %{
        "receiver" => "bot",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "read me"}
      })

    assert {:ok, [%{"entityId" => "alice", "count" => 1}]} =
             Store.unread_counts("bot", %{"receiverType" => "user"})

    response = post_json("/v3/messages/#{inbound["id"]}/interactions", bot_token, %{})

    assert response.status == 200
    assert %{"data" => %{"success" => true, "messageId" => message_id}} = decode(response)
    assert to_s(message_id) == to_s(inbound["id"])
    assert {:ok, []} = Store.unread_counts("bot", %{"receiverType" => "user"})
  end

  test "legacy message interactions endpoint cannot read inaccessible messages" do
    {:ok, %{"authToken" => bot_token}} = Store.create_auth_token("bot")

    {:ok, inaccessible} =
      Store.send_message("alice", %{
        "receiver" => "charlie",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "not for bot"}
      })

    response = post_json("/v3/messages/#{inaccessible["id"]}/interactions", bot_token, %{})

    assert response.status == 403
    assert %{"error" => %{"code" => "ERR_FORBIDDEN"}} = decode(response)
  end

  test "legacy message interactions endpoint validates body message ids against the same conversation" do
    {:ok, %{"authToken" => bot_token}} = Store.create_auth_token("bot")

    {:ok, accessible} =
      Store.send_message("alice", %{
        "receiver" => "bot",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "visible"}
      })

    {:ok, inaccessible} =
      Store.send_message("alice", %{
        "receiver" => "charlie",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "hidden"}
      })

    response =
      post_json("/v3/messages/#{accessible["id"]}/interactions", bot_token, %{
        "messageId" => inaccessible["id"]
      })

    assert response.status == 403
    assert %{"error" => %{"code" => "ERR_FORBIDDEN"}} = decode(response)
  end

  test "legacy self member delete path leaves group with a user auth token" do
    {:ok, %{"authToken" => bot_token}} = Store.create_auth_token("bot")
    assert {:ok, _group} = Store.upsert_group(%{"guid" => "room", "type" => "public"})
    assert {:ok, _members} = Store.add_group_members("room", ["bot"])

    response = delete_json("/v3/groups/room/members/bot", bot_token, [{"appid", "public-app"}])

    assert response.status == 200
    assert %{"data" => %{"success" => true}} = decode(response)
    assert {:ok, members} = Store.group_members("room")
    refute Enum.any?(members, &(&1["uid"] == "bot"))
  end

  test "legacy self member delete path cannot remove a different user" do
    {:ok, %{"authToken" => bot_token}} = Store.create_auth_token("bot")
    assert {:ok, _group} = Store.upsert_group(%{"guid" => "room", "type" => "public"})
    assert {:ok, _members} = Store.add_group_members("room", ["bot", "alice"])

    response = delete_json("/v3/groups/room/members/alice", bot_token)

    assert response.status == 403
    assert {:ok, members} = Store.group_members("room")
    assert Enum.any?(members, &(&1["uid"] == "alice"))
  end

  test "legacy self member delete path does not fall back to user auth when apiKey is invalid" do
    {:ok, %{"authToken" => bot_token}} = Store.create_auth_token("bot")
    assert {:ok, _group} = Store.upsert_group(%{"guid" => "room", "type" => "public"})
    assert {:ok, _members} = Store.add_group_members("room", ["bot"])

    response = delete_json("/v3/groups/room/members/bot", bot_token, [{"apikey", "public-app"}])

    assert response.status == 403
    assert %{"error" => %{"code" => "ERR_FORBIDDEN"}} = decode(response)
    assert {:ok, members} = Store.group_members("room")
    assert Enum.any?(members, &(&1["uid"] == "bot"))
  end

  defp get_json(path, token) do
    conn(:get, path)
    |> put_req_header("authtoken", token)
    |> Endpoint.call([])
  end

  defp post_json(path, token, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authtoken", token)
    |> Endpoint.call([])
  end

  defp delete_json(path, token, extra_headers \\ []) do
    extra_headers
    |> Enum.reduce(
      conn(:delete, path)
      |> put_req_header("authtoken", token),
      fn {key, value}, conn -> put_req_header(conn, key, value) end
    )
    |> Endpoint.call([])
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
