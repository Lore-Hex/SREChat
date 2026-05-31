defmodule OpenChat.StoreMessageStateTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.{Conversations, Entities, GroupState, MessageState, State, UserState}

  test "store_with_retention writes message indexes and unread counters" do
    conv_id = Conversations.user_conversation_id("alice", "bob")

    message = %{
      "id" => 10,
      "sender" => "alice",
      "receiver" => "bob",
      "receiverType" => "user",
      "conversationId" => conv_id,
      "data" => %{}
    }

    {state, ops} = MessageState.store_with_retention(State.default(), message)

    assert ops == []
    assert get_in(state, ["messages", "10"]) == message
    assert get_in(state, ["conversation_messages", conv_id]) == ["10"]
    assert get_in(state, ["conversation_latest", conv_id]) == "10"
    assert get_in(state, ["conversation_users", conv_id]) == ["alice", "bob"]
    assert get_in(state, ["user_conversations", "alice"]) == [conv_id]
    assert get_in(state, ["user_conversations", "bob"]) == [conv_id]
    assert get_in(state, ["unread_counts", "bob", conv_id]) == 1
    assert get_in(state, ["unread_counts", "alice", conv_id]) == nil
  end

  test "store tracks thread replies separately from conversation order" do
    conv_id = Conversations.user_conversation_id("alice", "bob")

    state =
      MessageState.store(State.default(), %{
        "id" => 11,
        "sender" => "bob",
        "receiver" => "alice",
        "receiverType" => "user",
        "conversationId" => conv_id,
        "parentId" => "10",
        "data" => %{}
      })

    assert get_in(state, ["conversation_messages", conv_id]) == ["11"]
    assert get_in(state, ["thread_messages", "10"]) == ["11"]
  end

  test "refresh_reactions builds CometChat reaction summary for current user" do
    state =
      State.default()
      |> put_in(["reactions", "10"], %{
        "👍" => %{
          "alice" => %{"uid" => "alice", "reactedBy" => %{"name" => "Alice"}},
          "bob" => %{"uid" => "bob", "reactedBy" => %{"name" => "Bob"}}
        },
        "🔥" => %{}
      })

    message = MessageState.refresh_reactions(state, %{"id" => 10, "data" => %{}}, "bob")

    assert get_in(message, ["data", "reactions"]) == [
             %{"reaction" => "👍", "count" => 2, "reactedByMe" => true}
           ]

    assert get_in(message, [
             "data",
             "metadata",
             "@injected",
             "extensions",
             "reactions",
             "👍"
           ]) == %{
             "alice" => %{"name" => "Alice"},
             "bob" => %{"name" => "Bob"}
           }

    assert get_in(message, [
             "data",
             "metadata",
             "@injected",
             "extensions",
             "profanity-filter"
           ]) == %{"message_clean" => "", "profanity" => "no"}
  end

  test "refresh_reactions removes stale legacy extension metadata when final reaction is removed" do
    message =
      MessageState.refresh_reactions(
        State.default(),
        %{
          "id" => 10,
          "data" => %{
            "metadata" => %{
              "@injected" => %{
                "extensions" => %{
                  "reactions" => %{"👍" => %{"alice" => %{"name" => "Alice"}}}
                }
              }
            }
          }
        },
        "bob"
      )

    refute get_in(message, ["data", "metadata", "@injected", "extensions", "reactions"])
  end

  test "remove_reaction removes empty reaction buckets and preserves other users" do
    state =
      State.default()
      |> put_in(["reactions", "10"], %{
        "👍" => %{"alice" => %{"uid" => "alice"}, "bob" => %{"uid" => "bob"}},
        "🔥" => %{"alice" => %{"uid" => "alice"}}
      })
      |> MessageState.remove_reaction("10", "👍", "alice")
      |> MessageState.remove_reaction("10", "🔥", "alice")

    assert get_in(state, ["reactions", "10", "👍"]) == %{"bob" => %{"uid" => "bob"}}
    refute Map.has_key?(get_in(state, ["reactions", "10"]), "🔥")
  end

  test "message actions and receiver entities are built from typed user and group records" do
    state =
      State.default()
      |> put_user(%{"uid" => "alice", "name" => "Alice", "authToken" => "secret"})
      |> put_group("room", %{"type" => "password", "password" => "group-secret"})
      |> GroupState.add_member("room", "alice", "participant")

    receiver = MessageState.receiver_entity(state, "group", "room")
    refute Map.has_key?(receiver, "password")

    action =
      MessageState.message_action(
        99,
        state,
        "alice",
        %{
          "id" => 10,
          "sender" => "alice",
          "receiver" => "room",
          "receiverType" => "group",
          "conversationId" => Conversations.group_conversation_id("room")
        },
        receiver,
        "edited"
      )

    assert action["category"] == "action"
    assert action["type"] == "message"
    assert get_in(action, ["data", "action"]) == "edited"
    assert get_in(action, ["data", "entities", "by", "entity", "uid"]) == "alice"
    refute Map.has_key?(get_in(action, ["data", "entities", "by", "entity"]), "authToken")
    assert get_in(action, ["data", "entities", "for", "entity", "membersCount"]) == 1
    refute Map.has_key?(get_in(action, ["data", "entities", "for", "entity"]), "password")
  end

  test "group actions include actor target and group entities" do
    state =
      State.default()
      |> put_user(%{"uid" => "owner", "name" => "Owner"})
      |> put_user(%{"uid" => "alice", "name" => "Alice"})
      |> put_group("room")

    action =
      MessageState.group_action(
        100,
        state,
        "owner",
        get_in(state, ["groups", "room"]),
        "alice",
        "joined"
      )

    assert action["receiver"] == "room"
    assert action["type"] == "groupMember"
    assert get_in(action, ["data", "entities", "by", "entity", "uid"]) == "owner"
    assert get_in(action, ["data", "entities", "on", "entity", "uid"]) == "alice"
    assert get_in(action, ["data", "entities", "for", "entity", "guid"]) == "room"
  end

  test "receiver_entity returns public user fallback and counted groups" do
    state =
      State.default()
      |> put_user(%{"uid" => "bob", "authToken" => "secret"})
      |> put_group("room")
      |> GroupState.add_member("room", "bob", "participant")

    assert %{"uid" => "bob"} = user = MessageState.receiver_entity(state, "user", "bob")
    refute Map.has_key?(user, "authToken")

    assert MessageState.receiver_entity(state, "user", "missing")["uid"] == "missing"
    assert MessageState.receiver_entity(state, "group", "room")["membersCount"] == 1
  end

  defp put_user(state, attrs) do
    user = UserState.normalise(attrs)
    UserState.put(state, user)
  end

  defp put_group(state, guid, attrs \\ %{}) do
    group = Entities.group(Map.merge(%{"guid" => guid, "type" => "public"}, attrs))

    state
    |> put_in(["groups", guid], group)
    |> GroupState.ensure_member_map(guid)
  end
end
