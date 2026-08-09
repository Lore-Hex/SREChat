defmodule OpenChat.Replication.Ingest do
  @moduledoc """
  Applies a peer region's oplog ops to local Store state.

  Runs INSIDE the Store GenServer (single writer), under the global Redis
  lock taken by the applier, with `Replication.while_applying/1` set so
  nothing applied here re-enters the oplog.

  Per-bucket merge rules:

    * `messages` — a new id runs the full local store path (conversation
      lists, indexes, unread, retention) exactly as if sent here, then
      fans out to local websockets. A known id is a replace (edits and
      deletes arrive as record puts, already version-gated by the
      applier). The conversation-latest pointer is max-merged by id so a
      late-arriving old message can never clobber a newer latest.
    * `reads` / `delivered` — per-conversation MAX-merge on the numeric
      message id. Receipt cursors only move forward; replay order cannot
      regress them. Unread counts resync from the merged cursor.
    * `members` — whole-map replace (version-gated), then the user→group
      index is rebuilt for every uid that appeared or disappeared, and a
      membership_changed system event nudges affected sockets to resync
      their subscriptions.
    * everything else — version-gated record replace.

  Known v1 anomalies, accepted for coordination chat and documented here
  deliberately: concurrent membership edits to the SAME group during a
  partition resolve by last-writer-wins (one side's add/remove set wins
  whole); reactions merge the same way. Messages are never lost. Receipt
  EVENTS are not re-broadcast cross-region (cursors replicate; the read
  ticks catch up on the next fetch).
  """

  alias OpenChat.Store.{MessageState, PersistenceOps, RedisPersistence, Unread}

  @doc """
  Apply decoded ops. Returns `{state, persist_ops, fanouts}` — the caller
  persists and then runs the fanouts, in that order.
  """
  def apply_ops(state, ops, _origin, _ts) do
    Enum.reduce(ops, {state, [], []}, fn op, {state, persist, fanouts} ->
      {state, new_persist, new_fanouts} = apply_op(state, op)
      {state, persist ++ new_persist, fanouts ++ new_fanouts}
    end)
  end

  defp apply_op(state, {:put, "messages", id, message}) do
    id = to_string(id)

    if Map.has_key?(state["messages"], id) do
      # Edit/delete replay: replace the record only. The id is already in
      # every list and index, and latest never moves on a replace.
      state = put_in(state, ["messages", id], message)
      {state, [RedisPersistence.put("messages", id, message)], []}
    else
      conv_id = to_string(message["conversationId"] || "")
      previous_latest = get_in(state, ["conversation_latest", conv_id])

      {state, retention_ops} = MessageState.store_with_retention(state, message)
      state = restore_latest_if_newer(state, conv_id, previous_latest)

      persist =
        PersistenceOps.message_create(state, message) ++
          retention_ops ++
          unread_ops(state, message)

      {state, persist, [{:message, message}]}
    end
  end

  defp apply_op(state, {:put, bucket, uid, incoming}) when bucket in ["reads", "delivered"] do
    uid = to_string(uid)
    local = get_in(state, [bucket, uid]) || %{}
    merged = max_merge_cursors(local, incoming || %{})

    if merged == local do
      {state, [], []}
    else
      state = put_in(state, [bucket, uid], merged)

      state =
        if bucket == "reads" do
          merged
          |> Map.keys()
          |> Enum.reduce(state, fn conv_id, acc -> Unread.sync_read_cursor(acc, uid, conv_id) end)
        else
          state
        end

      persist =
        [RedisPersistence.put(bucket, uid, merged)] ++
          if(bucket == "reads", do: PersistenceOps.unread_counts(state, [uid]), else: [])

      {state, persist, []}
    end
  end

  defp apply_op(state, {:put, "members", guid, members}) do
    guid = to_string(guid)
    previous = get_in(state, ["members", guid]) || %{}
    members = members || %{}
    touched = Map.keys(previous) |> Kernel.++(Map.keys(members)) |> Enum.uniq()

    state = put_in(state, ["members", guid], members)
    state = reindex_user_groups(state, touched)

    persist =
      [RedisPersistence.put("members", guid, members)] ++
        PersistenceOps.user_groups(state, touched) ++
        PersistenceOps.unread_counts(state, touched)

    {state, persist, [{:membership_changed, touched}]}
  end

  defp apply_op(state, {:put, bucket, id, value}) do
    {put_in(state, [bucket, to_string(id)], value), [RedisPersistence.put(bucket, id, value)], []}
  end

  defp apply_op(state, {:delete, "members", guid}) do
    apply_op(state, {:put, "members", guid, %{}})
  end

  defp apply_op(state, {:delete, bucket, id}) do
    {update_in(state, [bucket], &Map.delete(&1 || %{}, to_string(id))),
     [RedisPersistence.delete(bucket, id)], []}
  end

  # A replicated message that is OLDER than the local latest must not move
  # the pointer backwards; MessageState.store/2 sets it unconditionally.
  defp restore_latest_if_newer(state, conv_id, previous_latest) do
    current = get_in(state, ["conversation_latest", conv_id])

    if previous_latest && current && to_int(previous_latest) > to_int(current) do
      put_in(state, ["conversation_latest", conv_id], previous_latest)
    else
      state
    end
  end

  defp unread_ops(state, message) do
    PersistenceOps.unread_counts(state, Unread.participants(state, message))
  end

  defp max_merge_cursors(local, incoming) do
    Map.merge(local, incoming, fn _conv_id, l, r ->
      if to_int(r["messageId"]) > to_int(l["messageId"]), do: r, else: l
    end)
  end

  defp reindex_user_groups(state, uids) do
    Enum.reduce(uids, state, fn uid, acc ->
      groups =
        acc["members"]
        |> Enum.filter(fn {_guid, members} -> Map.has_key?(members || %{}, uid) end)
        |> Enum.map(fn {guid, _members} -> guid end)
        |> Enum.sort()

      put_in(acc, ["user_groups", uid], groups)
    end)
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp to_int(_value), do: 0

  @doc "Refresh keys the Store should load from its Redis before applying."
  def refresh_keys(ops) do
    Enum.flat_map(ops, fn
      {:put, "messages", id, message} ->
        conv_id = to_string(message["conversationId"] || "")

        [{"messages", to_string(id)}, {"conversation_messages", conv_id}] ++
          [{"conversation_latest", conv_id}]

      {:put, "members", _guid, _members} ->
        # Rebuilding user->group indexes scans every group's member map.
        [{:bucket, "members"}]

      {:put, bucket, uid, incoming} when bucket in ["reads", "delivered"] ->
        conv_keys =
          (incoming || %{})
          |> Map.keys()
          |> Enum.map(&{"conversation_messages", to_string(&1)})

        [{bucket, to_string(uid)}, {"unread_counts", to_string(uid)}] ++ conv_keys

      {:put, bucket, id, _value} ->
        [{bucket, to_string(id)}]

      {:delete, "members", _guid} ->
        [{:bucket, "members"}]

      {:delete, bucket, id} ->
        [{bucket, to_string(id)}]
    end)
    |> Enum.uniq()
  end

  @doc "Cursor buckets merge order-free and skip version gating."
  def merge_bucket?(bucket), do: bucket in ["reads", "delivered"]
end
