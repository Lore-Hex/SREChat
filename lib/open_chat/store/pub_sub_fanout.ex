defmodule OpenChat.Store.PubSubFanout do
  @moduledoc false

  alias OpenChat.{Config, Media}
  alias OpenChat.Store.{MessageData, MessageState}

  def message(state, message, opts \\ []) do
    message = message |> MessageData.ensure_media_wire_shape() |> Media.sign_urls()

    event = %{
      "appId" => Config.app_id(),
      "receiver" => message["receiver"],
      "receiverType" => message["receiverType"],
      "deviceId" => event_device_id(opts, message),
      "type" => "message",
      "sender" => to_s(message["sender"]),
      "body" => message
    }

    OpenChat.PubSub.broadcast(recipient_keys(state, message), event)
  end

  def message_update(state, message, actor_uid \\ nil, action_id \\ nil, opts \\ []) do
    receiver_entity =
      MessageState.receiver_entity(state, message["receiverType"], message["receiver"])

    message =
      message
      |> MessageData.ensure_media_wire_shape()
      |> Media.sign_urls()

    action =
      MessageState.message_action(
        action_id || message["id"],
        state,
        actor_uid || message["sender"],
        message,
        receiver_entity,
        "edited"
      )

    event = %{
      "appId" => Config.app_id(),
      "receiver" => action["receiver"],
      "receiverType" => action["receiverType"],
      "deviceId" => event_device_id(opts),
      "type" => "message",
      "sender" => to_s(action["sender"]),
      "body" => action
    }

    OpenChat.PubSub.broadcast(update_recipient_keys(state, message), event)
  end

  def reaction(state, message, reaction_obj, action, actor_uid, opts \\ []) do
    event = %{
      "appId" => Config.app_id(),
      "receiver" => message["receiver"],
      "receiverType" => message["receiverType"],
      "deviceId" => event_device_id(opts),
      "type" => "reaction",
      "sender" => actor_uid,
      "body" => %{
        "action" => action,
        "id" => reaction_obj["id"],
        "messageId" => message["id"],
        "reaction" => reaction_obj["reaction"],
        "reactedBy" => reaction_obj["reactedBy"],
        "reactedAt" => reaction_obj["reactedAt"]
      }
    }

    OpenChat.PubSub.broadcast(recipient_keys(state, message), event)
  end

  def receipt(payload, uid, receiver_type, receiver_id, action, opts \\ []) do
    actor = Keyword.get(opts, :user) || %{"uid" => to_s(uid), "name" => to_s(uid)}

    event = %{
      "appId" => Config.app_id(),
      "receiver" => receiver_id,
      "receiverType" => receiver_type,
      "deviceId" => "server",
      "type" => "receipts",
      "sender" => uid,
      "body" => %{
        "action" => action,
        "messageId" => payload["messageId"],
        "conversationId" => payload["conversationId"],
        "timestamp" => payload["deliveredAt"] || payload["readAt"],
        "user" => actor
      }
    }

    targets =
      if receiver_type == "group", do: [{:group, receiver_id}], else: [{:user, receiver_id}]

    targets =
      if Keyword.get(opts, :include_actor?, false) and receiver_type == "user" do
        [{:user, uid} | targets]
      else
        targets
      end

    OpenChat.PubSub.broadcast(targets, event)
  end

  def group_action(state, guid, action, opts) do
    except = Keyword.get(opts, :except)
    keys = group_recipient_keys(state, guid, except: except)
    action = action |> MessageData.ensure_media_wire_shape() |> Media.sign_urls()

    event = %{
      "appId" => Config.app_id(),
      "receiver" => guid,
      "receiverType" => "group",
      "deviceId" => "server",
      "type" => "message",
      "sender" => action["sender"],
      "body" => action
    }

    OpenChat.PubSub.broadcast(keys, event)
  end

  def membership_changed(uids) do
    keys =
      uids
      |> List.wrap()
      |> Enum.map(&to_s/1)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.map(&{:user, &1})

    if keys != [] do
      OpenChat.PubSub.broadcast_system(keys, %{"type" => "membership_changed"})
    end

    :ok
  end

  def recipient_keys(_state, %{"receiverType" => "user"} = message) do
    sender = to_s(message["sender"])
    receiver = to_s(message["receiver"])
    [{:user, receiver}, {:user, sender}]
  end

  def recipient_keys(state, %{"receiverType" => "group"} = message) do
    group_recipient_keys(state, to_s(message["receiver"]))
  end

  def update_recipient_keys(_state, %{"receiverType" => "user"} = message) do
    sender = to_s(message["sender"])
    receiver = to_s(message["receiver"])
    [{:user, receiver}, {:user, sender}]
  end

  def update_recipient_keys(state, %{"receiverType" => "group"} = message) do
    group_recipient_keys(state, to_s(message["receiver"]))
  end

  def group_recipient_keys(state, guid, opts \\ []) do
    except = opts |> Keyword.get(:except) |> to_s()
    members = state["members"] |> Map.get(to_s(guid), %{})

    if map_size(members) > Config.group_unread_fanout_limit() do
      [{:group, to_s(guid)}]
    else
      members
      |> Map.keys()
      |> Enum.reject(&(to_s(&1) == except))
      |> Enum.map(&{:user, &1})
    end
  end

  defp blank?(value), do: value in [nil, "", false]

  defp event_device_id(opts, message \\ %{}) do
    opts
    |> Keyword.get(:device_id)
    |> case do
      value when value in [nil, ""] -> message["resource"] || "server"
      value -> value
    end
    |> to_s()
    |> case do
      "" -> "server"
      value -> value
    end
  end

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
