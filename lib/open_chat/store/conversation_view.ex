defmodule OpenChat.Store.ConversationView do
  @moduledoc false

  alias OpenChat.Store.{Conversations, Entities, Indexes, Unread}

  def messages(state, conv_id, params) do
    state
    |> get_in(["conversation_messages", conv_id])
    |> List.wrap()
    |> messages_by_ids(state, params)
  end

  def messages_by_ids(ids, state, params) do
    ids
    |> Enum.map(&get_in(state, ["messages", to_s(&1)]))
    |> Enum.reject(&is_nil/1)
    |> filter_messages(params)
    |> paginate_messages(params)
  end

  def ids_for_user(state, uid) do
    indexed = Indexes.conversation_ids_for_user(state, uid)

    legacy_direct =
      state["conversation_messages"]
      |> Map.keys()
      |> Enum.filter(&user_conversation_for?(state, uid, &1))

    (indexed ++ legacy_direct)
    |> Enum.uniq()
    |> Enum.reject(&hidden?(state, uid, &1))
  end

  def build(_state, _uid, nil), do: nil

  def build(state, uid, conv_id) do
    last = latest_message(state, conv_id)

    if is_nil(last) or hidden?(state, uid, conv_id) do
      nil
    else
      type = if String.starts_with?(conv_id, "group_"), do: "group", else: "user"
      latest = to_s(last["id"])
      read = get_in(state, ["reads", uid, conv_id]) || %{}
      delivered = get_in(state, ["delivered", uid, conv_id]) || %{}

      %{
        "conversationId" => conv_id,
        "conversationType" => type,
        "lastMessage" => last,
        "conversationWith" => conversation_with(state, uid, conv_id),
        "unreadMessageCount" => Unread.count(state, uid, conv_id),
        "tags" => [],
        "unreadMentionsCount" => 0,
        "lastReadMessageId" => to_s(read["messageId"] || ""),
        "lastDeliveredMessageId" => to_s(delivered["messageId"] || ""),
        "deliveredAt" => delivered["deliveredAt"],
        "latestMessageId" => latest
      }
    end
  end

  def unread_count_row(state, uid, conv_id, count) do
    case conv_id do
      "group_" <> guid ->
        %{
          "entity" =>
            Entities.with_members_count(
              state["groups"][guid] || Entities.group(%{"guid" => guid}),
              state
            ),
          "entityType" => "group",
          "entityId" => guid,
          "count" => count
        }

      "user_" <> rest ->
        peer = user_peer_uid(state, uid, "user_" <> rest)

        %{
          "entity" =>
            Entities.public_user(state["users"][peer] || Entities.user(%{"uid" => peer})),
          "entityType" => "user",
          "entityId" => peer,
          "count" => count
        }
    end
  end

  def latest_message(state, conv_id), do: Conversations.latest_message(state, conv_id)

  def hidden?(state, uid, conv_id) do
    hidden = get_in(state, ["hidden_conversations", uid, conv_id])
    latest = latest_message(state, conv_id)

    not is_nil(hidden) and
      (is_nil(latest) or to_int(latest["id"]) <= to_int(hidden["messageId"]))
  end

  defp filter_messages(messages, params) do
    params = stringify_keys(params)
    hide_deleted = hide_deleted?(params)
    type = params["type"]
    category = params["category"]
    sender = params["sender"] || params["senderUid"] || params["sender_uid"]

    append_timestamp =
      params["fromTimestamp"] || params["fromTimeStamp"] || params["from_timestamp"]

    timestamp = params["sentAt"] || params["timestamp"] || params["updatedAt"] || append_timestamp
    after_id = params["afterId"] || params["after_id"] || params["fromId"] || params["from_id"]
    before_id = params["beforeId"] || params["before_id"]

    id =
      params["id"] || params["messageId"] || params["message_id"] || params["msgId"] ||
        params["msg_id"] || after_id || before_id || params["cursorValue"]

    cursor_id = params["cursorId"] || params["cursor_id"] || if(timestamp, do: id)

    affix =
      params["cursorAffix"] || params["affix"] ||
        cond do
          after_id -> "append"
          append_timestamp -> "append"
          true -> "prepend"
        end

    cursor_field =
      params["cursorField"] || if(timestamp, do: "sentAt", else: if(id, do: "id", else: "sentAt"))

    cursor_value =
      if(cursor_field == "id", do: id, else: timestamp || params["cursorValue"] || id)

    messages
    |> Enum.filter(fn message -> not hide_deleted or blank?(message["deletedAt"]) end)
    |> Enum.filter(fn message -> blank?(type) or message["type"] == type end)
    |> Enum.filter(fn message -> blank?(category) or message["category"] == category end)
    |> Enum.filter(fn message -> blank?(sender) or to_s(message["sender"]) == to_s(sender) end)
    |> filter_cursor(cursor_field, cursor_value, cursor_id, affix)
  end

  defp filter_cursor(messages, _field, nil, _cursor_id, _affix), do: messages

  defp filter_cursor(messages, field, value, cursor_id, affix) do
    field = if field == "id", do: "id", else: "sentAt"
    value_i = cursor_value(field, value, affix)
    cursor_id_i = to_int(cursor_id)

    Enum.filter(messages, fn message ->
      if field == "sentAt" and cursor_id_i > 0 do
        key = {to_int(message["sentAt"]), to_int(message["id"])}
        cursor = {value_i, cursor_id_i}
        if affix == "append", do: key > cursor, else: key < cursor
      else
        v = to_int(message[field])
        if affix == "append", do: v > value_i, else: v < value_i
      end
    end)
  end

  defp paginate_messages(messages, params) do
    params = stringify_keys(params)
    limit = clamp(to_int(params["per_page"] || params["limit"] || 30), 1, 100)

    append_timestamp =
      params["fromTimestamp"] || params["fromTimeStamp"] || params["from_timestamp"]

    after_id = params["afterId"] || params["after_id"] || params["fromId"] || params["from_id"]

    affix =
      params["cursorAffix"] || params["affix"] ||
        cond do
          after_id -> "append"
          append_timestamp -> "append"
          true -> "prepend"
        end

    messages =
      Enum.sort_by(messages, fn message ->
        {to_int(message["sentAt"]), to_int(message["id"])}
      end)

    messages = if affix == "append", do: messages, else: Enum.reverse(messages)
    Enum.take(messages, limit)
  end

  defp user_conversation_for?(state, uid, "user_" <> _ = conv_id) do
    case latest_message(state, conv_id) do
      %{"sender" => sender, "receiver" => receiver} ->
        uid in [to_s(sender), to_s(receiver)]

      _other ->
        case String.split(conv_id, "_") do
          ["user", a, b] -> uid in [a, b]
          _other -> false
        end
    end
  end

  defp user_conversation_for?(_state, _uid, _conv_id), do: false

  defp conversation_with(state, _uid, "group_" <> guid) do
    state["groups"][guid]
    |> Kernel.||(Entities.group(%{"guid" => guid, "name" => guid}))
    |> Entities.with_members_count(state)
  end

  defp conversation_with(state, uid, "user_" <> _rest = conv_id) do
    peer = user_peer_uid(state, uid, conv_id)
    Entities.public_user(state["users"][peer] || Entities.user(%{"uid" => peer}))
  end

  defp user_peer_uid(state, uid, conv_id) do
    case latest_message(state, conv_id) do
      %{"sender" => sender, "receiver" => receiver} ->
        sender = to_s(sender)
        receiver = to_s(receiver)

        if sender == uid, do: receiver, else: sender

      _other ->
        fallback_user_peer_uid(uid, conv_id)
    end
  end

  defp fallback_user_peer_uid(uid, "user_" <> rest) do
    case String.split(rest, "_", parts: 2) do
      [^uid, peer] -> peer
      [peer, ^uid] -> peer
      [_first, peer] -> peer
      [peer] -> peer
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_s(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp hide_deleted?(params) do
    case params["hideDeleted"] || params["hideDeletedMessages"] do
      value when value in [false, 0, "0", "false", "FALSE", "no", "NO"] -> false
      _other -> true
    end
  end

  defp blank?(value), do: value in [nil, "", false]
  defp clamp(value, lo, hi), do: value |> Kernel.max(lo) |> Kernel.min(hi)

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

  defp cursor_value("sentAt", value, affix) do
    value = to_int(value)

    if value > 10_000_000_000 do
      seconds = div(value, 1000)

      cond do
        affix == "append" -> seconds
        true -> seconds + 2
      end
    else
      value
    end
  end

  defp cursor_value(_field, value, _affix), do: to_int(value)
end
