defmodule OpenChat.BroadcastTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store
  alias OpenChat.PubSub

  setup do
    Store.reset!()
    :ok
  end

  test "Store.mark_read broadcasts to the peer" do
    # Alice sends a message to Bob
    {:ok, msg} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "hello"}
      })

    # Alice subscribes to her own events to see Bob's read receipt
    PubSub.subscribe({:user, "alice"})

    # Bob marks it as read (simulating REST API call)
    {:ok, _} = Store.mark_read("bob", "user", "alice", msg["id"])

    # Alice should receive a read receipt
    assert_receive {:comet_event,
                    %{
                      "type" => "receipts",
                      "receiver" => "alice",
                      "sender" => "bob",
                      "body" => %{"action" => "read"}
                    }},
                   500
  end

  test "Store.mark_delivered broadcasts to the peer" do
    # Alice sends a message to Bob
    {:ok, msg} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "hello"}
      })

    PubSub.subscribe({:user, "alice"})

    # Bob marks it as delivered
    {:ok, _} = Store.mark_delivered("bob", "user", "alice", msg["id"])

    # Alice should receive a delivered receipt
    assert_receive {:comet_event,
                    %{
                      "type" => "receipts",
                      "receiver" => "alice",
                      "sender" => "bob",
                      "body" => %{"action" => "delivered"}
                    }},
                   500
  end

  test "Store reactions broadcast edited actions before reaction detail events" do
    {:ok, msg} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "react fast"}
      })

    PubSub.subscribe({:user, "alice"})

    on_exit(fn ->
      PubSub.unsubscribe({:user, "alice"})
    end)

    {:ok, _} = Store.add_reaction("bob", msg["id"], "👍")

    assert_receive {:comet_event,
                    %{
                      "type" => "message",
                      "sender" => "bob",
                      "body" => %{
                        "category" => "action",
                        "data" => %{
                          "action" => "edited",
                          "entities" => %{
                            "on" => %{
                              "entity" => %{
                                "id" => id,
                                "updatedAt" => updated_at,
                                "data" => %{
                                  "reactions" => [%{"reaction" => "👍", "count" => 1}]
                                }
                              }
                            }
                          }
                        }
                      }
                    }},
                   500

    assert to_string(id) == to_string(msg["id"])
    assert updated_at == msg["updatedAt"]

    assert_receive {:comet_event,
                    %{
                      "type" => "reaction",
                      "sender" => "bob",
                      "body" => %{"messageId" => message_id, "reaction" => "👍"}
                    }},
                   500

    assert to_string(message_id) == to_string(msg["id"])
  end
end
