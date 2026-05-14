defmodule OpenChat.PubSubTest do
  use ExUnit.Case, async: false

  alias OpenChat.PubSub

  setup do
    # Registry is started by the application, so it should be available in tests.
    # If not, we might need to start it.
    # Application.ensure_all_started(:open_chat) is already done in test_helper.
    :ok
  end

  test "subscribe and broadcast" do
    PubSub.subscribe("user_alice")

    PubSub.broadcast("user_alice", %{"text" => "hi"})

    assert_receive {:comet_event, %{"text" => "hi"}}

    PubSub.unsubscribe("user_alice")
    PubSub.broadcast("user_alice", %{"text" => "bye"})

    refute_receive {:comet_event, %{"text" => "bye"}}, 100
  end

  test "broadcast to multiple keys" do
    PubSub.subscribe("u1")
    PubSub.subscribe("u2")

    PubSub.broadcast(["u1", "u2"], %{"msg" => "multi"})

    assert_receive {:comet_event, %{"msg" => "multi"}}
    # Since same process subscribed to both, it might receive twice?
    # Actually Registry.dispatch calls send for each entry.
    # If same PID is registered for multiple keys, it receives for each.
  end

  test "system broadcast" do
    PubSub.subscribe("sys")
    PubSub.broadcast_system("sys", %{"type" => "reload"})

    assert_receive {:open_chat_system_event, %{"type" => "reload"}}
  end
end
