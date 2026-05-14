defmodule OpenChat.Store.GroupState do
  @moduledoc false

  alias OpenChat.{Config, Errors, Time}
  alias OpenChat.Store.{Conversations, Entities, GroupPermissions, Indexes, Unread}

  def ensure_member_map(state, guid), do: update_in(state, ["members", guid], &(&1 || %{}))

  def ensure_group(state, guid) do
    guid = to_s(guid)

    if Map.has_key?(state["groups"], guid) do
      ensure_member_map(state, guid)
    else
      group =
        Entities.group(%{"guid" => guid, "name" => guid, "type" => "public", "owner" => "system"})

      state
      |> put_in(["groups", guid], group)
      |> ensure_member_map(guid)
    end
  end

  def add_member(state, guid, uid, scope) do
    previous_count = map_size(get_in(state, ["members", to_s(guid)]) || %{})

    state
    |> ensure_member_map(to_s(guid))
    |> clear_presence(guid, uid)
    |> Indexes.put_member(guid, uid, scope)
    |> sync_unread_after_member_add(guid, uid, previous_count)
  end

  def remove_member(state, guid, uid) do
    state
    |> Indexes.remove_member(guid, uid)
    |> Unread.remove_conversation(uid, Conversations.group_conversation_id(guid))
  end

  def authorize_moderation(_state, _guid, opts) when opts in [nil, []], do: :ok

  def authorize_moderation(state, guid, opts) do
    if Keyword.get(opts, :admin?, false) do
      :ok
    else
      actor_uid = Keyword.get(opts, :actor_uid) || Keyword.get(opts, :uid)

      if GroupPermissions.can_moderate?(state, guid, actor_uid) do
        :ok
      else
        {:error,
         Errors.forbidden(
           "Only group owners, admins, moderators, and coOwners can manage members."
         )}
      end
    end
  end

  def transient_join?(state, group, guid, uid, params) do
    group["type"] == "public" and
      not member?(state, guid, uid) and
      not truthy?(params["durable"]) and
      (truthy?(params["transient"]) or truthy?(params["visitor"]) or
         truthy?(params["asVisitor"]) or Config.public_group_joins_as_visits?())
  end

  def read_allowed?(state, guid, uid) do
    case Map.fetch(state["groups"], to_s(guid)) do
      :error ->
        false

      {:ok, group} ->
        not banned?(state, guid, uid) and
          (member?(state, guid, uid) or
             (not blank?(uid) and group["type"] == "public" and
                Config.public_group_reads_enabled?()))
    end
  end

  def member_limit_reached?(state, guid, uid) do
    not member?(state, guid, uid) and
      map_size(get_in(state, ["members", to_s(guid)]) || %{}) >= Config.group_max_members()
  end

  def member_limit_error(guid) do
    Errors.error("ERR_LIMIT_EXCEEDED", "Group #{guid} has reached its member limit.", %{
      "guid" => guid,
      "limit" => Config.group_max_members()
    })
  end

  def member_failure(error) do
    %{
      "success" => false,
      "code" => error["code"],
      "error" => error["message"],
      "message" => error["message"]
    }
  end

  def mark_presence(state, guid, uid) do
    now = Time.now()
    presence = Entities.presence(guid, uid, now, Config.group_presence_ttl_seconds())

    update_in(state, ["presence", to_s(guid)], fn rows ->
      rows
      |> Kernel.||(%{})
      |> Enum.reject(fn {_uid, presence} -> to_int(presence["expiresAt"]) <= now end)
      |> Map.new()
      |> Map.put(to_s(uid), presence)
      |> cap_presence()
    end)
  end

  def clear_presence(state, guid, uid) do
    update_in(state, ["presence", to_s(guid)], fn rows ->
      rows = Map.delete(rows || %{}, to_s(uid))
      if rows == %{}, do: nil, else: rows
    end)
  end

  def member?(state, guid, uid),
    do: Map.has_key?(get_in(state, ["members", to_s(guid)]) || %{}, to_s(uid))

  def banned?(state, guid, uid),
    do: Map.has_key?(get_in(state, ["banned", to_s(guid)]) || %{}, to_s(uid))

  def with_members_count(group, state), do: Entities.with_members_count(group, state)

  defp sync_unread_after_member_add(state, guid, uid, previous_count) do
    conv_id = Conversations.group_conversation_id(guid)
    member_count = map_size(get_in(state, ["members", to_s(guid)]) || %{})

    cond do
      previous_count <= Config.group_unread_fanout_limit() and
          member_count > Config.group_unread_fanout_limit() ->
        clear_group_unread_counts(state, guid)

      member_count > Config.group_unread_fanout_limit() ->
        Unread.remove_conversation(state, uid, conv_id)

      true ->
        Unread.sync(state, uid, conv_id)
    end
  end

  defp clear_group_unread_counts(state, guid) do
    conv_id = Conversations.group_conversation_id(guid)

    state
    |> get_in(["members", to_s(guid)])
    |> map_keys()
    |> Enum.reduce(state, fn uid, acc ->
      Unread.remove_conversation(acc, uid, conv_id)
    end)
  end

  defp cap_presence(rows) do
    limit = Config.group_max_presence()

    if map_size(rows) <= limit do
      rows
    else
      rows
      |> Enum.sort_by(fn {_uid, presence} -> -to_int(presence["lastSeenAt"]) end)
      |> Enum.take(limit)
      |> Map.new()
    end
  end

  defp map_keys(map) when is_map(map), do: Map.keys(map)
  defp map_keys(_other), do: []

  defp truthy?(value), do: value in [true, 1, "1", "true", "TRUE", "yes", "YES"]
  defp blank?(value), do: value in [nil, "", false]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(value), do: value |> to_s() |> to_int()
end
