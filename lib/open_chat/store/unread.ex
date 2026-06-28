defmodule OpenChat.Store.Unread do
  @moduledoc false

  alias OpenChat.Config
  alias OpenChat.Store.Indexes

  def rebuild(state) do
    state = Map.put(state, "unread_counts", %{})

    state
    |> Map.get("conversation_users", %{})
    |> Enum.reduce(state, fn {conv_id, uids}, acc ->
      Enum.reduce(List.wrap(uids), acc, &sync(&2, &1, conv_id))
    end)
  end

  def sync(state, uid, conv_id) do
    cond do
      oversized_group_conversation?(state, conv_id) ->
        put_count(state, uid, conv_id, 0)

      conversation_messages_loaded?(state, conv_id) ->
        put_count(
          state,
          uid,
          conv_id,
          count_after(state, uid, conv_id, read_id(state, uid, conv_id))
        )

      true ->
        sync_read_cursor(state, uid, conv_id)
    end
  end

  def sync_read_cursor(state, uid, conv_id) do
    cond do
      oversized_group_conversation?(state, conv_id) -> put_count(state, uid, conv_id, 0)
      read_through_latest?(state, uid, conv_id) -> put_count(state, uid, conv_id, 0)
      true -> state
    end
  end

  def count(state, uid, conv_id) do
    state
    |> get_in(["unread_counts", to_s(uid), to_s(conv_id)])
    |> to_int()
  end

  def message_created(state, message) do
    if countable?(message) do
      state
      |> participants(message)
      |> Enum.reject(&(&1 == to_s(message["sender"])))
      |> Enum.reduce(state, fn uid, acc ->
        update_count(acc, uid, message["conversationId"], &(&1 + 1))
      end)
    else
      state
    end
  end

  def message_deleted(state, message) do
    if countable?(message) do
      state
      |> participants(message)
      |> Enum.reject(&(&1 == to_s(message["sender"])))
      |> Enum.reduce(state, fn uid, acc ->
        if unread_for?(state, uid, message) do
          update_count(acc, uid, message["conversationId"], &max(&1 - 1, 0))
        else
          acc
        end
      end)
    else
      state
    end
  end

  def mark_read(state, uid, conv_id, message_id) do
    put_count(state, uid, conv_id, count_after(state, uid, conv_id, message_id))
  end

  def remove_conversation(state, uid, conv_id) do
    update_in(state, ["unread_counts", to_s(uid)], fn counts ->
      counts = Map.delete(counts || %{}, to_s(conv_id))
      if counts == %{}, do: nil, else: counts
    end)
    |> compact()
  end

  def participants(state, message), do: Indexes.message_participants(state, message)

  def count_after(state, uid, conv_id, message_id) do
    read_id = to_int(message_id)
    uid = to_s(uid)
    conv_id = to_s(conv_id)

    if oversized_group_conversation?(state, conv_id) do
      0
    else
      state
      |> get_in(["conversation_messages", conv_id])
      |> List.wrap()
      |> Enum.map(&get_in(state, ["messages", to_s(&1)]))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(fn message -> not countable?(message) end)
      |> Enum.reject(fn message -> to_s(message["sender"]) == uid end)
      |> Enum.reject(fn message -> not blank?(message["deletedAt"]) end)
      |> Enum.count(fn message -> to_int(message["id"]) > read_id end)
    end
  end

  defp oversized_group_conversation?(state, "group_" <> guid) do
    map_size(get_in(state, ["members", guid]) || %{}) > Config.group_unread_fanout_limit()
  end

  defp oversized_group_conversation?(_state, _conv_id), do: false

  defp conversation_messages_loaded?(state, conv_id) do
    is_list(get_in(state, ["conversation_messages", to_s(conv_id)]))
  end

  defp read_through_latest?(state, uid, conv_id) do
    latest_id = latest_message_id(state, conv_id)
    latest_id > 0 and read_id(state, uid, conv_id) >= latest_id
  end

  defp latest_message_id(state, conv_id) do
    case get_in(state, ["conversation_latest", to_s(conv_id)]) do
      id when is_integer(id) or is_binary(id) ->
        to_int(id)

      message when is_map(message) ->
        to_int(message["id"])

      _other ->
        0
    end
  end

  defp unread_for?(state, uid, message) do
    to_int(message["id"]) > read_id(state, uid, message["conversationId"])
  end

  defp read_id(state, uid, conv_id) do
    state
    |> get_in(["reads", to_s(uid), to_s(conv_id), "messageId"])
    |> to_int()
  end

  defp update_count(state, uid, conv_id, fun) do
    put_count(state, uid, conv_id, fun.(count(state, uid, conv_id)))
  end

  defp put_count(state, uid, conv_id, count) do
    uid = to_s(uid)
    conv_id = to_s(conv_id)
    count = max(to_int(count), 0)

    update_in(state, ["unread_counts", uid], fn counts ->
      counts = counts || %{}

      if count == 0 do
        Map.delete(counts, conv_id)
      else
        Map.put(counts, conv_id, count)
      end
    end)
    |> compact_user(uid)
  end

  defp compact_user(state, uid) do
    update_in(state, ["unread_counts"], fn rows ->
      rows = rows || %{}

      case rows[uid] do
        value when value in [nil, %{}] -> Map.delete(rows, uid)
        _other -> rows
      end
    end)
  end

  defp compact(state) do
    update_in(state, ["unread_counts"], fn rows ->
      rows
      |> Kernel.||(%{})
      |> Enum.reject(fn {_uid, counts} -> counts in [nil, %{}] end)
      |> Map.new()
    end)
  end

  defp countable?(message) do
    not blank?(message["conversationId"]) and blank?(message["deletedAt"]) and
      increment_unread?(message)
  end

  defp increment_unread?(message) do
    flag = get_in(message, ["data", "metadata", "incrementUnreadCount"])

    case flag do
      false -> false
      "false" -> false
      "FALSE" -> false
      0 -> false
      "0" -> false
      _other -> true
    end
  end

  defp blank?(value), do: value in [nil, "", false]

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
