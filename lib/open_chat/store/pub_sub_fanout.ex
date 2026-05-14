defmodule OpenChat.Store.PubSubFanout do
  @moduledoc false

  alias OpenChat.{Config, Media}

  def message(state, message) do
    message = Media.sign_urls(message)

    event = %{
      "appId" => Config.app_id(),
      "receiver" => message["receiver"],
      "receiverType" => message["receiverType"],
      "deviceId" => "server",
      "type" => "message",
      "sender" => to_s(message["sender"]),
      "body" => message
    }

    OpenChat.PubSub.broadcast(recipient_keys(state, message), event)
  end

  def reaction(state, message, reaction_obj, action, actor_uid) do
    event = %{
      "appId" => Config.app_id(),
      "receiver" => message["receiver"],
      "receiverType" => message["receiverType"],
      "deviceId" => "server",
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

  def receipt(payload, uid, receiver_type, receiver_id, action) do
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
        "timestamp" => payload["deliveredAt"] || payload["readAt"]
      }
    }

    targets =
      if receiver_type == "group", do: [{:group, receiver_id}], else: [{:user, receiver_id}]

    OpenChat.PubSub.broadcast(targets, event)
  end

  def group_action(state, guid, action, opts) do
    except = Keyword.get(opts, :except)
    keys = group_recipient_keys(state, guid, except: except)
    action = Media.sign_urls(action)

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
    sender = to_s(message["sender"])
    group_recipient_keys(state, to_s(message["receiver"]), except: sender)
  end

  def group_recipient_keys(state, guid, opts) do
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

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
