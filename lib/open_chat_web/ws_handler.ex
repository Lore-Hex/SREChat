defmodule OpenChatWeb.WSHandler do
  @moduledoc false
  @behaviour :cowboy_websocket

  require Logger

  alias OpenChat.{Config, Observability, Store}

  @auth_timeout_ms 30_000

  @impl true
  def init(req, _state) do
    if websocket_origin_allowed?(req) do
      Observability.record_ws("accepted")
      {:cowboy_websocket, req, %{uid: nil, token: nil, device_id: nil, groups: MapSet.new()}}
    else
      Observability.record_ws("origin_rejected")

      body =
        Jason.encode!(%{
          "error" => %{"code" => "ERR_FORBIDDEN", "message" => "Origin is not allowed."}
        })

      req =
        :cowboy_req.reply(
          403,
          %{"content-type" => "application/json; charset=utf-8"},
          body,
          req
        )

      {:ok, req, %{}}
    end
  end

  @doc false
  def websocket_origin_allowed?(req) do
    case request_origin(req) do
      nil -> true
      "" -> true
      origin -> Config.cors_allowed_origin(origin) != nil
    end
  end

  @impl true
  def websocket_init(state) do
    Observability.add_gauge("ws.active", 1)
    {:ok, state |> schedule_heartbeat() |> schedule_auth_timeout()}
  end

  @impl true
  def websocket_handle({:text, json}, state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "auth"} = event} ->
        handle_auth(event, state)

      {:ok, %{"type" => "receipts"} = event} ->
        handle_receipt(event, state)

      {:ok, %{"type" => "ping"}} ->
        Observability.record_ws("client_ping")
        {:reply, {:text, Jason.encode!(%{"action" => "pong"})}, state}

      {:ok, %{"action" => "ping"}} ->
        Observability.record_ws("client_ping")
        {:reply, {:text, Jason.encode!(%{"action" => "pong"})}, state}

      {:ok, _other} ->
        Observability.record_ws("ignored_text")
        {:ok, state}

      _ ->
        Observability.record_ws("malformed_text")
        {:ok, state}
    end
  end

  def websocket_handle(:ping, state) do
    Observability.record_ws("protocol_ping")
    {:reply, :pong, state}
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  @impl true
  def websocket_info({:open_chat_system_event, %{"type" => "membership_changed"}}, state),
    do: {:ok, sync_group_subscriptions(state)}

  def websocket_info({:comet_event, event}, state) do
    Observability.record_ws("event_forwarded", %{"type" => event["type"]})
    {:reply, {:text, Jason.encode!(event)}, state}
  end

  def websocket_info(:heartbeat, state) do
    case Config.websocket_heartbeat_ms() do
      interval when is_integer(interval) and interval > 0 ->
        Observability.record_ws("heartbeat")
        {:reply, :ping, schedule_heartbeat(state)}

      _other ->
        {:ok, schedule_heartbeat(state)}
    end
  end

  def websocket_info(:auth_timeout, %{uid: uid} = state) when uid in [nil, ""] do
    Observability.record_ws("auth_timeout")
    {:stop, state}
  end

  def websocket_info(:auth_timeout, state), do: {:ok, state}

  def websocket_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(reason, _req, state) do
    cancel_heartbeat(state)
    cancel_auth_timeout(state)
    Observability.add_gauge("ws.active", -1)

    Observability.record_ws("closed", %{
      "reason" => close_reason(reason),
      "authenticated" => authenticated?(state)
    })

    :ok
  end

  defp schedule_heartbeat(state) do
    cancel_heartbeat(state)

    case Config.websocket_heartbeat_ms() do
      interval when is_integer(interval) and interval > 0 ->
        Map.put(state, :heartbeat_ref, Process.send_after(self(), :heartbeat, interval))

      _other ->
        Map.delete(state, :heartbeat_ref)
    end
  end

  defp cancel_heartbeat(%{heartbeat_ref: ref}) when is_reference(ref),
    do: Process.cancel_timer(ref)

  defp cancel_heartbeat(_state), do: :ok

  defp schedule_auth_timeout(%{uid: uid} = state) when uid in [nil, ""] do
    cancel_auth_timeout(state)
    Map.put(state, :auth_timeout_ref, Process.send_after(self(), :auth_timeout, @auth_timeout_ms))
  end

  defp schedule_auth_timeout(state), do: state

  defp cancel_auth_timeout(%{auth_timeout_ref: ref}) when is_reference(ref),
    do: Process.cancel_timer(ref)

  defp cancel_auth_timeout(_state), do: :ok

  defp handle_auth(event, state) do
    body = event["body"] || %{}

    token =
      body["auth"] || event["auth"] || body["token"] || event["token"] || body["authToken"] ||
        event["authToken"]

    device_id = event["deviceId"] || body["deviceId"] || ""

    case Store.authenticate(token) do
      {:ok, user} ->
        uid = user["uid"]
        Observability.record_auth_attempt("websocket", "ok", present?(token))
        Observability.record_ws("auth_success")
        cancel_auth_timeout(state)
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
         state
         |> Map.merge(%{uid: uid, token: token, device_id: device_id})
         |> Map.delete(:auth_timeout_ref)}

      {:error, error} ->
        Observability.record_auth_attempt(
          "websocket",
          error["code"] || "error",
          present?(token)
        )

        Observability.record_ws("auth_failure", %{"code" => error["code"] || "401"})

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

    receiver =
      event["receiver"] || event["receiverId"] || event["recipient"] || body["receiver"] ||
        body["receiverId"] || body["recipient"]

    receiver_type =
      event["receiverType"] || event["receiver_type"] || body["receiverType"] ||
        body["receiver_type"] || "user"

    message_id =
      event["messageId"] || event["message_id"] || event["msgId"] || event["id"] ||
        body["messageId"] || body["message_id"] || body["msgId"] || body["id"] || "0"

    action = event["action"] || body["action"] || "read"

    delivered? = action in ["delivered", "deliver", "message_delivered"]

    receipt_result =
      cond do
        action == "read" ->
          safe_receipt(fn -> Store.mark_read(uid, receiver_type, receiver, message_id) end)

        delivered? ->
          safe_receipt(fn -> Store.mark_delivered(uid, receiver_type, receiver, message_id) end)

        true ->
          :ok
      end

    case receipt_result do
      :ok ->
        Observability.record_ws("receipt_ignored_or_ok")
        :ok

      {:ok, _payload} ->
        Observability.record_ws("receipt_ok", %{"action" => action})
        :ok

      {:error, reason} ->
        Observability.record_ws("receipt_error", %{"action" => action})
        Logger.warning("Ignoring websocket receipt after store failure: #{inspect(reason)}")
    end

    {:ok, state}
  end

  defp handle_receipt(_event, state), do: {:ok, state}

  defp safe_receipt(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

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

  defp request_origin(req) do
    case :cowboy_req.header("origin", req, nil) do
      nil -> nil
      :undefined -> nil
      origin -> to_s(origin)
    end
  end

  defp to_s(value) when is_binary(value), do: value
  defp to_s(value) when is_atom(value), do: Atom.to_string(value)
  defp to_s(value), do: to_string(value)

  defp present?(value), do: to_s(value) != ""

  defp close_reason({:remote, code, _text}), do: "remote_#{code}"
  defp close_reason({:error, reason}), do: "error_#{to_s(reason)}"
  defp close_reason(:normal), do: "normal"
  defp close_reason(:timeout), do: "timeout"
  defp close_reason(_reason), do: "other"

  defp authenticated?(%{uid: uid}) when is_binary(uid) and uid != "", do: true
  defp authenticated?(_state), do: false
end
