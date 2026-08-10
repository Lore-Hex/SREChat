defmodule SREChat.Store.Conversations do
  @moduledoc false

  alias SREChat.Store.Unread

  def rebuild_latest(state) do
    latest =
      state
      |> Map.get("conversation_messages", %{})
      |> Enum.reduce(%{}, fn {conv_id, ids}, acc ->
        case latest_message_id(ids, state) do
          nil -> acc
          id -> Map.put(acc, to_s(conv_id), id)
        end
      end)

    Map.put(state, "conversation_latest", latest)
  end

  def put_latest(state, message) do
    conv_id = to_s(message["conversationId"])
    id = to_s(message["id"])

    if blank?(conv_id) or blank?(id) do
      state
    else
      put_in(state, ["conversation_latest", conv_id], id)
    end
  end

  def mark_read(state, uid, receiver_type, receiver_id, message_id, now) do
    conv_id = conversation_id_for(uid, receiver_type, receiver_id)

    state =
      update_in(state, ["reads", uid], fn reads ->
        Map.put(reads || %{}, conv_id, %{"messageId" => to_s(message_id), "readAt" => now})
      end)
      |> Unread.mark_read(uid, conv_id, message_id)

    {state,
     %{
       "success" => true,
       "conversationId" => conv_id,
       "messageId" => to_s(message_id),
       "readAt" => now
     }}
  end

  def mark_unread(state, uid, receiver_type, receiver_id, message_id, now) do
    conv_id = conversation_id_for(uid, receiver_type, receiver_id)

    previous_id = previous_message_id(state, conv_id, message_id)

    state =
      update_in(state, ["reads", uid], fn reads ->
        Map.put(reads || %{}, conv_id, %{
          "messageId" => previous_id,
          "readAt" => now
        })
      end)
      |> Unread.mark_read(uid, conv_id, previous_id)

    {state, conv_id}
  end

  def mark_delivered(state, uid, receiver_type, receiver_id, message_id, now) do
    conv_id = conversation_id_for(uid, receiver_type, receiver_id)

    state =
      update_in(state, ["delivered", uid], fn delivered ->
        Map.put(delivered || %{}, conv_id, %{
          "messageId" => to_s(message_id),
          "deliveredAt" => now
        })
      end)

    {state,
     %{
       "success" => true,
       "conversationId" => conv_id,
       "messageId" => to_s(message_id),
       "deliveredAt" => now
     }}
  end

  def hide(state, uid, receiver_type, receiver_id, now) do
    conv_id = conversation_id_for(uid, receiver_type, receiver_id)
    latest = latest_message(state, conv_id)
    message_id = if latest, do: latest["id"], else: "0"

    state =
      update_in(state, ["hidden_conversations", uid], fn hidden ->
        Map.put(hidden || %{}, conv_id, %{
          "messageId" => to_s(message_id),
          "hiddenAt" => now
        })
      end)

    {state,
     %{
       "success" => true,
       "conversationId" => conv_id,
       "messageId" => to_s(message_id),
       "hiddenAt" => now
     }}
  end

  def delete_indexes(state, conv_ids, user_buckets) do
    conv_ids =
      conv_ids
      |> List.wrap()
      |> Enum.map(&to_s/1)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    touched =
      Map.new(user_buckets, fn bucket ->
        {bucket, uids_with_conversations(state, bucket, conv_ids)}
      end)

    state =
      state
      |> update_in(["conversation_messages"], fn conversations ->
        Enum.reduce(conv_ids, conversations || %{}, &Map.delete(&2, &1))
      end)
      |> update_in(["conversation_latest"], fn latest ->
        Enum.reduce(conv_ids, latest || %{}, &Map.delete(&2, &1))
      end)

    state =
      Enum.reduce(user_buckets, state, fn bucket, acc ->
        remove_conversations_from_user_bucket(acc, bucket, conv_ids)
      end)

    {state, %{conversation_ids: conv_ids, touched_user_buckets: touched}}
  end

  def delete_message_records(state, message_ids) do
    message_ids = message_ids |> List.wrap() |> Enum.map(&to_s/1) |> Enum.uniq()
    thread_ids = Enum.filter(message_ids, &Map.has_key?(state["thread_messages"], &1))

    state =
      state
      |> update_in(["messages"], fn messages ->
        Enum.reduce(message_ids, messages || %{}, &Map.delete(&2, &1))
      end)
      |> update_in(["reactions"], fn reactions ->
        Enum.reduce(message_ids, reactions || %{}, &Map.delete(&2, &1))
      end)
      |> update_in(["thread_messages"], fn threads ->
        Enum.reduce(thread_ids, threads || %{}, &Map.delete(&2, &1))
      end)

    {state, %{message_ids: message_ids, thread_ids: thread_ids}}
  end

  def latest_message(state, conv_id) do
    case get_in(state, ["conversation_latest", to_s(conv_id)]) do
      id when is_binary(id) and id != "" ->
        get_in(state, ["messages", id]) || latest_message_from_conversation(state, conv_id)

      _other ->
        latest_message_from_conversation(state, conv_id)
    end
  end

  def previous_message_id(state, conv_id, message_id) do
    ids = Map.get(state["conversation_messages"], conv_id, [])

    case Enum.find_index(ids, &(&1 == to_s(message_id))) do
      nil -> "0"
      0 -> "0"
      idx -> Enum.at(ids, idx - 1, "0")
    end
  end

  def conversation_id_for(uid, "user", receiver), do: user_conversation_id(uid, receiver)
  def conversation_id_for(_uid, "group", receiver), do: group_conversation_id(receiver)

  def user_conversation_id(a, b) do
    [x, y] = [to_s(a), to_s(b)] |> Enum.sort()
    "user_#{x}_#{y}"
  end

  def group_conversation_id(guid), do: "group_#{to_s(guid)}"

  defp uids_with_conversations(state, bucket, conv_ids) do
    conv_ids = MapSet.new(conv_ids)

    state
    |> Map.get(bucket, %{})
    |> Enum.filter(fn {_uid, conversations} ->
      cond do
        is_map(conversations) ->
          Enum.any?(conv_ids, &Map.has_key?(conversations, &1))

        is_list(conversations) ->
          Enum.any?(conversations, &(to_s(&1) in conv_ids))

        true ->
          false
      end
    end)
    |> Enum.map(fn {uid, _conversations} -> uid end)
  end

  defp remove_conversations_from_user_bucket(state, bucket, conv_ids) do
    update_in(state, [bucket], fn rows ->
      rows
      |> Kernel.||(%{})
      |> Enum.reduce(%{}, fn {uid, conversations}, acc ->
        conversations = remove_conversation_ids(conversations, conv_ids)

        if empty_conversations?(conversations),
          do: acc,
          else: Map.put(acc, uid, conversations)
      end)
    end)
  end

  defp remove_conversation_ids(conversations, conv_ids) when is_map(conversations) do
    Enum.reduce(conv_ids, conversations, &Map.delete(&2, &1))
  end

  defp remove_conversation_ids(conversations, conv_ids) when is_list(conversations) do
    conv_ids = MapSet.new(conv_ids)
    Enum.reject(conversations, &(to_s(&1) in conv_ids))
  end

  defp remove_conversation_ids(_conversations, _conv_ids), do: %{}

  defp empty_conversations?(conversations) when is_map(conversations),
    do: map_size(conversations) == 0

  defp empty_conversations?(conversations) when is_list(conversations), do: conversations == []
  defp empty_conversations?(_conversations), do: true

  defp blank?(value), do: value in [nil, "", false]

  defp latest_message_from_conversation(state, conv_id) do
    state["conversation_messages"]
    |> Map.get(to_s(conv_id), [])
    |> latest_message_id(state)
    |> case do
      nil -> nil
      id -> get_in(state, ["messages", id])
    end
  end

  defp latest_message_id(ids, state) do
    ids
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.map(&to_s/1)
    |> Enum.find(&Map.has_key?(state["messages"] || %{}, &1))
  end

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
