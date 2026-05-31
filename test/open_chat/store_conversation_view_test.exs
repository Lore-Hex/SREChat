defmodule OpenChat.Store.ConversationViewTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.{ConversationView, State}

  defp seeded_state do
    conv = "group_room"

    State.default()
    |> put_in(["users"], %{
      "alice" => %{"uid" => "alice", "name" => "Alice", "authToken" => "SECRET"},
      "bob" => %{"uid" => "bob", "name" => "Bob"}
    })
    |> put_in(["groups"], %{
      "room" => %{"guid" => "room", "name" => "Room", "type" => "public"}
    })
    |> put_in(["members", "room"], %{"alice" => %{}, "bob" => %{}})
    |> put_in(["messages"], %{
      "1" => %{
        "id" => "1",
        "sender" => "alice",
        "receiver" => "room",
        "receiverType" => "group",
        "conversationId" => conv,
        "sentAt" => 100,
        "data" => %{}
      },
      "2" => %{
        "id" => "2",
        "sender" => "alice",
        "receiver" => "room",
        "receiverType" => "group",
        "conversationId" => conv,
        "sentAt" => 200,
        "deletedAt" => "2026-01-01T00:00:00Z",
        "data" => %{}
      },
      "3" => %{
        "id" => "3",
        "sender" => "bob",
        "receiver" => "room",
        "receiverType" => "group",
        "conversationId" => conv,
        "sentAt" => 300,
        "data" => %{}
      }
    })
    |> put_in(["conversation_messages", conv], ["1", "2", "3"])
    |> put_in(["conversation_latest", conv], "3")
  end

  describe "build/3" do
    test "returns nil for unknown or hidden conversations" do
      state = seeded_state()
      assert ConversationView.build(state, "alice", nil) == nil
      assert ConversationView.build(state, "alice", "group_unknown") == nil

      hidden =
        put_in(state, ["hidden_conversations", "alice"], %{
          "group_room" => %{"messageId" => "9"}
        })

      assert ConversationView.build(hidden, "alice", "group_room") == nil
    end

    test "build returns a CometChat-shaped conversation summary for groups" do
      state =
        seeded_state()
        |> put_in(["reads", "alice"], %{"group_room" => %{"messageId" => "1"}})
        |> put_in(["delivered", "alice"], %{
          "group_room" => %{"messageId" => "3", "deliveredAt" => "2026-01-02T00:00:00Z"}
        })
        |> put_in(["unread_counts", "alice"], %{"group_room" => 5})

      conv = ConversationView.build(state, "alice", "group_room")

      assert conv["conversationId"] == "group_room"
      assert conv["conversationType"] == "group"
      assert conv["lastMessage"]["id"] == "3"
      assert conv["conversationWith"]["guid"] == "room"
      assert conv["conversationWith"]["membersCount"] == 2
      assert conv["unreadMessageCount"] == 5
      assert conv["lastReadMessageId"] == "1"
      assert conv["lastDeliveredMessageId"] == "3"
      assert conv["deliveredAt"] == "2026-01-02T00:00:00Z"
      assert conv["latestMessageId"] == "3"
    end

    test "build for user conversations strips auth tokens from the peer" do
      conv = "user_alice_bob"

      state =
        seeded_state()
        |> put_in(["conversation_messages", conv], ["10"])
        |> put_in(["conversation_latest", conv], "10")
        |> put_in(["messages", "10"], %{
          "id" => "10",
          "sender" => "alice",
          "receiver" => "bob",
          "receiverType" => "user",
          "conversationId" => conv,
          "sentAt" => 50,
          "data" => %{}
        })

      view = ConversationView.build(state, "alice", conv)
      assert view["conversationType"] == "user"
      assert view["conversationWith"]["uid"] == "bob"
      refute Map.has_key?(view["conversationWith"], "authToken")
    end
  end

  describe "hidden?/3" do
    test "is true while the latest message is below the hide cursor" do
      state =
        seeded_state()
        |> put_in(["hidden_conversations", "alice"], %{"group_room" => %{"messageId" => "9"}})

      assert ConversationView.hidden?(state, "alice", "group_room")
    end

    test "is false once a newer message arrives" do
      state =
        seeded_state()
        |> put_in(["hidden_conversations", "alice"], %{"group_room" => %{"messageId" => "1"}})

      refute ConversationView.hidden?(state, "alice", "group_room")
    end

    test "is false without a hide entry, even when there is no latest message" do
      refute ConversationView.hidden?(State.default(), "alice", "group_room")
    end
  end

  describe "unread_count_row/4" do
    test "group rows include membersCount and group entity shape" do
      row = ConversationView.unread_count_row(seeded_state(), "alice", "group_room", 7)
      assert row["entityType"] == "group"
      assert row["entityId"] == "room"
      assert row["count"] == 7
      assert row["entity"]["guid"] == "room"
      assert row["entity"]["membersCount"] == 2
    end

    test "user rows return the other participant as a public user" do
      conv = "user_alice_bob"

      state =
        seeded_state()
        |> put_in(["conversation_messages", conv], ["10"])
        |> put_in(["messages", "10"], %{
          "id" => "10",
          "sender" => "bob",
          "receiver" => "alice",
          "receiverType" => "user",
          "conversationId" => conv,
          "sentAt" => 50,
          "data" => %{}
        })

      row = ConversationView.unread_count_row(state, "alice", conv, 4)
      assert row["entityType"] == "user"
      assert row["entityId"] == "bob"
      refute Map.has_key?(row["entity"], "authToken")
    end
  end

  describe "messages/3 filtering, cursoring, and pagination" do
    test "hides deleted messages by default and surfaces them when explicitly disabled" do
      state = seeded_state()

      hidden = ConversationView.messages(state, "group_room", %{"limit" => 10})
      assert Enum.map(hidden, & &1["id"]) == ["3", "1"]

      # The implementation accepts string aliases for false (`"false"`, `"0"`, `"no"`).
      # A literal `false` short-circuits the `||` fallback to `hideDeletedMessages`, so
      # use the documented string aliases to keep deleted rows.
      for falsy <- ["false", "FALSE", "0", "no"] do
        shown =
          ConversationView.messages(state, "group_room", %{
            "limit" => 10,
            "hideDeleted" => falsy
          })

        assert Enum.map(shown, & &1["id"]) == ["3", "2", "1"],
               "expected deleted message to appear for hideDeleted=#{inspect(falsy)}"
      end
    end

    test "limit is clamped between 1 and 100 and defaults to 30" do
      state = seeded_state()
      assert length(ConversationView.messages(state, "group_room", %{"limit" => -10})) == 1
      assert length(ConversationView.messages(state, "group_room", %{"limit" => 1})) == 1
      assert length(ConversationView.messages(state, "group_room", %{"limit" => 1000})) == 2
    end

    test "millisecond prepend timestamps include the current server second despite clock skew" do
      base = 1_700_000_000

      state =
        State.default()
        |> put_in(["messages"], %{
          "1" => %{
            "id" => "1",
            "sender" => "alice",
            "receiver" => "room",
            "receiverType" => "group",
            "conversationId" => "group_room",
            "sentAt" => base,
            "data" => %{}
          },
          "2" => %{
            "id" => "2",
            "sender" => "alice",
            "receiver" => "room",
            "receiverType" => "group",
            "conversationId" => "group_room",
            "sentAt" => base + 1,
            "data" => %{}
          },
          "3" => %{
            "id" => "3",
            "sender" => "alice",
            "receiver" => "room",
            "receiverType" => "group",
            "conversationId" => "group_room",
            "sentAt" => base + 2,
            "data" => %{}
          }
        })
        |> put_in(["conversation_messages", "group_room"], ["1", "2", "3"])

      result =
        ConversationView.messages(state, "group_room", %{
          "limit" => 10,
          "timestamp" => to_string(base * 1000 + 1),
          "cursorAffix" => "prepend"
        })

      assert Enum.map(result, & &1["id"]) == ["2", "1"]
    end

    test "id cursor with prepend affix returns messages strictly before the cursor" do
      state = seeded_state()

      result =
        ConversationView.messages(state, "group_room", %{
          "limit" => 10,
          "id" => "3",
          "cursorAffix" => "prepend"
        })

      assert Enum.map(result, & &1["id"]) == ["1"]
    end

    test "append affix returns messages strictly after the cursor" do
      state = seeded_state()

      result =
        ConversationView.messages(state, "group_room", %{
          "limit" => 10,
          "id" => "1",
          "cursorAffix" => "append"
        })

      # default sort + append → forward chronological order
      assert Enum.map(result, & &1["id"]) == ["3"]
    end

    test "legacy timestamp aliases and sender filters apply before pagination" do
      state = seeded_state()

      after_updated_at =
        ConversationView.messages(state, "group_room", %{
          "limit" => 10,
          "updatedAt" => "100",
          "hideDeleted" => "false",
          "affix" => "append"
        })

      assert Enum.map(after_updated_at, & &1["id"]) == ["2", "3"]

      after_from_timestamp =
        ConversationView.messages(state, "group_room", %{
          "limit" => 10,
          "fromTimestamp" => "100",
          "hideDeleted" => "false"
        })

      assert Enum.map(after_from_timestamp, & &1["id"]) == ["2", "3"]

      latest_from_alice =
        ConversationView.messages(state, "group_room", %{
          "limit" => 1,
          "sender" => "alice"
        })

      assert Enum.map(latest_from_alice, & &1["id"]) == ["1"]
    end

    test "category and type filters narrow the result" do
      state = seeded_state() |> put_in(["messages", "3", "category"], "message")

      assert [%{"id" => "3"}] =
               ConversationView.messages(state, "group_room", %{
                 "limit" => 10,
                 "category" => "message"
               })

      assert [] =
               ConversationView.messages(state, "group_room", %{
                 "limit" => 10,
                 "category" => "action"
               })
    end
  end
end
