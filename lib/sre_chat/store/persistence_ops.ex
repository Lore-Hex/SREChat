defmodule SREChat.Store.PersistenceOps do
  @moduledoc false

  alias SREChat.Store.{AuthTokens, Indexes, RedisPersistence}

  def user(state, uids) do
    uids
    |> List.wrap()
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn uid ->
      case get_in(state, ["users", uid]) do
        nil -> []
        user -> [RedisPersistence.put("users", uid, user)]
      end
    end)
  end

  def user_with_embedded_token(user) do
    [RedisPersistence.put("users", user["uid"], user)] ++ embedded_token(user)
  end

  def embedded_token(%{"authToken" => token, "uid" => uid})
      when is_binary(token) and token != "",
      do: [RedisPersistence.put("tokens", token, uid)]

  def embedded_token(_user), do: []

  def token(state, token) do
    case get_in(state, ["tokens", to_s(token)]) do
      nil -> []
      uid -> [RedisPersistence.put("tokens", token, uid)]
    end
  end

  def auth_token(state, token) do
    token
    |> AuthTokens.lookup_tokens()
    |> Enum.flat_map(&uid_token_with_user(state, &1))
  end

  def uid_token_with_user(state, "uid:" <> uid = token) when uid != "" do
    token(state, token) ++ user(state, [uid])
  end

  def uid_token_with_user(state, token), do: token(state, token)

  def group(state, guid) do
    guid = to_s(guid)

    case get_in(state, ["groups", guid]) do
      nil -> []
      group -> [RedisPersistence.put("groups", guid, group)]
    end
  end

  def members(state, guid),
    do: [RedisPersistence.put_or_delete("members", guid, get_in(state, ["members", to_s(guid)]))]

  def user_groups(state, uids) do
    uids
    |> List.wrap()
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.map(fn uid ->
      RedisPersistence.put_or_delete("user_groups", uid, get_in(state, ["user_groups", uid]))
    end)
  end

  def presence(state, guid),
    do: [
      RedisPersistence.put_or_delete(
        "presence",
        guid,
        get_in(state, ["presence", to_s(guid)])
      )
    ]

  def user_conversations(state, uids) do
    uids
    |> List.wrap()
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.map(fn uid ->
      RedisPersistence.put_or_delete(
        "user_conversations",
        uid,
        get_in(state, ["user_conversations", uid])
      )
    end)
  end

  def unread_counts(state, uids) do
    uids
    |> List.wrap()
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.map(fn uid ->
      RedisPersistence.put_or_delete("unread_counts", uid, get_in(state, ["unread_counts", uid]))
    end)
  end

  def conversation_users(state, conversation_ids) do
    conversation_ids
    |> List.wrap()
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.map(fn conversation_id ->
      RedisPersistence.put_or_delete(
        "conversation_users",
        conversation_id,
        get_in(state, ["conversation_users", conversation_id])
      )
    end)
  end

  def conversation_latest(state, conversation_ids) do
    conversation_ids
    |> List.wrap()
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.map(fn conversation_id ->
      RedisPersistence.put_or_delete(
        "conversation_latest",
        conversation_id,
        get_in(state, ["conversation_latest", conversation_id])
      )
    end)
  end

  def blocks(state, uid),
    do: [RedisPersistence.put_or_delete("blocks", uid, get_in(state, ["blocks", to_s(uid)]))]

  def banned(state, guid),
    do: [RedisPersistence.put_or_delete("banned", guid, get_in(state, ["banned", to_s(guid)]))]

  def reads(state, uid),
    do: [RedisPersistence.put_or_delete("reads", uid, get_in(state, ["reads", to_s(uid)]))]

  def delivered(state, uid) do
    [
      RedisPersistence.put_or_delete("delivered", uid, get_in(state, ["delivered", to_s(uid)]))
    ]
  end

  def hidden_conversations(state, uid) do
    [
      RedisPersistence.put_or_delete(
        "hidden_conversations",
        uid,
        get_in(state, ["hidden_conversations", to_s(uid)])
      )
    ]
  end

  def reactions(state, message_id) do
    [
      RedisPersistence.put_or_delete(
        "reactions",
        message_id,
        get_in(state, ["reactions", to_s(message_id)])
      )
    ]
  end

  def stored_message(state, message) do
    id = to_s(message["id"])
    conv_id = message["conversationId"]
    participants = Indexes.message_participants(state, message)

    ops =
      [
        RedisPersistence.put("messages", id, message),
        RedisPersistence.put(
          "conversation_messages",
          conv_id,
          state["conversation_messages"][conv_id]
        ),
        RedisPersistence.put_or_delete(
          "conversation_latest",
          conv_id,
          get_in(state, ["conversation_latest", conv_id])
        ),
        RedisPersistence.put_or_delete(
          "conversation_users",
          conv_id,
          state["conversation_users"][conv_id]
        )
      ] ++ message_muid_ops(message)

    ops =
      ops ++
        Enum.map(participants, fn uid ->
          RedisPersistence.put_or_delete(
            "user_conversations",
            uid,
            get_in(state, ["user_conversations", uid])
          )
        end) ++
        unread_counts(state, participants)

    if parent_id = message["parentId"] || message["parentMessageId"] do
      parent_id = to_s(parent_id)

      [
        RedisPersistence.put("thread_messages", parent_id, state["thread_messages"][parent_id])
        | ops
      ]
    else
      ops
    end
  end

  def message_create(state, message) do
    participant_ops =
      case message["receiverType"] do
        "user" -> user(state, [message["sender"], message["receiver"]])
        "group" -> user(state, [message["sender"]]) ++ group(state, message["receiver"])
        _other -> []
      end

    participant_ops ++ stored_message(state, message) ++ next_id(state)
  end

  def next_id(state), do: [RedisPersistence.counter("next_id", state["next_id"])]

  def next_reaction_id(state),
    do: [RedisPersistence.counter("next_reaction_id", state["next_reaction_id"])]

  def secondary_indexes(state) do
    Indexes.secondary_buckets()
    |> Enum.flat_map(fn bucket ->
      state
      |> Map.get(bucket, %{})
      |> Enum.map(fn {id, value} -> RedisPersistence.put_or_delete(bucket, id, value) end)
    end)
  end

  defp blank?(value), do: value in [nil, "", false]

  defp message_muid_ops(message) do
    case to_s(message["muid"]) do
      "" -> []
      muid -> [RedisPersistence.put("message_muids", muid, to_s(message["id"]))]
    end
  end

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
