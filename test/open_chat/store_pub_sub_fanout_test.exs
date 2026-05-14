defmodule OpenChat.StorePubSubFanoutTest do
  use ExUnit.Case, async: false

  alias OpenChat.PubSub
  alias OpenChat.Store.{GroupState, PubSubFanout, State}

  test "recipient keys target both sides of direct messages" do
    message = %{"receiverType" => "user", "sender" => "alice", "receiver" => "bob"}

    assert PubSubFanout.recipient_keys(State.default(), message) == [
             {:user, "bob"},
             {:user, "alice"}
           ]
  end

  test "group fanout targets members until the room crosses the fanout limit" do
    with_open_chat_env(%{group_unread_fanout_limit: 2}, fn ->
      state =
        State.default()
        |> put_in(["members", "room"], %{"alice" => %{}, "bob" => %{}})

      assert PubSubFanout.group_recipient_keys(state, "room", except: "alice") == [
               {:user, "bob"}
             ]

      state = put_in(state, ["members", "room", "carol"], %{})

      assert PubSubFanout.group_recipient_keys(state, "room", except: "alice") == [
               {:group, "room"}
             ]
    end)
  end

  test "message broadcasts carry CometChat-compatible event envelopes" do
    PubSub.subscribe({:user, "bob"})

    on_exit(fn ->
      PubSub.unsubscribe({:user, "bob"})
    end)

    PubSubFanout.message(State.default(), %{
      "id" => 1,
      "sender" => "alice",
      "receiver" => "bob",
      "receiverType" => "user"
    })

    assert_receive {:comet_event,
                    %{
                      "type" => "message",
                      "sender" => "alice",
                      "receiver" => "bob",
                      "receiverType" => "user",
                      "body" => %{"id" => 1}
                    }}
  end

  test "group action and membership changes publish to tuple keys" do
    state =
      State.default()
      |> put_in(["members", "room"], %{"alice" => %{}, "bob" => %{}})

    PubSub.subscribe({:user, "bob"})

    on_exit(fn ->
      PubSub.unsubscribe({:user, "bob"})
    end)

    PubSubFanout.group_action(
      state,
      "room",
      %{"sender" => "alice", "receiver" => "room", "receiverType" => "group", "id" => 9},
      except: "alice"
    )

    assert_receive {:comet_event, %{"type" => "message", "body" => %{"id" => 9}}}

    PubSubFanout.membership_changed(["bob", "", nil, "bob"])
    assert_receive {:open_chat_system_event, %{"type" => "membership_changed"}}
  end

  test "reaction and receipt broadcasts use their dedicated event types" do
    PubSub.subscribe({:user, "alice"})
    PubSub.subscribe({:user, "bob"})

    on_exit(fn ->
      PubSub.unsubscribe({:user, "alice"})
      PubSub.unsubscribe({:user, "bob"})
    end)

    PubSubFanout.reaction(
      State.default(),
      %{"id" => 1, "sender" => "alice", "receiver" => "bob", "receiverType" => "user"},
      %{"id" => 2, "messageId" => 1, "reaction" => "👍", "reactedBy" => %{}, "reactedAt" => 3},
      "message_reaction_added",
      "bob"
    )

    assert_receive {:comet_event, %{"type" => "reaction", "sender" => "bob"}}

    PubSubFanout.receipt(
      %{"messageId" => "1", "conversationId" => "user_alice_bob", "readAt" => 4},
      "alice",
      "user",
      "bob",
      "read"
    )

    assert_receive {:comet_event, %{"type" => "receipts", "body" => %{"action" => "read"}}}
  end

  test "fanout works with real group membership state" do
    state =
      State.default()
      |> put_in(["groups", "room"], %{"guid" => "room"})
      |> GroupState.ensure_member_map("room")
      |> GroupState.add_member("room", "alice", "participant")
      |> GroupState.add_member("room", "bob", "participant")

    assert PubSubFanout.recipient_keys(
             state,
             %{"receiverType" => "group", "sender" => "alice", "receiver" => "room"}
           ) == [{:user, "bob"}]
  end

  defp with_open_chat_env(overrides, fun) do
    old = Map.new(overrides, fn {key, _value} -> {key, Application.get_env(:open_chat, key)} end)

    Enum.each(overrides, fn {key, value} ->
      Application.put_env(:open_chat, key, value)
    end)

    try do
      fun.()
    after
      Enum.each(old, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:open_chat, key),
          else: Application.put_env(:open_chat, key, value)
      end)
    end
  end
end
