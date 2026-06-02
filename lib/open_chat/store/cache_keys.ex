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
      user(message["sender"]) ++ receiver(message)
  end

  defp action_subject_message(message) do
    case get_in(message, ["data", "entities", "on", "entity"]) do
      %{"id" => _id, "conversationId" => _conv_id} = subject -> message(subject)
      %{"id" => id} -> message_record(id) ++ [{"reactions", id}]
      _other -> []
    end
  end

  defp receiver(%{"receiverType" => "group", "receiver" => guid}), do: group(guid)
  defp receiver(%{"receiver" => uid}), do: user(uid)
  defp receiver(_message), do: []

  defp blank?(value), do: value in [nil, "", false]
  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
