defmodule SREChat.StoreIndexesTest do
  use ExUnit.Case, async: false

  alias SREChat.Store.Indexes

  test "put_member and remove_member maintain member rows and user group indexes" do
    state = base_state()

    state =
      state
      |> Indexes.put_member("room", "alice", "admin", 100)
      |> Indexes.put_member("room", "bob", "members", 101)

    assert get_in(state, ["members", "room", "alice"]) == %{
             "uid" => "alice",
             "guid" => "room",
             "scope" => "admin",
             "role" => "admin",
             "joinedAt" => 100
           }

    assert get_in(state, ["members", "room", "bob", "scope"]) == "participant"
    assert state["user_groups"] == %{"alice" => ["room"], "bob" => ["room"]}

    state = Indexes.remove_member(state, "room", "alice")

    refute Map.has_key?(state["members"]["room"], "alice")
    refute Map.has_key?(state["user_groups"], "alice")
    assert state["user_groups"]["bob"] == ["room"]
  end

  test "link_message maintains direct conversation and muid indexes without duplicates" do
    message = direct_message("10", "alice", "bob", "client-10")

    state =
      base_state()
      |> Indexes.link_message(message)
      |> Indexes.link_message(message)

    assert state["message_muids"] == %{"client-10" => "10"}
    assert state["conversation_users"]["user_alice_bob"] == ["alice", "bob"]
    assert state["user_conversations"]["alice"] == ["user_alice_bob"]
    assert state["user_conversations"]["bob"] == ["user_alice_bob"]
  end

  test "remove_messages deletes muid secondary indexes only for removed messages" do
    keep = direct_message("10", "alice", "bob", "keep-muid")
    remove = direct_message("11", "alice", "bob", "remove-muid")

    state =
      base_state()
      |> Indexes.link_message(keep)
      |> Indexes.link_message(remove)
      |> Indexes.remove_messages([remove])

    assert state["message_muids"] == %{"keep-muid" => "10"}
  end

  test "remove_conversations clears conversation users and compacts user indexes" do
    state =
      base_state()
      |> put_in(["conversation_users", "user_alice_bob"], ["alice", "bob"])
      |> put_in(["conversation_users", "user_alice_carol"], ["alice", "carol"])
      |> put_in(["user_conversations", "alice"], ["user_alice_bob", "user_alice_carol"])
      |> put_in(["user_conversations", "bob"], ["user_alice_bob"])
      |> put_in(["user_conversations", "carol"], ["user_alice_carol"])

    state = Indexes.remove_conversations(state, ["user_alice_bob"])

    refute Map.has_key?(state["conversation_users"], "user_alice_bob")
    assert state["conversation_users"]["user_alice_carol"] == ["alice", "carol"]
    assert state["user_conversations"]["alice"] == ["user_alice_carol"]
    refute Map.has_key?(state["user_conversations"], "bob")
    assert state["user_conversations"]["carol"] == ["user_alice_carol"]
  end

  test "group message participants cap fanout for large rooms" do
    with_sre_chat_env(%{group_unread_fanout_limit: 2}, fn ->
      state =
        base_state()
        |> put_in(["members", "room"], %{
          "alice" => %{"uid" => "alice"},
          "bob" => %{"uid" => "bob"},
          "carol" => %{"uid" => "carol"}
        })

      message = group_message("20", "alice", "room", "group_room")

      assert Indexes.message_participants(state, message) == ["alice"]

      state = Indexes.link_message(state, message)

      assert state["conversation_users"]["group_room"] == ["alice"]
      assert state["user_conversations"]["alice"] == ["group_room"]
      refute Map.has_key?(state["user_conversations"], "bob")
    end)
  end

  test "conversation_ids_for_user includes group conversations only when they have messages or latest" do
    state =
      base_state()
      |> put_in(["user_groups", "alice"], ["empty-room", "active-room"])
      |> put_in(["conversation_messages", "group_active-room"], ["1"])
      |> put_in(["user_conversations", "alice"], ["user_alice_bob", "user_alice_carol"])
      |> put_in(["conversation_latest", "user_alice_bob"], "2")

    assert Indexes.conversation_ids_for_user(state, "alice") |> Enum.sort() ==
             ["group_active-room", "user_alice_bob"]
  end

  test "rebuild derives secondary indexes from members and messages" do
    state =
      base_state()
      |> put_in(["members", "room"], %{"alice" => %{"uid" => "alice"}})
      |> put_in(["messages", "10"], direct_message("10", "alice", "bob", "client-10"))
      |> put_in(["messages", "11"], group_message("11", "alice", "room", "group_room"))

    rebuilt = Indexes.rebuild(state)

    assert rebuilt["message_muids"] == %{"client-10" => "10"}
    assert rebuilt["user_groups"] == %{"alice" => ["room"]}
    assert rebuilt["conversation_users"]["user_alice_bob"] == ["alice", "bob"]
    assert rebuilt["conversation_users"]["group_room"] == ["alice"]
  end

  defp base_state do
    %{
      "members" => %{},
      "messages" => %{},
      "conversation_messages" => %{},
      "conversation_latest" => %{},
      "message_muids" => %{},
      "user_conversations" => %{},
      "conversation_users" => %{},
      "user_groups" => %{}
    }
  end

  defp direct_message(id, sender, receiver, muid) do
    %{
      "id" => id,
      "muid" => muid,
      "sender" => sender,
      "receiver" => receiver,
      "receiverType" => "user",
      "conversationId" => "user_#{sender}_#{receiver}"
    }
  end

  defp group_message(id, sender, guid, conv_id) do
    %{
      "id" => id,
      "sender" => sender,
      "receiver" => guid,
      "receiverType" => "group",
      "conversationId" => conv_id
    }
  end

  defp with_sre_chat_env(overrides, fun) do
    previous =
      Map.new(overrides, fn {key, _value} ->
        {key, Application.get_env(:sre_chat, key)}
      end)

    Enum.each(overrides, fn {key, value} ->
      Application.put_env(:sre_chat, key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:sre_chat, key)
        {key, value} -> Application.put_env(:sre_chat, key, value)
      end)
    end
  end
end
