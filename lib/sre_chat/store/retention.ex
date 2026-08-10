defmodule SREChat.Store.Retention do
  @moduledoc false

  alias SREChat.{Config, Time}
  alias SREChat.Store.{Indexes, RedisPersistence, Unread}

  def trim_group_history(state, %{"receiverType" => "group"} = message) do
    conv_id = to_s(message["conversationId"])
    ids = state |> get_in(["conversation_messages", conv_id]) |> List.wrap() |> Enum.map(&to_s/1)
    keep_ids = retained_ids(state, ids, message)
    remove_ids = ids -- keep_ids

    if remove_ids == [] do
      {state, []}
    else
      removed_messages =
        remove_ids
        |> Enum.map(&get_in(state, ["messages", &1]))
        |> Enum.reject(&is_nil/1)

      {state, thread_ops} = prune_thread_indexes(state, remove_ids)

      state =
        state
        |> Indexes.remove_messages(removed_messages)
        |> update_in(["messages"], &delete_keys(&1, remove_ids))
        |> update_in(["reactions"], &delete_keys(&1, remove_ids))
        |> put_in(["conversation_messages", conv_id], keep_ids)
        |> put_latest(conv_id, keep_ids)
        |> sync_unread(message)

      ops =
        Enum.flat_map(removed_messages, &message_delete_ops/1) ++
          thread_ops

      {state, ops}
    end
  end

  def trim_group_history(state, _message), do: {state, []}

  defp retained_ids(state, ids, message) do
    newest_by_count =
      ids
      |> Enum.reverse()
      |> Enum.take(Config.group_max_messages())
      |> MapSet.new()

    latest_id = to_s(message["id"])
    cutoff = Time.now() - Config.group_message_retention_days() * 86_400

    Enum.filter(ids, fn id ->
      id == latest_id or
        (MapSet.member?(newest_by_count, id) and message_new_enough?(state, id, cutoff))
    end)
  end

  defp message_new_enough?(state, id, cutoff) do
    case get_in(state, ["messages", id, "sentAt"]) do
      nil -> true
      sent_at -> to_int(sent_at) >= cutoff
    end
  end

  defp prune_thread_indexes(state, remove_ids) do
    removed = MapSet.new(Enum.map(remove_ids, &to_s/1))

    {threads, ops} =
      state
      |> Map.get("thread_messages", %{})
      |> Enum.reduce({%{}, []}, fn {parent_id, ids}, {threads, ops} ->
        parent_id = to_s(parent_id)

        cond do
          MapSet.member?(removed, parent_id) ->
            {threads, [RedisPersistence.delete("thread_messages", parent_id) | ops]}

          true ->
            kept_ids = Enum.reject(List.wrap(ids), &(to_s(&1) in removed))

            cond do
              kept_ids == [] ->
                {threads, [RedisPersistence.delete("thread_messages", parent_id) | ops]}

              kept_ids == ids ->
                {Map.put(threads, parent_id, ids), ops}

              true ->
                {Map.put(threads, parent_id, kept_ids),
                 [RedisPersistence.put("thread_messages", parent_id, kept_ids) | ops]}
            end
        end
      end)

    {Map.put(state, "thread_messages", threads), Enum.reverse(ops)}
  end

  defp put_latest(state, conv_id, keep_ids) do
    latest_id =
      keep_ids
      |> Enum.reverse()
      |> Enum.find(&Map.has_key?(state["messages"] || %{}, &1))

    case latest_id do
      nil -> update_in(state, ["conversation_latest"], &Map.delete(&1 || %{}, conv_id))
      id -> put_in(state, ["conversation_latest", conv_id], id)
    end
  end

  defp sync_unread(state, message) do
    if capped_group?(state, message) do
      state
    else
      state
      |> Indexes.message_participants(message)
      |> Enum.reduce(state, fn uid, acc ->
        Unread.sync(acc, uid, message["conversationId"])
      end)
    end
  end

  defp capped_group?(state, %{"receiverType" => "group", "receiver" => guid}) do
    map_size(get_in(state, ["members", to_s(guid)]) || %{}) > Config.group_unread_fanout_limit()
  end

  defp capped_group?(_state, _message), do: false

  defp message_delete_ops(message) do
    id = to_s(message["id"])

    [
      RedisPersistence.delete("messages", id),
      RedisPersistence.delete("reactions", id)
    ] ++ message_muid_delete_ops(message)
  end

  defp message_muid_delete_ops(message) do
    case to_s(message["muid"]) do
      "" -> []
      muid -> [RedisPersistence.delete("message_muids", muid)]
    end
  end

  defp delete_keys(map, keys) do
    Enum.reduce(keys, map || %{}, &Map.delete(&2, to_s(&1)))
  end

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, _rest} -> i
      :error -> 0
    end
  end

  defp to_int(value), do: value |> to_s() |> to_int()
end
