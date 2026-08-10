defmodule SREChat.Store.Indexes do
  @moduledoc false

  alias SREChat.Config
  alias SREChat.Store.{Conversations, Entities}
  alias SREChat.Time

  @secondary_buckets [
    "message_muids",
    "user_conversations",
    "conversation_users",
    "user_groups"
  ]

  def secondary_buckets, do: @secondary_buckets

  def empty_buckets do
    Map.new(@secondary_buckets, &{&1, %{}})
  end

  def rebuild(state) do
    state =
      state
      |> ensure_secondary_buckets()
      |> Map.merge(empty_buckets())

    state =
      Enum.reduce(state["members"] || %{}, state, fn {guid, members}, acc ->
        members
        |> Map.keys()
        |> Enum.reduce(acc, &put_user_group(&2, &1, guid))
      end)

    Enum.reduce(state["messages"] || %{}, state, fn {_id, message}, acc ->
      link_message(acc, message)
    end)
  end

  def ensure_secondary_buckets(state) do
    Enum.reduce(@secondary_buckets, state, fn bucket, acc ->
      Map.put(acc, bucket, Map.get(acc, bucket, %{}) || %{})
    end)
  end

  def put_member(state, guid, uid, scope, now \\ Time.now()) do
    guid = to_s(guid)
    uid = to_s(uid)
    member = Entities.member(guid, uid, scope, now)

    state
    |> update_in(["members", guid], &(&1 || %{}))
    |> put_in(["members", guid, uid], member)
    |> put_user_group(uid, guid)
  end

  def remove_member(state, guid, uid) do
    guid = to_s(guid)
    uid = to_s(uid)

    state
    |> update_in(["members", guid], &Map.delete(&1 || %{}, uid))
    |> remove_user_group(uid, guid)
  end

  def remove_group(state, guid) do
    guid = to_s(guid)
    member_uids = state |> get_in(["members", guid]) |> map_keys()

    Enum.reduce(member_uids, state, fn uid, acc ->
      remove_user_group(acc, uid, guid)
    end)
  end

  def link_message(state, message) do
    id = to_s(message["id"])
    conv_id = to_s(message["conversationId"])

    if blank?(id) or blank?(conv_id) do
      state
    else
      participants = message_participants(state, message)

      state
      |> put_message_muid(message)
      |> put_conversation_users(conv_id, participants)
      |> put_user_conversations(participants, conv_id)
    end
  end

  def remove_messages(state, messages) do
    messages
    |> List.wrap()
    |> Enum.reduce(state, fn message, acc ->
      remove_message_muid(acc, message)
    end)
  end

  def remove_conversations(state, conversation_ids) do
    conversation_ids =
      conversation_ids
      |> List.wrap()
      |> Enum.map(&to_s/1)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    participants =
      conversation_ids
      |> Enum.flat_map(fn conv_id -> get_in(state, ["conversation_users", conv_id]) || [] end)
      |> Enum.uniq()

    state =
      update_in(state, ["conversation_users"], fn rows ->
        Enum.reduce(conversation_ids, rows || %{}, &Map.delete(&2, &1))
      end)

    Enum.reduce(participants, state, fn uid, acc ->
      update_in(acc, ["user_conversations", uid], fn ids ->
        ids = remove_values(ids || [], conversation_ids)
        if ids == [], do: nil, else: ids
      end)
    end)
    |> compact_map_bucket("user_conversations")
  end

  def conversation_ids_for_user(state, uid) do
    uid = to_s(uid)

    direct =
      state
      |> get_in(["user_conversations", uid])
      |> List.wrap()
      |> Enum.reject(&(to_s(&1) |> String.starts_with?("group_")))

    groups =
      state
      |> get_in(["user_groups", uid])
      |> List.wrap()
      |> Enum.map(&Conversations.group_conversation_id/1)

    (direct ++ groups)
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.filter(fn conv_id ->
      Map.has_key?(state["conversation_latest"] || %{}, conv_id) or
        Map.has_key?(state["conversation_messages"] || %{}, conv_id)
    end)
  end

  def message_participants(state, %{"receiverType" => "group", "receiver" => guid} = message) do
    guid = to_s(guid)
    sender = to_s(message["sender"])
    members = get_in(state, ["members", guid]) || %{}

    members
    |> fanout_member_keys(sender)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  def message_participants(_state, message) do
    [message["sender"], message["receiver"]]
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp put_message_muid(state, message) do
    muid = to_s(message["muid"])

    if blank?(muid),
      do: state,
      else: put_in(state, ["message_muids", muid], to_s(message["id"]))
  end

  defp remove_message_muid(state, message) do
    muid = to_s(message["muid"])

    if blank?(muid),
      do: state,
      else: update_in(state, ["message_muids"], &Map.delete(&1 || %{}, muid))
  end

  defp put_user_group(state, uid, guid) do
    append_unique(state, ["user_groups", to_s(uid)], to_s(guid))
  end

  defp remove_user_group(state, uid, guid) do
    update_in(state, ["user_groups", to_s(uid)], fn groups ->
      groups = remove_values(groups || [], [to_s(guid)])
      if groups == [], do: nil, else: groups
    end)
    |> compact_map_bucket("user_groups")
  end

  defp put_conversation_users(state, conv_id, participants) do
    append_unique(state, ["conversation_users", conv_id], participants)
  end

  defp put_user_conversations(state, participants, conv_id) do
    Enum.reduce(participants, state, fn uid, acc ->
      append_unique(acc, ["user_conversations", uid], conv_id)
    end)
  end

  defp append_unique(state, path, values) when is_list(values) do
    values =
      values
      |> Enum.map(&to_s/1)
      |> Enum.reject(&blank?/1)

    update_in(state, path, fn existing ->
      ((existing || []) ++ values)
      |> Enum.map(&to_s/1)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
    end)
  end

  defp append_unique(state, path, value), do: append_unique(state, path, [value])

  defp compact_map_bucket(state, bucket) do
    update_in(state, [bucket], fn rows ->
      rows
      |> Kernel.||(%{})
      |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
      |> Map.new()
    end)
  end

  defp remove_values(values, removals) do
    removals = MapSet.new(Enum.map(removals, &to_s/1))
    Enum.reject(List.wrap(values), &(to_s(&1) in removals))
  end

  defp map_keys(map) when is_map(map), do: Map.keys(map)
  defp map_keys(_other), do: []

  defp fanout_member_keys(members, sender) do
    if map_size(members) > Config.group_unread_fanout_limit() do
      [sender]
    else
      map_keys(members) ++ [sender]
    end
  end

  defp blank?(value), do: value in [nil, "", false]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
