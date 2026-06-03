defmodule OpenChat.Store.RequestPlan do
  @moduledoc false

  alias OpenChat.Config
  alias OpenChat.Store.{AuthTokens, Conversations, RedisPersistence}

  defstruct mutating?: false, locks: [], refresh: []

  def build(:reset), do: mutate([:global], [])

  def build({:get_user, uid}), do: read([{"users", uid}])

  def build({:get_user_for, viewer_uid, uid}) do
    read([{"users", uid}, {"blocks", viewer_uid}, {"blocks", uid}])
  end

  def build({:ensure_user, uid}), do: mutate(user_scope(uid), [{"users", uid}])

  def build({:upsert_user, attrs}) do
    attrs = stringify_keys(attrs)
    uid = attrs["uid"] || attrs["id"]
    mutate(user_scope(uid), user_record_keys(uid))
  end

  def build({:list_users, _params}), do: read([{:bucket, "users"}])
  def build({:delete_user, uid}), do: mutate(user_scope(uid), [{"users", uid}])

  def build({:reactivate_users, uids}) do
    mutate(
      Enum.flat_map(List.wrap(uids), &user_scope/1),
      Enum.flat_map(List.wrap(uids), &user_record_keys/1)
    )
  end

  def build({:block_users, uid, uids}) do
    mutate(
      user_scope(uid),
      [{"blocks", uid}] ++ Enum.flat_map(List.wrap(uids), &user_record_keys/1)
    )
  end

  def build({:unblock_users, uid, _uids}), do: mutate(user_scope(uid), [{"blocks", uid}])
  def build({:blocked_users, uid, params}), do: read(blocked_user_keys(uid, params))
  def build({:create_auth_token, uid}), do: mutate(user_scope(uid), [{"users", uid}])
  def build({:revoke_auth_token, token}), do: mutate(token_scope(token), [{"tokens", token}])

  def build({request, token}) when request in [:authenticate, :me] do
    if token_requires_auth_mutation?(token) do
      mutate(token_scopes(token), token_refresh_keys(token))
    else
      read(token_refresh_keys(token))
    end
  end

  def build({:upsert_group, attrs}) do
    attrs = stringify_keys(attrs)
    guid = attrs["guid"] || attrs["id"]
    mutate(group_scope(guid), group_keys(guid))
  end

  def build({:get_group, guid}), do: read(group_keys(guid))
  def build({:list_groups, _params}), do: read([{:bucket, "groups"}, {:bucket, "members"}])
  def build({:delete_group, guid}), do: mutate(group_scope(guid), group_delete_keys(guid))

  def build({:join_group, guid, uid, _params}),
    do:
      mutate(
        group_scope(guid),
        group_keys(guid) ++
          user_record_keys(uid) ++
          [{"user_groups", uid}, {"unread_counts", uid}, {:counter, "next_id"}]
      )

  def build({:leave_group, guid, uid}),
    do:
      mutate(
        group_scope(guid),
        group_keys(guid) ++ [{"user_groups", uid}, {"unread_counts", uid}, {:counter, "next_id"}]
      )

  def build({:add_group_members, guid, uids, _scope, opts}) do
    mutate(
      group_scope(guid),
      group_keys(guid) ++
        actor_user_keys(opts) ++
        Enum.flat_map(List.wrap(uids), &user_record_keys/1) ++
        Enum.map(List.wrap(uids), &{"user_groups", &1}) ++
        Enum.map(List.wrap(uids), &{"unread_counts", &1})
    )
  end

  def build({:group_members, guid, _params}), do: read(group_keys(guid))
  def build({:groups_for_user, uid}), do: read([{"user_groups", uid}])

  def build({:set_group_scopes, guid, scope_map, opts}) do
    mutate(
      group_scope(guid),
      group_keys(guid) ++
        actor_user_keys(opts) ++
        Enum.flat_map(uids_from_scope_map(scope_map), &user_record_keys/1) ++
        Enum.map(uids_from_scope_map(scope_map), &{"user_groups", &1}) ++
        Enum.map(uids_from_scope_map(scope_map), &{"unread_counts", &1})
    )
  end

  def build({:ban_group_member, guid, uid}),
    do:
      mutate(
        group_scope(guid),
        group_keys(guid) ++
          user_record_keys(uid) ++ [{"user_groups", uid}, {"unread_counts", uid}]
      )

  def build({:unban_group_member, guid, _uid}), do: mutate(group_scope(guid), [{"banned", guid}])
  def build({:banned_group_members, guid, _params}), do: read([{"banned", guid}])

  def build({:send_message, sender_uid, params, _uploads, _opts}) do
    send_message_plan(sender_uid, params)
  end

  def build({:send_message, sender_uid, params, _data, _type, _opts}) do
    send_message_plan(sender_uid, params)
  end

  def build({:edit_message, _uid, id, _params, _opts}),
    do: mutate(message_action_scope(id), [{"messages", id}, {:counter, "next_id"}])

  def build({:delete_message, _uid, id, _opts}),
    do: mutate(message_action_scope(id), [{"messages", id}, {:counter, "next_id"}])

  def build({:delete_conversation, conversation_id}),
    do: mutate([{:conversation, conversation_id}], conversation_delete_keys(conversation_id))

  def build({:hide_conversation, uid, receiver_type, receiver_id}) do
    mutate(
      conversation_scope(uid, receiver_type, receiver_id),
      conversation_record_keys(uid, receiver_type, receiver_id) ++ [{"hidden_conversations", uid}]
    )
  end

  def build({:get_message, id}), do: read([{"messages", id}, {"reactions", id}])
  def build({:get_message_for, _uid, id, _opts}), do: read([{"messages", id}, {"reactions", id}])

  def build({:find_message_by_muid, muid}), do: read([{"message_muids", muid}])
  def build({:find_message_by_muid_for, _uid, muid, _opts}), do: read([{"message_muids", muid}])

  def build({:messages_for_user, uid, peer_uid, _params}),
    do: read([{"conversation_messages", Conversations.user_conversation_id(uid, peer_uid)}])

  def build({:messages_for_group, _uid, guid, _params}),
    do:
      read(
        group_keys(guid) ++ [{"conversation_messages", Conversations.group_conversation_id(guid)}]
      )

  def build({:messages_for_thread, _uid, parent_id, _params}),
    do: read([{"messages", parent_id}, {"thread_messages", parent_id}])

  def build({receipt, uid, receiver_type, receiver_id, message_id})
      when receipt in [:mark_read, :mark_unread] do
    mutate(
      conversation_scope(uid, receiver_type, receiver_id) ++ user_scope(uid),
      receipt_refresh_keys(uid, receiver_type, receiver_id, message_id) ++
        [{"reads", uid}] ++
        [{"unread_counts", uid}]
    )
  end

  def build({:mark_delivered, uid, receiver_type, receiver_id, message_id}) do
    mutate(
      conversation_scope(uid, receiver_type, receiver_id) ++ user_scope(uid),
      receipt_refresh_keys(uid, receiver_type, receiver_id, message_id) ++ [{"delivered", uid}]
    )
  end

  def build({:unread_counts, uid, _params}), do: read(user_conversation_keys(uid))

  def build({:conversations, uid, _params}), do: read(user_conversation_keys(uid))

  def build({:conversation, uid, receiver_type, receiver_id}) do
    refresh =
      [
        {"reads", uid},
        {"delivered", uid},
        {"hidden_conversations", uid},
        {"unread_counts", uid}
      ] ++
        conversation_record_keys(uid, receiver_type, receiver_id) ++
        if(receiver_type == "group",
          do: group_keys(receiver_id),
          else: user_record_keys(receiver_id)
        )

    read(refresh)
  end

  def build({:add_reaction, uid, id, _reaction}) do
    mutate(message_scope(id), [
      {"messages", id},
      {"reactions", id},
      {"users", uid},
      {:counter, "next_reaction_id"}
    ])
  end

  def build({:add_reaction, uid, id, _reaction, _opts}),
    do: build({:add_reaction, uid, id, nil})

  def build({:remove_reaction, uid, id, _reaction}) do
    mutate(message_scope(id), [{"messages", id}, {"reactions", id}, {"users", uid}])
  end

  def build({:remove_reaction, uid, id, _reaction, _opts}),
    do: build({:remove_reaction, uid, id, nil})

  def build({:toggle_reaction, uid, id, _reaction}) do
    mutate(message_scope(id), [
      {"messages", id},
      {"reactions", id},
      {"users", uid},
      {:counter, "next_reaction_id"}
    ])
  end

  def build({:toggle_reaction, uid, id, _reaction, _opts}),
    do: build({:toggle_reaction, uid, id, nil})

  def build({:reactions, _uid, id, _reaction}), do: read([{"messages", id}, {"reactions", id}])
  def build(_request), do: read([])

  def followup_refresh({request, token}, state) when request in [:authenticate, :me] do
    token
    |> AuthTokens.lookup_tokens()
    |> Enum.flat_map(&auth_user_refresh_keys(&1, state))
    |> Enum.uniq()
  end

  def followup_refresh({:send_message, sender_uid, params, _uploads, _opts}, state) do
    send_message_followup_refresh(sender_uid, params, state)
  end

  def followup_refresh({:send_message, sender_uid, params, _data, _type, _opts}, state) do
    send_message_followup_refresh(sender_uid, params, state)
  end

  def followup_refresh({:delete_conversation, conversation_id}, state) do
    state
    |> get_in(["conversation_users", to_s(conversation_id)])
    |> List.wrap()
    |> Enum.map(&{"unread_counts", &1})
  end

  def followup_refresh({request, uid, id, _opts}, state) when request in [:delete_message] do
    message_action_refresh_keys(state, uid, id)
  end

  def followup_refresh({request, uid, id, _params, _opts}, state)
      when request in [:edit_message] do
    message_action_refresh_keys(state, uid, id)
  end

  def followup_refresh(_request, _state), do: []

  defp read(refresh), do: %__MODULE__{refresh: refresh}
  defp mutate(locks, refresh), do: %__MODULE__{mutating?: true, locks: locks, refresh: refresh}

  defp send_message_followup_refresh(sender_uid, params, state) do
    params = stringify_keys(params)
    receiver = params["receiver"] || params["receiverId"]
    receiver_type = receiver_type(params)

    unread_count_keys(sender_uid, receiver_type, receiver, state)
  end

  defp send_message_plan(sender_uid, params) do
    params = stringify_keys(params)
    receiver = params["receiver"] || params["receiverId"]
    receiver_type = receiver_type(params)

    refresh =
      [{"users", sender_uid}, {:counter, "next_id"}] ++
        conversation_record_keys(sender_uid, receiver_type, receiver) ++
        unread_count_keys(sender_uid, receiver_type, receiver) ++
        auto_delivery_keys(receiver_type, receiver) ++
        parent_message_keys(params) ++
        if(receiver_type == "group", do: group_keys(receiver), else: user_record_keys(receiver))

    mutate(conversation_scope(sender_uid, receiver_type, receiver), refresh)
  end

  defp receiver_type(params),
    do: (params["receiverType"] || "user") |> to_s() |> String.downcase()

  defp conversation_scope(uid, receiver_type, receiver_id) do
    if valid_receiver?(receiver_type, receiver_id) do
      [{:conversation, Conversations.conversation_id_for(uid, receiver_type, receiver_id)}]
    else
      [:global]
    end
  end

  defp conversation_record_keys(uid, receiver_type, receiver_id) do
    if valid_receiver?(receiver_type, receiver_id) do
      [
        {"conversation_messages",
         Conversations.conversation_id_for(uid, receiver_type, receiver_id)},
        {"conversation_latest",
         Conversations.conversation_id_for(uid, receiver_type, receiver_id)}
      ]
    else
      []
    end
  end

  defp receipt_refresh_keys(uid, receiver_type, receiver_id, message_id) do
    conversation_record_keys(uid, receiver_type, receiver_id) ++
      if(receiver_type == "group",
        do: group_keys(receiver_id),
        else: user_record_keys(receiver_id)
      ) ++
      message_record_keys(message_id)
  end

  defp unread_count_keys(sender_uid, "user", receiver_id) do
    [sender_uid, receiver_id]
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.map(&{"unread_counts", &1})
  end

  defp unread_count_keys(_sender_uid, "group", _receiver_id), do: []
  defp unread_count_keys(_sender_uid, _receiver_type, _receiver_id), do: []

  defp unread_count_keys(sender_uid, "group", receiver_id, state) do
    members = get_in(state, ["members", to_s(receiver_id)]) || %{}

    member_uids =
      if map_size(members) > Config.group_unread_fanout_limit(),
        do: [],
        else: Map.keys(members)

    member_uids
    |> Kernel.++([sender_uid])
    |> Enum.map(&to_s/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.map(&{"unread_counts", &1})
  end

  defp unread_count_keys(sender_uid, receiver_type, receiver_id, _state) do
    unread_count_keys(sender_uid, receiver_type, receiver_id)
  end

  defp auto_delivery_keys("user", receiver_id) do
    receiver_id = to_s(receiver_id)
    if blank?(receiver_id), do: [], else: [{"delivered", receiver_id}]
  end

  defp auto_delivery_keys(_receiver_type, _receiver_id), do: []

  defp parent_message_keys(params) do
    params
    |> Map.get("parentId", Map.get(params, "parentMessageId"))
    |> message_record_keys()
  end

  defp message_record_keys(value),
    do: if(blank?(value) or to_s(value) == "0", do: [], else: [{"messages", value}])

  defp valid_receiver?(receiver_type, receiver_id),
    do: receiver_type in ["user", "group"] and not blank?(receiver_id)

  defp token_scopes(token) do
    token
    |> AuthTokens.lookup_tokens()
    |> Enum.flat_map(&single_token_scopes/1)
    |> Enum.uniq()
  end

  defp token_requires_auth_mutation?(token) do
    tokens = AuthTokens.lookup_tokens(token)

    Config.accept_uid_tokens?() and
      Enum.any?(tokens, &match?({:ok, _uid}, AuthTokens.uid_token(&1)))
  end

  defp single_token_scopes(token) do
    case AuthTokens.uid_token(token) do
      {:ok, uid} -> [{:token, token}, {:user, uid}]
      :error -> token_scope(token)
    end
  end

  defp user_scope(value), do: if(blank?(value), do: [:global], else: [{:user, value}])
  defp token_scope(value), do: if(blank?(value), do: [:global], else: [{:token, value}])
  defp message_scope(value), do: if(blank?(value), do: [:global], else: [{:message, value}])

  defp group_scope(value) do
    if blank?(value),
      do: [:global],
      else: [{:conversation, Conversations.group_conversation_id(value)}]
  end

  defp message_action_scope(value) do
    message_scope(value) ++ RedisPersistence.message_conversation_locks(value)
  end

  defp token_refresh_keys(token) do
    token
    |> AuthTokens.lookup_tokens()
    |> Enum.flat_map(&single_token_refresh_keys/1)
    |> Enum.uniq()
  end

  defp single_token_refresh_keys(token) do
    case AuthTokens.uid_token(token) do
      {:ok, uid} -> [{"users", uid}, {"tokens", token}]
      :error -> [{"tokens", token}]
    end
  end

  defp auth_user_refresh_keys(token, state) do
    case AuthTokens.uid_token(token) do
      {:ok, uid} ->
        user_record_keys(uid)

      :error ->
        state
        |> get_in(["tokens", token])
        |> user_record_keys()
    end
  end

  defp message_action_refresh_keys(state, uid, id) do
    message = get_in(state, ["messages", to_s(id)]) || %{}

    user_record_keys(uid) ++
      user_record_keys(message["sender"]) ++
      conversation_index_keys(message["conversationId"]) ++
      unread_count_keys(uid, message["receiverType"], message["receiver"], state) ++
      case message["receiverType"] do
        "group" -> group_keys(message["receiver"])
        "user" -> user_record_keys(message["receiver"])
        _other -> []
      end
  end

  defp blocked_user_keys(uid, params) do
    params = stringify_keys(params || %{})

    case params["direction"] do
      "blockedByMe" -> [{"blocks", uid}]
      _other -> [{"blocks", uid}, {:bucket, "blocks"}]
    end
  end

  defp group_delete_keys(guid) do
    conv_id = Conversations.group_conversation_id(guid)

    group_keys(guid) ++
      [
        {"conversation_messages", conv_id},
        {"conversation_latest", conv_id},
        {"conversation_users", conv_id}
      ]
  end

  defp conversation_delete_keys(conversation_id) do
    conversation_id = to_s(conversation_id)

    extra_ids =
      if String.starts_with?(conversation_id, "group_"),
        do: [],
        else: [Conversations.group_conversation_id(conversation_id)]

    [conversation_id]
    |> Kernel.++(extra_ids)
    |> Enum.uniq()
    |> Enum.flat_map(fn conv_id ->
      [
        {"conversation_messages", conv_id},
        {"conversation_latest", conv_id},
        {"conversation_users", conv_id}
      ]
    end)
  end

  defp conversation_index_keys(conversation_id) do
    conversation_id = to_s(conversation_id)

    if blank?(conversation_id) do
      []
    else
      [
        {"conversation_messages", conversation_id},
        {"conversation_latest", conversation_id},
        {"conversation_users", conversation_id}
      ]
    end
  end

  defp user_conversation_keys(uid) do
    [
      {"user_conversations", uid},
      {"user_groups", uid},
      {"reads", uid},
      {"delivered", uid},
      {"hidden_conversations", uid},
      {"unread_counts", uid}
    ]
  end

  defp actor_user_keys(opts) do
    opts
    |> List.wrap()
    |> Keyword.get(:actor_uid)
    |> user_record_keys()
  end

  defp user_record_keys(value), do: if(blank?(value), do: [], else: [{"users", value}])
  defp group_keys(guid), do: [{"groups", guid}, {"members", guid}, {"banned", guid}]

  defp uids_from_scope_map(scope_map) do
    scope_map = stringify_keys(scope_map || %{})

    [
      scope_map["participants"],
      scope_map["members"],
      scope_map["moderators"],
      scope_map["admins"],
      scope_map["uids"]
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp stringify_keys(%{__struct__: _} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_s(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp blank?(value), do: value in [nil, "", false]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
