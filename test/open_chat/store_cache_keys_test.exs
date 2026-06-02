defmodule OpenChat.Store.CacheKeysTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.CacheKeys

  test "pubsub user and group keys expand to the same Redis buckets Store refreshes" do
    assert CacheKeys.for_pubsub_keys([{:user, "alice"}, {:group, "room"}, :ignored]) == [
             {"users", "alice"},
             {"user_groups", "alice"},
             {"user_conversations", "alice"},
             {"unread_counts", "alice"},
             {"reads", "alice"},
             {"delivered", "alice"},
             {"hidden_conversations", "alice"},
             {"blocks", "alice"},
             {"groups", "room"},
             {"members", "room"},
             {"banned", "room"},
             {"conversation_messages", "group_room"},
             {"conversation_latest", "group_room"},
             {"conversation_users", "group_room"}
           ]
  end

  test "message events refresh message indexes participants parents and action subjects" do
    event = %{
      "type" => "message",
      "body" => %{
        "id" => "12",
        "sender" => "alice",
        "receiverType" => "group",
        "receiver" => "room",
        "conversationId" => "group_room",
        "parentId" => "9",
        "muid" => "client-1",
        "data" => %{
          "entities" => %{
            "on" => %{"entity" => %{"id" => "8"}}
          }
        }
      }
    }

    assert CacheKeys.for_event(event) == [
             {"messages", "12"},
             {"reactions", "12"},
             {"conversation_messages", "group_room"},
             {"conversation_latest", "group_room"},
             {"conversation_users", "group_room"},
             {"message_muids", "client-1"},
             {"messages", "9"},
             {"thread_messages", "9"},
             {"users", "alice"},
             {"user_groups", "alice"},
             {"user_conversations", "alice"},
             {"unread_counts", "alice"},
             {"reads", "alice"},
             {"delivered", "alice"},
             {"hidden_conversations", "alice"},
             {"blocks", "alice"},
             {"groups", "room"},
             {"members", "room"},
             {"banned", "room"},
             {"conversation_messages", "group_room"},
             {"conversation_latest", "group_room"},
             {"conversation_users", "group_room"},
             {"messages", "8"},
             {"reactions", "8"}
           ]
  end

  test "reaction and receipt events refresh their scoped records" do
    assert CacheKeys.for_event(%{
             "type" => "reaction",
             "body" => %{"messageId" => "42"}
           }) == [{"messages", "42"}, {"reactions", "42"}]

    assert CacheKeys.for_event(%{
             "type" => "receipts",
             "sender" => "alice",
             "receiverType" => "user",
             "receiver" => "bob",
             "body" => %{"messageId" => "42"}
           }) == [
             {"reads", "alice"},
             {"delivered", "alice"},
             {"unread_counts", "alice"},
             {"conversation_latest", "user_alice_bob"},
             {"conversation_users", "user_alice_bob"}
           ]
  end
end
