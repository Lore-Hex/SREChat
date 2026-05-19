defmodule OpenChat.Store.ConversationsTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.{Conversations, State}

  describe "conversation_id helpers" do
    test "user conversations are deterministically ordered" do
      assert Conversations.user_conversation_id("alice", "bob") == "user_alice_bob"
      assert Conversations.user_conversation_id("bob", "alice") == "user_alice_bob"
      assert Conversations.user_conversation_id("alice", "alice") == "user_alice_alice"
    end

    test "group conversation ids are prefixed and forced to string" do
      assert Conversations.group_conversation_id("room-1") == "group_room-1"
      assert Conversations.group_conversation_id(:room) == "group_room"
    end

    test "conversation_id_for dispatches on receiverType" do
      assert Conversations.conversation_id_for("alice", "user", "bob") == "user_alice_bob"
      assert Conversations.conversation_id_for("alice", "group", "room-1") == "group_room-1"
    end
  end

  describe "put_latest/2 and latest_message/2" do
    test "put_latest writes the conversation pointer when ids are present" do
      state =
        State.default()
        |> Conversations.put_latest(%{"conversationId" => "user_a_b", "id" => "42"})

      assert get_in(state, ["conversation_latest", "user_a_b"]) == "42"
    end

    test "put_latest skips when the message lacks ids" do
      state = State.default()
      assert Conversations.put_latest(state, %{"conversationId" => ""}) == state
      assert Conversations.put_latest(state, %{"conversationId" => "x", "id" => nil}) == state
    end

    test "latest_message follows the pointer, then falls back to the conversation list" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["messages"], %{
          "1" => %{"id" => "1", "conversationId" => conv_id, "text" => "first"},
          "2" => %{"id" => "2", "conversationId" => conv_id, "text" => "second"}
        })
        |> put_in(["conversation_messages", conv_id], ["1", "2"])
        |> put_in(["conversation_latest", conv_id], "2")

      assert Conversations.latest_message(state, conv_id)["text"] == "second"

      # When the pointer is stale, fall back to scanning the ordered list.
      stale = put_in(state, ["conversation_latest", conv_id], "missing")
      assert Conversations.latest_message(stale, conv_id)["text"] == "second"

      # Unknown conversations return nil.
      assert Conversations.latest_message(State.default(), "user_x_y") == nil
    end
  end

  describe "rebuild_latest/1" do
    test "rebuilds the conversation_latest pointer for every conversation that has messages" do
      a = "user_a_b"
      g = "group_room"

      state =
        State.default()
        |> put_in(["messages"], %{
          "1" => %{"id" => "1", "conversationId" => a},
          "2" => %{"id" => "2", "conversationId" => a},
          "9" => %{"id" => "9", "conversationId" => g}
        })
        |> put_in(["conversation_messages"], %{a => ["1", "2"], g => ["9"]})
        |> put_in(["conversation_latest"], %{a => "stale", g => "stale"})

      rebuilt = Conversations.rebuild_latest(state)

      assert rebuilt["conversation_latest"] == %{a => "2", g => "9"}
    end

    test "skips conversations whose listed message ids are all missing" do
      state =
        State.default()
        |> put_in(["messages"], %{"1" => %{"id" => "1", "conversationId" => "user_a_b"}})
        |> put_in(["conversation_messages"], %{
          "user_a_b" => ["1"],
          "group_orphan" => ["missing-1", "missing-2"]
        })

      rebuilt = Conversations.rebuild_latest(state)
      assert rebuilt["conversation_latest"] == %{"user_a_b" => "1"}
    end
  end

  describe "previous_message_id/3" do
    test "returns the message immediately before the cursor" do
      state = put_in(State.default(), ["conversation_messages", "g"], ["1", "2", "3", "4"])

      assert Conversations.previous_message_id(state, "g", "3") == "2"
      assert Conversations.previous_message_id(state, "g", "4") == "3"
    end

    test "returns \"0\" for the head, missing ids, and unknown conversations" do
      state = put_in(State.default(), ["conversation_messages", "g"], ["1", "2", "3"])

      assert Conversations.previous_message_id(state, "g", "1") == "0"
      assert Conversations.previous_message_id(state, "g", "missing") == "0"
      assert Conversations.previous_message_id(State.default(), "g", "1") == "0"
    end
  end

  describe "mark_read/6 and mark_delivered/6" do
    test "mark_read writes the read cursor and resyncs unread counts" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["messages"], %{
          "1" => %{"id" => "1", "sender" => "alice", "conversationId" => conv_id},
          "2" => %{"id" => "2", "sender" => "alice", "conversationId" => conv_id}
        })
        |> put_in(["conversation_messages", conv_id], ["1", "2"])
        |> put_in(["unread_counts", "bob"], %{conv_id => 2})

      {state, response} =
        Conversations.mark_read(state, "bob", "group", "room", "2", "2026-01-01T00:00:00Z")

      assert response == %{
               "success" => true,
               "conversationId" => conv_id,
               "messageId" => "2",
               "readAt" => "2026-01-01T00:00:00Z"
             }

      assert get_in(state, ["reads", "bob", conv_id]) == %{
               "messageId" => "2",
               "readAt" => "2026-01-01T00:00:00Z"
             }

      assert get_in(state, ["unread_counts", "bob", conv_id]) == nil
    end

    test "mark_delivered writes the delivered cursor without touching unread counts" do
      conv_id = "user_alice_bob"
      state = put_in(State.default(), ["unread_counts", "bob"], %{conv_id => 4})

      {state, response} =
        Conversations.mark_delivered(state, "bob", "user", "alice", "7", "2026-01-02T00:00:00Z")

      assert response["conversationId"] == conv_id
      assert response["messageId"] == "7"
      assert response["deliveredAt"] == "2026-01-02T00:00:00Z"

      assert get_in(state, ["delivered", "bob", conv_id]) == %{
               "messageId" => "7",
               "deliveredAt" => "2026-01-02T00:00:00Z"
             }

      assert get_in(state, ["unread_counts", "bob", conv_id]) == 4
    end
  end

  describe "hide/5" do
    test "hides at the latest message in the conversation" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["messages"], %{
          "1" => %{"id" => "1", "conversationId" => conv_id},
          "2" => %{"id" => "2", "conversationId" => conv_id}
        })
        |> put_in(["conversation_messages", conv_id], ["1", "2"])
        |> put_in(["conversation_latest", conv_id], "2")

      {state, response} =
        Conversations.hide(state, "bob", "group", "room", "2026-01-03T00:00:00Z")

      assert response["messageId"] == "2"
      assert response["hiddenAt"] == "2026-01-03T00:00:00Z"
      assert response["conversationId"] == conv_id

      assert get_in(state, ["hidden_conversations", "bob", conv_id]) == %{
               "messageId" => "2",
               "hiddenAt" => "2026-01-03T00:00:00Z"
             }
    end

    test "hides at \"0\" when the conversation has no messages yet" do
      {_state, response} =
        Conversations.hide(State.default(), "bob", "user", "alice", "2026-01-03T00:00:00Z")

      assert response["messageId"] == "0"
    end
  end

  describe "delete_indexes/3" do
    test "removes conversations from the indexes and from user buckets" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["conversation_messages", conv_id], ["1", "2"])
        |> put_in(["conversation_latest", conv_id], "2")
        |> put_in(["reads", "alice"], %{conv_id => %{"messageId" => "1"}})
        |> put_in(["reads", "bob"], %{conv_id => %{"messageId" => "2"}, "other" => %{}})
        |> put_in(["delivered", "alice"], %{conv_id => %{"messageId" => "1"}})

      {state, report} = Conversations.delete_indexes(state, [conv_id], ["reads", "delivered"])

      assert report.conversation_ids == [conv_id]
      assert "alice" in report.touched_user_buckets["reads"]
      assert "bob" in report.touched_user_buckets["reads"]
      assert "alice" in report.touched_user_buckets["delivered"]

      refute Map.has_key?(state["conversation_messages"], conv_id)
      refute Map.has_key?(state["conversation_latest"], conv_id)
      refute get_in(state, ["reads", "alice"])
      refute get_in(state, ["delivered", "alice"])
      assert get_in(state, ["reads", "bob", "other"]) == %{}
    end

    test "is a no-op for blank or duplicate ids" do
      state = put_in(State.default(), ["conversation_messages", "g"], ["1"])

      {result, report} = Conversations.delete_indexes(state, ["", nil, "g", "g"], ["reads"])

      assert report.conversation_ids == ["g"]
      refute Map.has_key?(result["conversation_messages"], "g")
    end
  end

  describe "delete_message_records/2" do
    test "removes messages, reactions, and parent thread lists" do
      state =
        State.default()
        |> put_in(["messages"], %{
          "1" => %{"id" => "1"},
          "2" => %{"id" => "2"}
        })
        |> put_in(["reactions"], %{"1" => %{"+" => %{}}, "2" => %{"+" => %{}}})
        |> put_in(["thread_messages"], %{"1" => ["3"], "9" => ["8"]})

      {state, report} = Conversations.delete_message_records(state, ["1", "2"])

      assert Enum.sort(report.message_ids) == ["1", "2"]
      assert report.thread_ids == ["1"]
      refute Map.has_key?(state["messages"], "1")
      refute Map.has_key?(state["messages"], "2")
      refute Map.has_key?(state["reactions"], "1")
      refute Map.has_key?(state["thread_messages"], "1")
      assert get_in(state, ["thread_messages", "9"]) == ["8"]
    end
  end
end
