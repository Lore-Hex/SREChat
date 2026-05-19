defmodule OpenChat.Store.UnreadTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.{State, Unread}

  describe "message_created/2" do
    test "increments unread for every group member except the sender" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["members", "room"], %{"alice" => %{}, "bob" => %{}, "carol" => %{}})

      message = %{
        "id" => "1",
        "sender" => "alice",
        "receiver" => "room",
        "receiverType" => "group",
        "conversationId" => conv_id,
        "data" => %{}
      }

      state = Unread.message_created(state, message)

      assert Unread.count(state, "bob", conv_id) == 1
      assert Unread.count(state, "carol", conv_id) == 1
      assert Unread.count(state, "alice", conv_id) == 0
    end

    test "increments unread for the recipient of a direct message" do
      conv_id = "user_alice_bob"

      state = State.default()

      message = %{
        "id" => "2",
        "sender" => "alice",
        "receiver" => "bob",
        "receiverType" => "user",
        "conversationId" => conv_id,
        "data" => %{}
      }

      state = Unread.message_created(state, message)

      assert Unread.count(state, "bob", conv_id) == 1
      assert Unread.count(state, "alice", conv_id) == 0
    end

    test "skips counting when incrementUnreadCount metadata says false" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["members", "room"], %{"alice" => %{}, "bob" => %{}})

      message = fn flag ->
        %{
          "id" => "1",
          "sender" => "alice",
          "receiver" => "room",
          "receiverType" => "group",
          "conversationId" => conv_id,
          "data" => %{"metadata" => %{"incrementUnreadCount" => flag}}
        }
      end

      for flag <- [false, "false", "FALSE", 0, "0"] do
        state = Unread.message_created(state, message.(flag))
        assert Unread.count(state, "bob", conv_id) == 0, "did not skip for #{inspect(flag)}"
      end

      state = Unread.message_created(state, message.(true))
      assert Unread.count(state, "bob", conv_id) == 1
    end

    test "skips counting for already-deleted messages and messages without a conversation id" do
      base = State.default() |> put_in(["members", "room"], %{"alice" => %{}, "bob" => %{}})

      deleted = %{
        "id" => "1",
        "sender" => "alice",
        "receiver" => "room",
        "receiverType" => "group",
        "conversationId" => "group_room",
        "deletedAt" => "2026-01-01T00:00:00Z",
        "data" => %{}
      }

      missing_conv = %{
        "id" => "2",
        "sender" => "alice",
        "receiver" => "room",
        "receiverType" => "group",
        "conversationId" => "",
        "data" => %{}
      }

      assert Unread.count(Unread.message_created(base, deleted), "bob", "group_room") == 0
      assert Unread.count(Unread.message_created(base, missing_conv), "bob", "group_room") == 0
    end
  end

  describe "message_deleted/2" do
    test "decrements unread for participants who had not read the message yet" do
      conv_id = "user_alice_bob"

      state =
        State.default()
        |> put_in(["unread_counts", "bob"], %{conv_id => 3})

      message = %{
        "id" => "5",
        "sender" => "alice",
        "receiver" => "bob",
        "receiverType" => "user",
        "conversationId" => conv_id,
        "data" => %{}
      }

      state = Unread.message_deleted(state, message)
      assert Unread.count(state, "bob", conv_id) == 2
    end

    test "does not change unread when the participant already read past the deleted message" do
      conv_id = "user_alice_bob"

      state =
        State.default()
        |> put_in(["reads", "bob"], %{conv_id => %{"messageId" => "10"}})
        |> put_in(["unread_counts", "bob"], %{conv_id => 0})

      message = %{
        "id" => "5",
        "sender" => "alice",
        "receiver" => "bob",
        "receiverType" => "user",
        "conversationId" => conv_id,
        "data" => %{}
      }

      state = Unread.message_deleted(state, message)
      assert Unread.count(state, "bob", conv_id) == 0
    end

    test "never goes below zero" do
      conv_id = "user_alice_bob"

      state =
        State.default()
        |> put_in(["unread_counts", "bob"], %{conv_id => 0})

      message = %{
        "id" => "5",
        "sender" => "alice",
        "receiver" => "bob",
        "receiverType" => "user",
        "conversationId" => conv_id,
        "data" => %{}
      }

      state = Unread.message_deleted(state, message)
      assert Unread.count(state, "bob", conv_id) == 0
    end
  end

  describe "mark_read/4 and count_after/4" do
    test "mark_read replaces the unread count with the messages-after-cursor count" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["messages"], %{
          "1" => %{"id" => "1", "sender" => "alice", "conversationId" => conv_id},
          "2" => %{"id" => "2", "sender" => "alice", "conversationId" => conv_id},
          "3" => %{"id" => "3", "sender" => "alice", "conversationId" => conv_id}
        })
        |> put_in(["conversation_messages", conv_id], ["1", "2", "3"])
        |> put_in(["unread_counts", "bob"], %{conv_id => 3})

      state = Unread.mark_read(state, "bob", conv_id, "2")
      assert Unread.count(state, "bob", conv_id) == 1

      state = Unread.mark_read(state, "bob", conv_id, "3")
      assert Unread.count(state, "bob", conv_id) == 0
      # 0 counts are pruned from the bucket
      assert get_in(state, ["unread_counts", "bob"]) == nil
    end

    test "count_after ignores deleted messages and the viewer's own sends" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["messages"], %{
          "1" => %{"id" => "1", "sender" => "alice", "conversationId" => conv_id},
          "2" => %{
            "id" => "2",
            "sender" => "alice",
            "conversationId" => conv_id,
            "deletedAt" => "2026-01-01T00:00:00Z"
          },
          "3" => %{"id" => "3", "sender" => "bob", "conversationId" => conv_id},
          "4" => %{"id" => "4", "sender" => "alice", "conversationId" => conv_id}
        })
        |> put_in(["conversation_messages", conv_id], ["1", "2", "3", "4"])

      # Bob has not read anything → counts messages with id > 0, sent by others, not deleted.
      assert Unread.count_after(state, "bob", conv_id, "0") == 2
      # Bob has read "3" → only message 4 remains unread.
      assert Unread.count_after(state, "bob", conv_id, "3") == 1
    end
  end

  describe "remove_conversation/3" do
    test "drops the conversation entry and compacts empty buckets" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["unread_counts", "bob"], %{conv_id => 5, "other" => 2})

      state = Unread.remove_conversation(state, "bob", conv_id)
      assert get_in(state, ["unread_counts", "bob"]) == %{"other" => 2}

      state = Unread.remove_conversation(state, "bob", "other")
      assert state["unread_counts"] == %{}
    end
  end

  describe "rebuild/1" do
    test "recomputes the unread counts bucket from messages and reads" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["messages"], %{
          "1" => %{"id" => "1", "sender" => "alice", "conversationId" => conv_id},
          "2" => %{"id" => "2", "sender" => "alice", "conversationId" => conv_id}
        })
        |> put_in(["conversation_messages", conv_id], ["1", "2"])
        |> put_in(["conversation_users", conv_id], ["alice", "bob"])
        |> put_in(["reads", "bob"], %{conv_id => %{"messageId" => "1"}})
        |> put_in(["unread_counts"], %{"bob" => %{conv_id => 99}, "alice" => %{conv_id => 99}})

      state = Unread.rebuild(state)
      assert Unread.count(state, "bob", conv_id) == 1
      # alice's own sends never contribute to her own unread bucket
      assert Unread.count(state, "alice", conv_id) == 0
    end
  end
end
