defmodule OpenChat.Store.CacheKeys do
  @moduledoc false

  alias OpenChat.Store.Conversations

  def for_pubsub_keys(keys) do
    keys
    |> List.wrap()
    |> Enum.flat_map(fn
      {:user, uid} -> user(uid)
      {:group, guid} -> group(guid)
      _other -> []
    end)
  end

  def for_pubsub_keys(keys, %{"type" => "message", "body" => %{} = message}) do
    keys
    |> List.wrap()
    |> Enum.flat_map(&message_pubsub_key(&1, message))
  end

  def for_pubsub_keys(_keys, %{"type" => "reaction"}), do: []

  def for_pubsub_keys(keys, %{"type" => "receipts"} = event) do
    keys
    |> List.wrap()
    |> Enum.flat_map(&receipt_pubsub_key(&1, event))
  end

  def for_pubsub_keys(keys, _event), do: for_pubsub_keys(keys)

  def for_event(%{"type" => "message", "body" => %{} = message}) do
    message(message) ++ action_subject_message(message)
  end

  def for_event(%{"type" => "reaction", "body" => %{} = body}) do
    message_id = body["messageId"] || body["message_id"] || body["id"]
    message_record(message_id) ++ [{"reactions", message_id}]
  end

  def for_event(%{"type" => "receipts", "sender" => uid, "body" => %{} = body} = event) do
    receiver_type = event["receiverType"] || body["receiverType"] || body["type"] || "user"
    receiver = event["receiver"] || body["receiver"] || body["receiverId"]

    conv_id =
      body["conversationId"] || Conversations.conversation_id_for(uid, receiver_type, receiver)

    [
      {"reads", uid},
      {"delivered", uid},
      {"unread_counts", uid},
      {"conversation_latest", conv_id},
      {"conversation_users", conv_id}
    ]
  end

  def for_event(_event), do: []

  def user(uid) do
    uid = to_s(uid)

    if blank?(uid) do
      []
    else
      [
        {"users", uid},
        {"user_groups", uid},
        {"user_conversations", uid},
        {"unread_counts", uid},
        {"reads", uid},
        {"delivered", uid},
        {"hidden_conversations", uid},
        {"blocks", uid}
      ]
    end
  end

  def group(guid) do
    guid = to_s(guid)

    if blank?(guid) do
      []
    else
      conv_id = Conversations.group_conversation_id(guid)

      [
        {"groups", guid},
        {"members", guid},
        {"banned", guid},
        {"presence", guid},
        {"conversation_messages", conv_id},
        {"conversation_latest", conv_id},
        {"conversation_users", conv_id}
      ]
    end
  end

  def message_record(value),
    do: if(blank?(value) or to_s(value) == "0", do: [], else: [{"messages", value}])

  defp message(message) do
    conv_id =
      message["conversationId"] ||
        Conversations.conversation_id_for(
          message["sender"],
          message["receiverType"],
          message["receiver"]
        )

    parent_id = message["parentId"] || message["parentMessageId"]
    muid = message["muid"]

    message_record(message["id"]) ++
      [
        {"reactions", message["id"]},
        {"conversation_messages", conv_id},
        {"conversation_latest", conv_id},
        {"conversation_users", conv_id},
        {"message_muids", muid}
      ] ++
      message_record(parent_id) ++
      if(blank?(parent_id), do: [], else: [{"thread_messages", parent_id}]) ++
      user_record(message["sender"]) ++ receiver(message)
  end

  defp message_pubsub_key({:user, uid}, %{"receiverType" => "group"}) do
    unread_count(uid)
  end

  defp message_pubsub_key({:group, guid}, %{"receiverType" => "group"}) do
    shallow_group(guid)
  end

  defp message_pubsub_key({:user, uid}, _message) do
    user_record(uid) ++ [{"user_conversations", to_s(uid)}, {"unread_counts", to_s(uid)}]
  end

  defp message_pubsub_key({:group, guid}, _message), do: shallow_group(guid)
  defp message_pubsub_key(_key, _message), do: []

  defp receipt_pubsub_key({:group, guid}, _event), do: shallow_group(guid)
  defp receipt_pubsub_key({:user, uid}, _event), do: user_record(uid) ++ unread_count(uid)
  defp receipt_pubsub_key(_key, _event), do: []

  defp action_subject_message(message) do
    case get_in(message, ["data", "entities", "on", "entity"]) do
      %{"id" => _id, "conversationId" => _conv_id} = subject -> message(subject)
      %{"id" => id} -> message_record(id) ++ [{"reactions", id}]
      _other -> []
    end
  end

  defp receiver(%{"receiverType" => "group", "receiver" => guid}), do: shallow_group(guid)
  defp receiver(%{"receiver" => uid}), do: user_record(uid)
  defp receiver(_message), do: []

  defp user_record(uid) do
    uid = to_s(uid)
    if blank?(uid), do: [], else: [{:record_only, "users", uid}]
  end

  defp unread_count(uid) do
    uid = to_s(uid)
    if blank?(uid), do: [], else: [{:record_only, "unread_counts", uid}]
  end

  defp shallow_group(guid) do
    guid = to_s(guid)

    if blank?(guid) do
      []
    else
      [
        {:record_only, "groups", guid},
        {:record_only, "members", guid},
        {:record_only, "banned", guid},
        {:record_only, "presence", guid}
      ]
    end
  end

  defp blank?(value), do: value in [nil, "", false]
  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
