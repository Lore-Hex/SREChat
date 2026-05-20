defmodule OpenChatWeb.WSHandlerTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store
  alias OpenChatWeb.WSHandler

  setup do
    Store.reset!()
    :ok
  end

  test "auth event accepts a valid token and returns the CometChat websocket payload" do
    {:reply, {:text, json}, state} =
      WSHandler.websocket_handle(
        {:text,
         Jason.encode!(%{
           "type" => "auth",
           "appId" => "local-app",
           "deviceId" => "device-1",
           "body" => %{"auth" => "uid:alice"}
         })},
        %{uid: nil, token: nil, device_id: nil}
      )

    reply = Jason.decode!(json)

    assert state.uid == "alice"
    assert state.token == "uid:alice"
    assert state.device_id == "device-1"
    assert reply["type"] == "auth"
    assert reply["sender"] == "alice"
    assert reply["body"] == %{"status" => "OK", "code" => "200"}
  end

  test "authenticated sockets resync group subscriptions after join and leave" do
    assert {:ok, _group} = Store.upsert_group(%{"guid" => "ws-sync-room", "type" => "public"})

    {:reply, {:text, _json}, state} =
      WSHandler.websocket_handle(
        {:text,
         Jason.encode!(%{
           "type" => "auth",
           "body" => %{"auth" => "uid:alice"}
         })},
        %{uid: nil, token: nil, device_id: nil}
      )

    refute subscribed?({:group, "ws-sync-room"})
    assert state.groups == MapSet.new()

    assert {:ok, _joined} = Store.join_group("ws-sync-room", "alice", %{})
    assert_receive {:open_chat_system_event, %{"type" => "membership_changed"} = event}
    assert {:ok, state} = WSHandler.websocket_info({:open_chat_system_event, event}, state)

    assert subscribed?({:group, "ws-sync-room"})
    assert state.groups == MapSet.new(["ws-sync-room"])

    assert {:ok, _left} = Store.leave_group("ws-sync-room", "alice")
    assert_receive {:open_chat_system_event, %{"type" => "membership_changed"} = event}
    assert {:ok, state} = WSHandler.websocket_info({:open_chat_system_event, event}, state)

    refute subscribed?({:group, "ws-sync-room"})
    assert state.groups == MapSet.new()
  end

  test "auth event returns an error payload for invalid tokens" do
    {:reply, {:text, json}, state} =
      WSHandler.websocket_handle(
        {:text, Jason.encode!(%{"type" => "auth", "body" => %{"auth" => "bad-token"}})},
        %{uid: nil, token: nil, device_id: nil}
      )

    reply = Jason.decode!(json)

    assert state.uid == nil
    assert reply["type"] == "auth"
    assert reply["sender"] == ""
    assert reply["body"]["status"] == "ERROR"
    assert reply["body"]["code"] == "ERR_NO_AUTH"
  end

  test "ping frames and malformed JSON do not mutate websocket state" do
    state = %{uid: "alice", token: "uid:alice", device_id: "device-1"}

    assert {:reply, {:text, pong}, ^state} =
             WSHandler.websocket_handle({:text, Jason.encode!(%{"type" => "ping"})}, state)

    assert Jason.decode!(pong) == %{"action" => "pong"}
    assert {:reply, :pong, ^state} = WSHandler.websocket_handle(:ping, state)
    assert {:ok, ^state} = WSHandler.websocket_handle({:text, "not-json"}, state)
  end

  test "websocket heartbeat sends protocol pings and keeps the timer replaceable" do
    assert {:ok, state} = WSHandler.websocket_init(%{uid: "alice"})
    assert is_reference(state.heartbeat_ref)

    assert {:reply, :ping, next_state} = WSHandler.websocket_info(:heartbeat, state)
    assert is_reference(next_state.heartbeat_ref)
    refute next_state.heartbeat_ref == state.heartbeat_ref

    assert :ok = WSHandler.terminate(:normal, nil, next_state)
  end

  test "authenticated read receipts update unread counts and broadcast a timestamped receipt" do
    {:ok, message} =
      Store.send_message("bob", %{
        "receiver" => "alice",
        "receiverType" => "user",
        "data" => %{"text" => "please read"}
      })

    assert {:ok, [%{"entityId" => "bob", "count" => 1}]} =
             Store.unread_counts("alice", %{"receiverType" => "user"})

    OpenChat.PubSub.subscribe({:user, "bob"})

    state = %{uid: "alice", token: "uid:alice", device_id: "device-1"}

    assert {:ok, ^state} =
             WSHandler.websocket_handle(
               {:text,
                Jason.encode!(%{
                  "type" => "receipts",
                  "receiver" => "bob",
                  "receiverType" => "user",
                  "body" => %{"messageId" => message["id"], "action" => "read"}
                })},
               state
             )

    assert {:ok, []} = Store.unread_counts("alice", %{"receiverType" => "user"})

    assert_receive {:comet_event, event}
    assert event["type"] == "receipts"
    assert event["receiver"] == "bob"
    assert is_integer(get_in(event, ["body", "timestamp"]))
  end

  test "authenticated delivered receipts update delivered cursors and broadcast once" do
    {:ok, message} =
      Store.send_message("bob", %{
        "receiver" => "alice",
        "receiverType" => "user",
        "data" => %{"text" => "please deliver"}
      })

    OpenChat.PubSub.subscribe({:user, "bob"})
    state = %{uid: "alice", token: "uid:alice", device_id: "device-1"}

    assert {:ok, ^state} =
             WSHandler.websocket_handle(
               {:text,
                Jason.encode!(%{
                  "type" => "receipts",
                  "receiver" => "bob",
                  "receiverType" => "user",
                  "body" => %{"messageId" => message["id"], "action" => "delivered"}
                })},
               state
             )

    assert {:ok, conversation} = Store.conversation("alice", "user", "bob")
    assert conversation["lastDeliveredMessageId"] == to_string(message["id"])

    assert_receive {:comet_event, event}
    assert event["type"] == "receipts"
    assert get_in(event, ["body", "action"]) == "delivered"
    assert get_in(event, ["body", "messageId"]) == to_string(message["id"])
    refute_receive {:comet_event, _event}, 20
  end

  test "receipt events are ignored until the websocket is authenticated" do
    {:ok, message} =
      Store.send_message("bob", %{
        "receiver" => "alice",
        "receiverType" => "user",
        "data" => %{"text" => "still unread"}
      })

    assert {:ok, state} =
             WSHandler.websocket_handle(
               {:text,
                Jason.encode!(%{
                  "type" => "receipts",
                  "receiver" => "bob",
                  "receiverType" => "user",
                  "body" => %{"messageId" => message["id"], "action" => "read"}
                })},
               %{uid: nil, token: nil, device_id: nil}
             )

    assert state.uid == nil

    assert {:ok, [%{"entityId" => "bob", "count" => 1}]} =
             Store.unread_counts("alice", %{"receiverType" => "user"})
  end

  defp subscribed?(key) do
    OpenChat.PubSub
    |> Registry.lookup(key)
    |> Enum.any?(fn {pid, _meta} -> pid == self() end)
  end
end
