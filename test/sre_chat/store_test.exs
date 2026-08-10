defmodule SREChat.StoreTest do
  use ExUnit.Case, async: false

  setup do
    SREChat.Store.reset!()
    :ok
  end

  test "auth token login payload includes CometChat settings and user getters fields" do
    {:ok, me} = SREChat.Store.me("uid:alice")
    assert me["uid"] == "alice"
    assert me["authToken"] == "uid:alice"
    assert me["settings"]["CHAT_API_VERSION"] == "v3.0"
    assert me["settings"]["CHAT_WSS_PORT"]
    assert me["jwt"]
  end

  test "send, fetch, unread, mark read, and conversation" do
    {:ok, msg} =
      SREChat.Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "type" => "text",
        "category" => "message",
        "data" => %{"text" => "hello"}
      })

    assert msg["data"]["text"] == "hello"
    assert get_in(msg, ["data", "entities", "sender", "entity", "uid"]) == "alice"

    {:ok, messages} = SREChat.Store.messages_for_user("bob", "alice", %{"limit" => 10})
    assert length(messages) == 1

    {:ok, counts} =
      SREChat.Store.unread_counts("bob", %{
        "receiverType" => "user",
        "count" => "1",
        "unread" => "1"
      })

    assert [%{"entityId" => "alice", "count" => 1}] = counts

    {:ok, _} = SREChat.Store.mark_read("bob", "user", "alice", msg["id"])
    {:ok, counts} = SREChat.Store.unread_counts("bob", %{"receiverType" => "user"})
    assert counts == []

    {:ok, conv} = SREChat.Store.conversation("bob", "user", "alice")
    assert conv["lastMessage"]["id"] == msg["id"]
    assert conv["conversationWith"]["uid"] == "alice"
  end

  test "mark unread on the first message rewinds the read cursor" do
    {:ok, msg} =
      SREChat.Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "type" => "text",
        "data" => %{"text" => "first unread"}
      })

    {:ok, _} = SREChat.Store.mark_read("bob", "user", "alice", msg["id"])
    {:ok, []} = SREChat.Store.unread_counts("bob", %{"receiverType" => "user"})

    {:ok, %{"conversation" => conv}} =
      SREChat.Store.mark_unread("bob", "user", "alice", msg["id"])

    assert conv["lastReadMessageId"] == "0"

    {:ok, counts} = SREChat.Store.unread_counts("bob", %{"receiverType" => "user"})
    assert [%{"entityId" => "alice", "count" => 1}] = counts
  end

  test "groups require join before group messages" do
    {:ok, group} = SREChat.Store.join_group("lobby", "alice", %{})
    assert group["hasJoined"]

    {:ok, msg} =
      SREChat.Store.send_message("alice", %{
        "receiver" => "lobby",
        "receiverType" => "group",
        "type" => "text",
        "data" => %{"text" => "hello group"}
      })

    assert msg["conversationId"] == "group_lobby"
  end

  test "custom, media-like data, delete/edit actions, and reactions" do
    {:ok, msg} =
      SREChat.Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "type" => "custom",
        "category" => "message",
        "data" => %{"customData" => %{"kind" => "ping"}}
      })

    assert get_in(msg, ["data", "customData", "kind"]) == "ping"

    {:ok, reacted} = SREChat.Store.add_reaction("bob", msg["id"], "👍")
    assert [%{"reaction" => "👍", "count" => 1}] = get_in(reacted, ["data", "reactions"])
    assert reacted["updatedAt"] == msg["updatedAt"]

    {:ok, unreacted} = SREChat.Store.remove_reaction("bob", msg["id"], "👍")
    assert get_in(unreacted, ["data", "reactions"]) == []
    assert unreacted["updatedAt"] == msg["updatedAt"]

    {:ok, legacy_reacted} =
      SREChat.Store.call_on(SREChat.Store, {:add_reaction, "bob", to_string(msg["id"]), "🔥"})

    assert [%{"reaction" => "🔥", "count" => 1}] = get_in(legacy_reacted, ["data", "reactions"])

    {:ok, legacy_unreacted} =
      SREChat.Store.call_on(
        SREChat.Store,
        {:remove_reaction, "bob", to_string(msg["id"]), "🔥"}
      )

    assert get_in(legacy_unreacted, ["data", "reactions"]) == []

    {:ok, legacy_toggled} =
      SREChat.Store.call_on(
        SREChat.Store,
        {:toggle_reaction, "bob", to_string(msg["id"]), "🎧"}
      )

    assert [%{"reaction" => "🎧", "count" => 1}] = get_in(legacy_toggled, ["data", "reactions"])

    {:ok, edited_action} =
      SREChat.Store.edit_message("alice", msg["id"], %{
        "data" => %{"customData" => %{"kind" => "pong"}}
      })

    assert edited_action["category"] == "action"
    assert edited_action["id"] != msg["id"]
    assert get_in(edited_action, ["data", "action"]) == "edited"

    {:ok, stored_edited_action} = SREChat.Store.get_message(edited_action["id"])
    assert stored_edited_action["id"] == edited_action["id"]

    assert get_in(edited_action, [
             "data",
             "entities",
             "on",
             "entity",
             "data",
             "customData",
             "kind"
           ]) == "pong"

    {:ok, deleted_action} = SREChat.Store.delete_message("alice", msg["id"])
    assert get_in(deleted_action, ["data", "action"]) == "deleted"
    assert get_in(deleted_action, ["data", "entities", "on", "entity", "deletedAt"])
    assert deleted_action["id"] > edited_action["id"]

    {:ok, stored_deleted_action} = SREChat.Store.get_message(deleted_action["id"])
    assert stored_deleted_action["id"] == deleted_action["id"]
  end
end
