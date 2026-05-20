defmodule OpenChatWeb.WSHandler do
  @moduledoc false
  @behaviour :cowboy_websocket

  alias OpenChat.{Config, Store}

  @impl true
  def init(req, _state),
    do: {:cowboy_websocket, req, %{uid: nil, token: nil, device_id: nil, groups: MapSet.new()}}

  @impl true
  def websocket_init(state), do: {:ok, schedule_heartbeat(state)}

  @impl true
  def websocket_handle({:text, json}, state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "auth"} = event} ->
        handle_auth(event, state)

      {:ok, %{"type" => "receipts"} = event} ->
        handle_receipt(event, state)

      {:ok, %{"type" => "ping"}} ->
        {:reply, {:text, Jason.encode!(%{"action" => "pong"})}, state}

      {:ok, %{"action" => "ping"}} ->
        {:reply, {:text, Jason.encode!(%{"action" => "pong"})}, state}

      {:ok, _other} ->
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  def websocket_handle(:ping, state), do: {:reply, :pong, state}
  def websocket_handle(_frame, state), do: {:ok, state}

  @impl true
  def websocket_info({:open_chat_system_event, %{"type" => "membership_changed"}}, state),
    do: {:ok, sync_group_subscriptions(state)}

  def websocket_info({:comet_event, event}, state),
    do: {:reply, {:text, Jason.encode!(event)}, state}

  def websocket_info(:heartbeat, state),
    do: {:reply, :ping, schedule_heartbeat(state)}

  def websocket_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _req, state) do
    cancel_heartbeat(state)
    :ok
  end

  defp schedule_heartbeat(state) do
    cancel_heartbeat(state)
    Map.put(state, :heartbeat_ref, Process.send_after(self(), :heartbeat, 25_000))
  end

  defp cancel_heartbeat(%{heartbeat_ref: ref}) when is_reference(ref),
    do: Process.cancel_timer(ref)

  defp cancel_heartbeat(_state), do: :ok

  defp handle_auth(event, state) do
    body = event["body"] || %{}
    token = body["auth"] || event["auth"] || body["token"] || event["token"]
    device_id = event["deviceId"] || body["deviceId"] || ""

    case Store.authenticate(token) do
      {:ok, user} ->
        uid = user["uid"]
        state = replace_user_subscription(state, uid)
        state = sync_group_subscriptions(%{state | uid: uid})

        reply = %{
          "appId" => event["appId"] || Config.app_id(),
          "receiver" => event["receiver"] || "",
          "receiverType" => event["receiverType"] || "",
          "deviceId" => device_id,
          "type" => "auth",
          "sender" => uid,
          "body" => %{"status" => "OK", "code" => "200"}
        }

        {:reply, {:text, Jason.encode!(reply)},
         %{state | uid: uid, token: token, device_id: device_id}}

      {:error, error} ->
        reply = %{
          "appId" => event["appId"] || Config.app_id(),
          "receiver" => event["receiver"] || "",
          "receiverType" => event["receiverType"] || "",
          "deviceId" => device_id,
          "type" => "auth",
          "sender" => event["sender"] || "",
          "body" => %{"status" => "ERROR", "code" => error["code"] || "401"}
        }

        {:reply, {:text, Jason.encode!(reply)}, state}
    end
  end

  defp handle_receipt(event, %{uid: uid} = state) when is_binary(uid) and uid != "" do
    body = event["body"] || %{}
    receiver = event["receiver"] || body["receiver"]
    receiver_type = event["receiverType"] || body["receiverType"] || "user"
    message_id = body["messageId"] || body["id"] || "0"
    action = body["action"] || "read"

    delivered? = action in ["delivered", "deliver", "message_delivered"]

    cond do
      action == "read" ->
        Store.mark_read(uid, receiver_type, receiver, message_id)

      delivered? ->
        Store.mark_delivered(uid, receiver_type, receiver, message_id)

      true ->
        :ok
    end

    {:ok, state}
  end

  defp handle_receipt(_event, state), do: {:ok, state}

  defp replace_user_subscription(state, uid) do
    case Map.get(state, :uid) do
      previous_uid when is_binary(previous_uid) and previous_uid != "" and previous_uid != uid ->
        OpenChat.PubSub.unsubscribe({:user, previous_uid})

      _other ->
        :ok
    end

    OpenChat.PubSub.unsubscribe({:user, uid})
    subscribe({:user, uid})
    state
  end

  defp sync_group_subscriptions(%{uid: uid} = state) when is_binary(uid) and uid != "" do
    current = Map.get(state, :groups) || MapSet.new()

    case Store.groups_for_user(uid) do
      {:ok, groups} ->
        desired = groups |> Enum.map(& &1["guid"]) |> MapSet.new()

        desired
        |> MapSet.difference(current)
        |> Enum.each(&subscribe({:group, &1}))

        current
        |> MapSet.difference(desired)
        |> Enum.each(&OpenChat.PubSub.unsubscribe({:group, &1}))

        Map.put(state, :groups, desired)

      _other ->
        state
    end
  end

  defp sync_group_subscriptions(state), do: state

  defp subscribe(key) do
    case OpenChat.PubSub.subscribe(key) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end
end
