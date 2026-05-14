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
end
