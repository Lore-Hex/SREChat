defmodule OpenChat.Store do
  @moduledoc """
  Small CometChat-compatible data store.

  The default backend is in-memory OTP state. If `REDIS_URL` is set, this GenServer
  also persists records into Redis under per-entity keys and index sets. That keeps
  the replacement drop-in while avoiding one large whole-state JSON value.
  """

  use GenServer

  alias OpenChat.{Config, Errors, Time}

  alias OpenChat.Store.{
    Access,
    AuthTokens,
    ConversationView,
    Conversations,
    Entities,
    GroupState,
    Indexes,
    MessageState,
    MessageData,
    MessagePermissions,
    Pagination,
    PersistenceOps,
    PubSubFanout,
    RedisPersistence,
    RequestPlan,
    State,
    UserState,
    Unread
  }

  # Public API

  def start_link(opts \\ []) do
    {start_opts, init_opts} = Keyword.split(opts, [:name])

    start_opts =
      case Keyword.fetch(start_opts, :name) do
        {:ok, nil} -> []
        {:ok, _name} -> start_opts
        :error -> [name: __MODULE__]
      end

    GenServer.start_link(__MODULE__, init_opts, start_opts)
  end

  def reset!, do: call(:reset)
  def get_user(uid), do: call({:get_user, to_s(uid)})

  def get_user_for(viewer_uid, uid),
    do: call({:get_user_for, to_s(viewer_uid), to_s(uid)})

  def ensure_user(uid), do: call({:ensure_user, to_s(uid)})
  def upsert_user(attrs), do: call({:upsert_user, attrs})
  def list_users(params \\ %{}), do: call({:list_users, params})
  def delete_user(uid), do: call({:delete_user, to_s(uid)})
  def reactivate_users(uids), do: call({:reactivate_users, uids})
  def block_users(uid, uids), do: call({:block_users, to_s(uid), uids})
  def unblock_users(uid, uids), do: call({:unblock_users, to_s(uid), uids})

  def blocked_users(uid, params \\ %{}),
    do: call({:blocked_users, to_s(uid), params})

  def create_auth_token(uid), do: call({:create_auth_token, to_s(uid)})
  def revoke_auth_token(token), do: call({:revoke_auth_token, token})
  def authenticate(token), do: call({:authenticate, token})
  def me(token), do: call({:me, token})

  def upsert_group(attrs), do: call({:upsert_group, attrs})
  def get_group(guid), do: call({:get_group, to_s(guid)})
  def list_groups(params \\ %{}), do: call({:list_groups, params})
  def delete_group(guid), do: call({:delete_group, to_s(guid)})

  def join_group(guid, uid, params \\ %{}),
    do: call({:join_group, to_s(guid), to_s(uid), params})

  def leave_group(guid, uid),
    do: call({:leave_group, to_s(guid), to_s(uid)})

  def add_group_members(guid, uids, scope \\ "participant", opts \\ []),
    do: call({:add_group_members, to_s(guid), uids, scope, opts})

  def group_members(guid, params \\ %{}),
    do: call({:group_members, to_s(guid), params})

  def groups_for_user(uid), do: call({:groups_for_user, to_s(uid)})

  def set_group_scopes(guid, scope_map, opts \\ []),
    do: call({:set_group_scopes, to_s(guid), scope_map, opts})

  def ban_group_member(guid, uid),
    do: call({:ban_group_member, to_s(guid), to_s(uid)})

  def unban_group_member(guid, uid),
    do: call({:unban_group_member, to_s(guid), to_s(uid)})

  def banned_group_members(guid, params \\ %{}),
    do: call({:banned_group_members, to_s(guid), params})

  def send_message(sender_uid, params, uploads \\ [], opts \\ []),
    do: call({:send_message, to_s(sender_uid), params, uploads, opts})

  def edit_message(uid, id, params, opts \\ []),
    do: call({:edit_message, to_s(uid), to_s(id), params, opts})

  def delete_message(uid, id, opts \\ []),
    do: call({:delete_message, to_s(uid), to_s(id), opts})

  def delete_conversation(conversation_id),
    do: call({:delete_conversation, to_s(conversation_id)})

  def hide_conversation(uid, receiver_type, receiver_id),
    do: call({:hide_conversation, to_s(uid), to_s(receiver_type), to_s(receiver_id)})

  def get_message(id), do: call({:get_message, to_s(id)})

  def get_message_for(uid, id, opts \\ []),
    do: call({:get_message_for, to_s(uid), to_s(id), opts})

  def find_message_by_muid(muid),
    do: call({:find_message_by_muid, to_s(muid)})

  def find_message_by_muid_for(uid, muid, opts \\ []),
    do: call({:find_message_by_muid_for, to_s(uid), to_s(muid), opts})

  def messages_for_user(uid, peer_uid, params \\ %{}),
    do: call({:messages_for_user, to_s(uid), to_s(peer_uid), params})

  def messages_for_group(uid, guid, params \\ %{}),
    do: call({:messages_for_group, to_s(uid), to_s(guid), params})

  def messages_for_thread(uid, parent_id, params \\ %{}),
    do: call({:messages_for_thread, to_s(uid), to_s(parent_id), params})

  def mark_read(uid, receiver_type, receiver_id, message_id),
    do: call({:mark_read, to_s(uid), to_s(receiver_type), to_s(receiver_id), to_s(message_id)})

  def mark_unread(uid, receiver_type, receiver_id, message_id),
    do: call({:mark_unread, to_s(uid), to_s(receiver_type), to_s(receiver_id), to_s(message_id)})

  def mark_delivered(uid, receiver_type, receiver_id, message_id),
    do:
      call({:mark_delivered, to_s(uid), to_s(receiver_type), to_s(receiver_id), to_s(message_id)})

  def unread_counts(uid, params \\ %{}),
    do: call({:unread_counts, to_s(uid), params})

  def conversations(uid, params \\ %{}),
    do: call({:conversations, to_s(uid), params})

  def conversation(uid, receiver_type, receiver_id),
    do: call({:conversation, to_s(uid), to_s(receiver_type), to_s(receiver_id)})

  def add_reaction(uid, id, reaction),
    do: call({:add_reaction, to_s(uid), to_s(id), reaction})

  def remove_reaction(uid, id, reaction),
    do: call({:remove_reaction, to_s(uid), to_s(id), reaction})

  def toggle_reaction(uid, id, reaction),
    do: call({:toggle_reaction, to_s(uid), to_s(id), reaction})

  def reactions(uid, id, reaction \\ nil),
    do: call({:reactions, to_s(uid), to_s(id), reaction})

  def call_on(server, request), do: call(server, request)

  def refresh_from_pubsub(keys, event), do: refresh_from_pubsub(__MODULE__, keys, event)

  def refresh_from_pubsub(server, keys, event) do
    GenServer.call(server, {:refresh_from_pubsub, keys, event}, :infinity)
  end

  defp call(request), do: call(__MODULE__, request)

  defp call(server, request) do
    plan = RequestPlan.build(request)

    if plan.mutating? do
      RedisPersistence.with_locks(plan.locks, fn ->
        GenServer.call(server, {:locked_call, request, plan.refresh}, :infinity)
      end)
    else
      GenServer.call(server, {:cache_call, request, plan.refresh}, :infinity)
    end
  end

  # GenServer

  @impl true
  def init(_opts) do
    state = load_or_seed_state()
    {:ok, state}
  end

  @impl true
  def handle_call({:locked_call, request, refresh}, from, state) do
    request
    |> handle_call(
      from,
      refresh_request_state(request, state, refresh)
    )
  end

  def handle_call({:cache_call, request, refresh}, from, state) do
    request
    |> handle_call(
      from,
      refresh_request_state(request, state, refresh)
    )
  end

  def handle_call({:refresh_from_pubsub, keys, event}, _from, state) do
    refresh =
      keys
      |> pubsub_key_refresh_keys()
      |> Kernel.++(event_refresh_keys(event))
      |> Enum.uniq()

    {:reply, :ok, RedisPersistence.refresh_keys(State.default(), state, refresh)}
  end

  def handle_call(:reset, _from, _state) do
    state = seed_state()
    persist(state)
    {:reply, :ok, state}
  end

  def handle_call({:get_user, uid}, _from, state) do
    {:reply, UserState.fetch_public(state, nil, uid), state}
  end

  def handle_call({:get_user_for, viewer_uid, uid}, _from, state) do
    {:reply, UserState.fetch_public(state, viewer_uid, uid), state}
  end

  def handle_call({:ensure_user, uid}, _from, state) do
    {user, state} = UserState.ensure(state, uid)
    persist_ops(PersistenceOps.user(state, [user["uid"]]))
    {:reply, {:ok, user}, state}
  end

  def handle_call({:upsert_user, attrs}, _from, state) do
    attrs = stringify_keys(attrs)
    uid = attrs["uid"] || attrs["id"]

    if blank?(uid) do
      {:reply, {:error, Errors.missing("uid")}, state}
    else
      user = UserState.normalise(Map.merge(Map.get(state["users"], to_s(uid), %{}), attrs))
      state = UserState.put(state, user)
      state = UserState.maybe_store_embedded_token(state, user)
      persist_ops(PersistenceOps.user_with_embedded_token(user))
      {:reply, {:ok, UserState.public(user)}, state}
    end
  end

  def handle_call({:delete_user, uid}, _from, state) do
    case Map.fetch(state["users"], uid) do
      :error ->
        {:reply, {:error, Errors.user_not_found(uid)}, state}

      {:ok, user} ->
        user = user |> Map.put("deactivatedAt", Time.now()) |> Map.put("status", "offline")
        state = put_in(state, ["users", uid], user)
        persist_ops(PersistenceOps.user(state, [uid]))
        {:reply, {:ok, %{"success" => true, "uid" => uid}}, state}
    end
  end

  def handle_call({:reactivate_users, uids}, _from, state) do
    {state, result} =
      List.wrap(uids)
      |> Enum.reduce({state, %{}}, fn uid, {st, acc} ->
        uid = to_s(uid)
        {user, st} = UserState.ensure(st, uid)
        user = user |> Map.delete("deactivatedAt") |> Map.put("status", "available")
        st = UserState.put(st, user)
        {st, Map.put(acc, uid, %{"success" => true})}
      end)

    persist_ops(PersistenceOps.user(state, Map.keys(result)))
    {:reply, {:ok, %{"success" => result}}, state}
  end

  def handle_call({:list_users, params}, _from, state) do
    params = stringify_keys(params)

    users =
      state["users"]
      |> Map.values()
      |> Enum.reject(& &1["deactivatedAt"])
      |> Enum.map(&UserState.public/1)
      |> sort_by_key("uid")

    search = params["searchKey"] || params["search"]

    users =
      if blank?(search),
        do: users,
        else:
          Enum.filter(users, fn u ->
            contains?(u["uid"], search) or contains?(u["name"], search)
          end)

    {:reply, {:ok, Pagination.page(users, params, 30, 100)}, state}
  end

  def handle_call({:block_users, uid, uids}, _from, state) do
    {state, result} =
      List.wrap(uids)
      |> Enum.reduce({state, %{}}, fn blocked_uid, {st, acc} ->
        blocked_uid = to_s(blocked_uid)
        {_user, st} = UserState.ensure(st, blocked_uid)
        st = update_in(st, ["blocks", uid], &Map.put(&1 || %{}, blocked_uid, true))
        {st, Map.put(acc, blocked_uid, %{"success" => true, "message" => "User blocked."})}
      end)

    persist_ops(PersistenceOps.user(state, Map.keys(result)) ++ PersistenceOps.blocks(state, uid))
    {:reply, {:ok, result}, state}
  end

  def handle_call({:unblock_users, uid, uids}, _from, state) do
    {state, result} =
      List.wrap(uids)
      |> Enum.reduce({state, %{}}, fn blocked_uid, {st, acc} ->
        blocked_uid = to_s(blocked_uid)
        st = update_in(st, ["blocks", uid], &Map.delete(&1 || %{}, blocked_uid))
        {st, Map.put(acc, blocked_uid, %{"success" => true, "message" => "User unblocked."})}
      end)

    persist_ops(PersistenceOps.blocks(state, uid))
    {:reply, {:ok, result}, state}
  end

  def handle_call({:blocked_users, uid, params}, _from, state) do
    params = stringify_keys(params)
    direction = params["direction"] || "both"
    blocked_by_me = state["blocks"] |> Map.get(uid, %{}) |> Map.keys()

    has_blocked_me =
      state["blocks"]
      |> Enum.filter(fn {_blocker, blocked} -> Map.has_key?(blocked || %{}, uid) end)
      |> Enum.map(fn {blocker, _blocked} -> blocker end)

    uids =
      case direction do
        "blockedByMe" -> blocked_by_me
        "hasBlockedMe" -> has_blocked_me
        _ -> Enum.uniq(blocked_by_me ++ has_blocked_me)
      end

    search = params["searchKey"] || params["search"]

    users =
      uids
      |> Enum.map(fn target_uid ->
        user = UserState.get_or_default(state, target_uid)
        UserState.public_with_block_state(state, uid, user)
      end)
      |> Enum.filter(fn user ->
        blank?(search) or contains?(user["uid"], search) or contains?(user["name"], search)
      end)
      |> sort_by_key("uid")

    {page, meta} = Pagination.page_with_meta(users, params, 30, 100)
    {:reply, {:ok, page, meta}, state}
  end

  def handle_call({:create_auth_token, uid}, _from, state) do
    {user, state} = UserState.ensure(state, uid)
    token = "auth_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    state = put_in(state, ["tokens", token], user["uid"])
    persist_ops(PersistenceOps.user(state, [user["uid"]]) ++ PersistenceOps.token(state, token))
    {:reply, {:ok, me_payload(user, token)}, state}
  end

  def handle_call({:revoke_auth_token, token}, _from, state) do
    state = update_in(state, ["tokens"], &Map.delete(&1 || %{}, token))
    persist_ops([RedisPersistence.delete("tokens", token)])
    {:reply, {:ok, %{"success" => true}}, state}
  end

  def handle_call({:authenticate, token}, _from, state) do
    {reply, state} = authenticate_in_state(state, token)
    persist_ops(PersistenceOps.auth_token(state, token))
    {:reply, reply, state}
  end

  def handle_call({:me, token}, _from, state) do
    case authenticate_in_state(state, token) do
      {{:ok, user}, state} ->
        persist_ops(PersistenceOps.auth_token(state, token))
        {:reply, {:ok, me_payload(user, token)}, state}

      {error, state} ->
        {:reply, error, state}
    end
  end

  def handle_call({:upsert_group, attrs}, _from, state) do
    attrs = stringify_keys(attrs)
    guid = attrs["guid"] || attrs["id"]

    if blank?(guid) do
      {:reply, {:error, Errors.missing("guid")}, state}
    else
      group = normalise_group(Map.merge(Map.get(state["groups"], to_s(guid), %{}), attrs))
      state = put_in(state, ["groups", group["guid"]], group)
      state = GroupState.ensure_member_map(state, group["guid"])

      persist_ops(
        PersistenceOps.group(state, group["guid"]) ++ PersistenceOps.members(state, group["guid"])
      )

      {:reply, {:ok, group}, state}
    end
  end

  def handle_call({:get_group, guid}, _from, state) do
    {:reply, Map.fetch(state["groups"], guid), state}
  end

  def handle_call({:list_groups, params}, _from, state) do
    params = stringify_keys(params)

    groups =
      state["groups"]
      |> Map.values()
      |> Enum.map(&GroupState.with_members_count(&1, state))
      |> sort_by_key("guid")

    search = params["searchKey"] || params["search"]

    groups =
      if blank?(search),
        do: groups,
        else:
          Enum.filter(groups, fn g ->
            contains?(g["guid"], search) or contains?(g["name"], search)
          end)

    {:reply, {:ok, Pagination.page(groups, params, 30, 100)}, state}
  end

  def handle_call({:delete_group, guid}, _from, state) do
    conv_id = group_conversation_id(guid)
    message_ids = Map.get(state["conversation_messages"], conv_id, [])

    {state, conversation_ops} = delete_conversation_indexes(state, [conv_id])
    {state, message_ops} = delete_message_records(state, message_ids)
    member_uids = state |> get_in(["members", guid]) |> map_keys()
    state = Indexes.remove_group(state, guid)

    state =
      state
      |> update_in(["groups"], &Map.delete(&1 || %{}, guid))
      |> update_in(["members"], &Map.delete(&1 || %{}, guid))
      |> update_in(["banned"], &Map.delete(&1 || %{}, guid))

    persist_ops(
      [
        RedisPersistence.delete("groups", guid),
        RedisPersistence.delete("members", guid),
        RedisPersistence.delete("banned", guid)
      ] ++
        PersistenceOps.user_groups(state, member_uids) ++ conversation_ops ++ message_ops
    )

    PubSubFanout.membership_changed(member_uids)
    {:reply, {:ok, %{"success" => true, "guid" => guid}}, state}
  end

  def handle_call({:join_group, guid, uid, params}, _from, state) do
    params = stringify_keys(params)

    case Map.fetch(state["groups"], guid) do
      :error ->
        {:reply, {:error, Errors.group_not_found(guid)}, state}

      {:ok, group} ->
        {user, state} = UserState.ensure(state, uid)

        cond do
          not blank?(user["deactivatedAt"]) ->
            {:reply, {:error, Errors.no_auth()}, state}

          group["type"] == "private" ->
            {:reply, {:error, Errors.forbidden("Private groups must add members server-side.")},
             state}

          group["type"] == "password" and to_s(params["password"]) != to_s(group["password"]) ->
            {:reply, {:error, Errors.invalid("password", "Invalid group password.")}, state}

          GroupState.banned?(state, guid, uid) ->
            {:reply, {:error, Errors.forbidden("You are banned from this group.")}, state}

          GroupState.transient_join?(state, group, guid, uid, params) ->
            {_user, state} = UserState.ensure(state, uid)
            state = GroupState.mark_presence(state, guid, uid)

            group =
              state["groups"][guid]
              |> Map.put("hasJoined", true)
              |> Map.put("transient", true)
              |> GroupState.with_members_count(state)

            persist_ops(PersistenceOps.user(state, [uid]))
            {:reply, {:ok, group}, state}

          GroupState.member_limit_reached?(state, guid, uid) ->
            {:reply, {:error, GroupState.member_limit_error(guid)}, state}

          true ->
            {_user, state} = UserState.ensure(state, uid)
            state = GroupState.add_member(state, guid, uid, "participant")

            group =
              state["groups"][guid]
              |> Map.put("hasJoined", true)
              |> GroupState.with_members_count(state)

            {action_id, state} = take_counter(state, "next_id")
            action = MessageState.group_action(action_id, state, uid, group, uid, "joined")

            persist_ops(
              PersistenceOps.user(state, [uid]) ++
                PersistenceOps.members(state, guid) ++
                PersistenceOps.user_groups(state, [uid]) ++
                PersistenceOps.unread_counts(state, [uid]) ++
                PersistenceOps.next_id(state)
            )

            PubSubFanout.group_action(state, guid, action, except: uid)
            PubSubFanout.membership_changed([uid])
            {:reply, {:ok, group}, state}
        end
    end
  end

  def handle_call({:leave_group, guid, uid}, _from, state) do
    state = GroupState.remove_member(state, guid, uid)
    group = state["groups"][guid]

    {state, action} =
      if group do
        {action_id, state} = take_counter(state, "next_id")
        action = MessageState.group_action(action_id, state, uid, group, uid, "left")
        {state, action}
      else
        {state, nil}
      end

    persist_ops(
      PersistenceOps.members(state, guid) ++
        PersistenceOps.user_groups(state, [uid]) ++
        PersistenceOps.unread_counts(state, [uid]) ++
        PersistenceOps.next_id(state)
    )

    if action, do: PubSubFanout.group_action(state, guid, action, except: uid)
    PubSubFanout.membership_changed([uid])
    {:reply, {:ok, %{"success" => true}}, state}
  end

  def handle_call({:add_group_members, guid, uids, scope, opts}, _from, state) do
    with {:ok, group} <- Map.fetch(state["groups"], guid),
         :ok <- GroupState.authorize_moderation(state, guid, opts) do
      {state, result, touched_uids} =
        Enum.reduce(List.wrap(uids), {state, %{}, []}, fn uid, {st, acc, touched} ->
          uid = to_s(uid)

          if GroupState.member_limit_reached?(st, guid, uid) do
            error = GroupState.member_limit_error(guid)
            {st, Map.put(acc, uid, GroupState.member_failure(error)), touched}
          else
            {_user, st} = UserState.ensure(st, uid)
            st = GroupState.add_member(st, guid, uid, scope || "participant")

            {st, Map.put(acc, uid, %{"success" => true, "message" => "Member added."}),
             [uid | touched]}
          end
        end)

      group = GroupState.with_members_count(group, state)
      touched_uids = Enum.uniq(touched_uids)

      persist_ops(
        PersistenceOps.user(state, touched_uids) ++
          PersistenceOps.members(state, guid) ++
          PersistenceOps.user_groups(state, touched_uids) ++
          PersistenceOps.unread_counts(state, touched_uids)
      )

      PubSubFanout.membership_changed(touched_uids)
      {:reply, {:ok, %{"success" => result, "group" => group}}, state}
    else
      :error -> {:reply, {:error, Errors.group_not_found(guid)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:group_members, guid, params}, _from, state) do
    params = stringify_keys(params)

    case Map.fetch(state["groups"], guid) do
      :error ->
        {:reply, {:error, Errors.group_not_found(guid)}, state}

      {:ok, _group} ->
        scopes =
          params["scope"]
          |> to_s()
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)

        members =
          state["members"]
          |> Map.get(guid, %{})
          |> Enum.filter(fn {_uid, meta} -> scopes == [] or meta["scope"] in scopes end)
          |> Enum.map(fn {uid, meta} ->
            scope = meta["scope"] || "participant"

            state
            |> UserState.get_or_default(uid)
            |> UserState.public()
            |> Map.merge(meta)
            |> Map.put("role", scope)
            |> Map.put("scope", scope)
          end)
          |> sort_by_key("uid")

        {:reply, {:ok, members}, state}
    end
  end

  def handle_call({:set_group_scopes, guid, scope_map, opts}, _from, state) do
    scope_map = stringify_keys(scope_map || %{})
    state = GroupState.ensure_group(state, guid)

    case GroupState.authorize_moderation(state, guid, opts) do
      :ok ->
        assignments = [
          {"participant", scope_map["participants"] || scope_map["members"] || []},
          {"moderator", scope_map["moderators"] || []},
          {"admin", scope_map["admins"] || []},
          {scope_map["scope"] || "participant", scope_map["uids"] || []}
        ]

        {state, touched, failed} =
          Enum.reduce(assignments, {state, [], %{}}, fn {scope, uids}, {st, acc, failed} ->
            Enum.reduce(List.wrap(uids), {st, acc, failed}, fn uid, {st2, acc2, failed2} ->
              uid = to_s(uid)

              if GroupState.member_limit_reached?(st2, guid, uid) do
                {st2, acc2,
                 Map.put(
                   failed2,
                   uid,
                   GroupState.member_failure(GroupState.member_limit_error(guid))
                 )}
              else
                {_user, st2} = UserState.ensure(st2, uid)
                st2 = GroupState.add_member(st2, guid, uid, scope)

                {st2, [Entities.member(guid, uid, scope, Time.now()) | acc2], failed2}
              end
            end)
          end)

        first = List.first(Enum.reverse(touched)) || %{"guid" => guid}

        touched_uids = Enum.map(touched, & &1["uid"])

        persist_ops(
          PersistenceOps.group(state, guid) ++
            PersistenceOps.members(state, guid) ++
            PersistenceOps.user(state, touched_uids) ++
            PersistenceOps.user_groups(state, touched_uids) ++
            PersistenceOps.unread_counts(state, touched_uids)
        )

        PubSubFanout.membership_changed(touched_uids)

        payload =
          %{
            "success" => map_size(failed) == 0,
            "members" => Enum.reverse(touched),
            "failed" => failed
          }
          |> Map.merge(first)

        {:reply, {:ok, payload}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:ban_group_member, guid, uid}, _from, state) do
    state = GroupState.ensure_group(state, guid)
    {_user, state} = UserState.ensure(state, uid)
    now = Time.now()

    state =
      update_in(state, ["banned", guid], &Map.put(&1 || %{}, uid, Entities.ban(guid, uid, now)))

    state = GroupState.remove_member(state, guid, uid)

    persist_ops(
      PersistenceOps.group(state, guid) ++
        PersistenceOps.user(state, [uid]) ++
        PersistenceOps.banned(state, guid) ++
        PersistenceOps.members(state, guid) ++
        PersistenceOps.user_groups(state, [uid]) ++
        PersistenceOps.unread_counts(state, [uid])
    )

    PubSubFanout.membership_changed([uid])

    {:reply,
     {:ok, %{"success" => true, "message" => "User banned.", "uid" => uid, "guid" => guid}},
     state}
  end

  def handle_call({:unban_group_member, guid, uid}, _from, state) do
    state = update_in(state, ["banned", guid], &Map.delete(&1 || %{}, uid))
    persist_ops(PersistenceOps.banned(state, guid))

    {:reply,
     {:ok, %{"success" => true, "message" => "User unbanned.", "uid" => uid, "guid" => guid}},
     state}
  end

  def handle_call({:banned_group_members, guid, params}, _from, state) do
    params = stringify_keys(params)
    search = params["searchKey"] || params["search"]

    members =
      state["banned"]
      |> Map.get(guid, %{})
      |> Enum.map(fn {uid, meta} ->
        Map.merge(state |> UserState.get_or_default(uid) |> UserState.public(), meta)
      end)
      |> Enum.filter(fn user ->
        blank?(search) or contains?(user["uid"], search) or contains?(user["name"], search)
      end)
      |> sort_by_key("uid")
      |> Pagination.page(params, 30, 100)

    {:reply, {:ok, members}, state}
  end

  def handle_call({:groups_for_user, uid}, _from, state) do
    groups =
      state
      |> get_in(["user_groups", uid])
      |> List.wrap()
      |> Enum.map(fn guid -> state["groups"][guid] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&GroupState.with_members_count(&1, state))

    {:reply, {:ok, groups}, state}
  end

  def handle_call({:send_message, sender_uid, params, uploads, opts}, _from, state) do
    params = stringify_keys(params)

    case build_message(state, sender_uid, params, uploads, opts) do
      {:error, error} ->
        {:reply, {:error, error}, state}

      {:ok, message, state} ->
        {state, retention_ops} = MessageState.store_with_retention(state, message)
        persist_ops(PersistenceOps.message_create(state, message) ++ retention_ops)
        PubSubFanout.message(state, message)
        {:reply, {:ok, message}, state}
    end
  end

  def handle_call({:edit_message, uid, id, params, opts}, _from, state) do
    params = stringify_keys(params)

    case Map.fetch(state["messages"], id) do
      :error ->
        {:reply, {:error, Errors.message_not_found(id)}, state}

      {:ok, message} ->
        case MessagePermissions.authorize(state, uid, message, :edit, opts) do
          :ok ->
            now = Time.now()
            data = MessageData.merge(message["data"] || %{}, params["data"] || params)

            message =
              message
              |> Map.put("data", enrich_data_entities(state, message, data))
              |> Map.put("editedAt", now)
              |> Map.put("editedBy", uid)
              |> Map.put("updatedAt", now)

            state = put_in(state, ["messages", id], message)
            {action_id, state} = take_counter(state, "next_id")

            receiver_entity =
              MessageState.receiver_entity(state, message["receiverType"], message["receiver"])

            action =
              MessageState.message_action(
                action_id,
                state,
                uid,
                message,
                receiver_entity,
                "edited"
              )

            {state, retention_ops} = MessageState.store_with_retention(state, action)

            persist_ops(
              [RedisPersistence.put("messages", id, message)] ++
                PersistenceOps.stored_message(state, action) ++
                retention_ops ++ PersistenceOps.next_id(state)
            )

            PubSubFanout.message(state, action)
            {:reply, {:ok, action}, state}

          {:error, error} ->
            {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:delete_message, uid, id, opts}, _from, state) do
    case Map.fetch(state["messages"], id) do
      :error ->
        {:reply, {:error, Errors.message_not_found(id)}, state}

      {:ok, message} ->
        case MessagePermissions.authorize(state, uid, message, :delete, opts) do
          :ok ->
            now = Time.now()
            original_participants = Unread.participants(state, message)
            state = Unread.message_deleted(state, message)

            message =
              message
              |> Map.put("deletedAt", now)
              |> Map.put("deletedBy", uid)
              |> Map.put("updatedAt", now)

            state = put_in(state, ["messages", id], message)
            {action_id, state} = take_counter(state, "next_id")

            receiver_entity =
              MessageState.receiver_entity(state, message["receiverType"], message["receiver"])

            action =
              MessageState.message_action(
                action_id,
                state,
                uid,
                message,
                receiver_entity,
                "deleted"
              )

            {state, retention_ops} = MessageState.store_with_retention(state, action)

            persist_ops(
              [RedisPersistence.put("messages", id, message)] ++
                PersistenceOps.stored_message(state, action) ++
                retention_ops ++
                PersistenceOps.unread_counts(state, original_participants) ++
                PersistenceOps.next_id(state)
            )

            PubSubFanout.message(state, action)
            {:reply, {:ok, action}, state}

          {:error, error} ->
            {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:get_message, id}, _from, state) do
    {:reply, Map.fetch(state["messages"], id), state}
  end

  def handle_call({:get_message_for, uid, id, opts}, _from, state) do
    reply =
      case Map.fetch(state["messages"], id) do
        {:ok, message} ->
          case Access.message(state, uid, message, opts) do
            :ok -> {:ok, hydrate_message_for_viewer(state, uid, message)}
            {:error, error} -> {:error, error}
          end

        :error ->
          :error
      end

    {:reply, reply, state}
  end

  def handle_call({:delete_conversation, conversation_id}, _from, state) do
    ids =
      [conversation_id]
      |> Kernel.++(
        if String.starts_with?(conversation_id, "group_"),
          do: [],
          else: [group_conversation_id(conversation_id)]
      )
      |> Enum.uniq()

    {state, ops} = delete_conversation_indexes(state, ids)

    persist_ops(ops)
    {:reply, {:ok, %{"success" => true, "conversationId" => conversation_id}}, state}
  end

  def handle_call({:hide_conversation, uid, receiver_type, receiver_id}, _from, state) do
    case Access.conversation(state, uid, receiver_type, receiver_id) do
      :ok ->
        {state, payload} = Conversations.hide(state, uid, receiver_type, receiver_id, Time.now())
        persist_ops(PersistenceOps.hidden_conversations(state, uid))
        {:reply, {:ok, payload}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:find_message_by_muid, muid}, _from, state) do
    result =
      case get_in(state, ["message_muids", muid]) do
        nil -> nil
        id -> get_in(state, ["messages", to_s(id)])
      end

    {:reply, if(result, do: {:ok, result}, else: :error), state}
  end

  def handle_call({:find_message_by_muid_for, uid, muid, opts}, _from, state) do
    result =
      case get_in(state, ["message_muids", muid]) do
        nil -> nil
        id -> get_in(state, ["messages", to_s(id)])
      end

    reply =
      case result do
        nil ->
          :error

        message ->
          case Access.message(state, uid, message, opts) do
            :ok -> {:ok, hydrate_message_for_viewer(state, uid, message)}
            {:error, error} -> {:error, error}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:messages_for_user, uid, peer_uid, params}, _from, state) do
    conv_id = user_conversation_id(uid, peer_uid)

    messages =
      state
      |> ConversationView.messages(conv_id, params)
      |> hydrate_messages_for_viewer(state, uid)

    {:reply, {:ok, messages}, state}
  end

  def handle_call({:messages_for_group, uid, guid, params}, _from, state) do
    if GroupState.read_allowed?(state, guid, uid) do
      conv_id = group_conversation_id(guid)

      messages =
        state
        |> ConversationView.messages(conv_id, params)
        |> hydrate_messages_for_viewer(state, uid)

      {:reply, {:ok, messages}, state}
    else
      {:reply, {:error, Errors.not_member(guid)}, state}
    end
  end

  def handle_call({:messages_for_thread, uid, parent_id, params}, _from, state) do
    with {:ok, parent} <- Map.fetch(state["messages"], parent_id),
         :ok <- Access.message(state, uid, parent) do
      ids = Map.get(state["thread_messages"], parent_id, [])

      messages =
        ids
        |> ConversationView.messages_by_ids(state, params)
        |> hydrate_messages_for_viewer(state, uid)

      {:reply, {:ok, messages}, state}
    else
      :error -> {:reply, {:ok, []}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:mark_read, uid, receiver_type, receiver_id, message_id}, _from, state) do
    case Access.receipt(state, uid, receiver_type, receiver_id, message_id) do
      :ok ->
        {state, payload} =
          Conversations.mark_read(state, uid, receiver_type, receiver_id, message_id, Time.now())

        persist_ops(PersistenceOps.reads(state, uid) ++ PersistenceOps.unread_counts(state, uid))
        PubSubFanout.receipt(payload, uid, receiver_type, receiver_id, "read")
        {:reply, {:ok, payload}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:mark_delivered, uid, receiver_type, receiver_id, message_id}, _from, state) do
    case Access.receipt(state, uid, receiver_type, receiver_id, message_id) do
      :ok ->
        {state, payload} =
          Conversations.mark_delivered(
            state,
            uid,
            receiver_type,
            receiver_id,
            message_id,
            Time.now()
          )

        persist_ops(PersistenceOps.delivered(state, uid))
        PubSubFanout.receipt(payload, uid, receiver_type, receiver_id, "delivered")
        {:reply, {:ok, payload}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:mark_unread, uid, receiver_type, receiver_id, message_id}, _from, state) do
    case Access.receipt(state, uid, receiver_type, receiver_id, message_id) do
      :ok ->
        {state, conv_id} =
          Conversations.mark_unread(
            state,
            uid,
            receiver_type,
            receiver_id,
            message_id,
            Time.now()
          )

        conv = ConversationView.build(state, uid, conv_id)
        persist_ops(PersistenceOps.reads(state, uid) ++ PersistenceOps.unread_counts(state, uid))
        {:reply, {:ok, %{"conversation" => conv}}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:unread_counts, uid, params}, _from, state) do
    params = stringify_keys(params)
    receiver_type = params["receiverType"]

    counts =
      ConversationView.ids_for_user(state, uid)
      |> Enum.map(fn conv_id -> {conv_id, Unread.count(state, uid, conv_id)} end)
      |> Enum.filter(fn {_conv_id, count} -> count > 0 end)
      |> Enum.map(fn {conv_id, count} ->
        ConversationView.unread_count_row(state, uid, conv_id, count)
      end)
      |> Enum.filter(fn row -> blank?(receiver_type) or row["entityType"] == receiver_type end)
      |> Enum.filter(fn row ->
        cond do
          not blank?(params["uid"]) ->
            row["entityType"] == "user" and row["entityId"] == to_s(params["uid"])

          not blank?(params["guid"]) ->
            row["entityType"] == "group" and row["entityId"] == to_s(params["guid"])

          true ->
            true
        end
      end)

    {:reply, {:ok, counts}, state}
  end

  def handle_call({:conversations, uid, params}, _from, state) do
    params = stringify_keys(params)
    type = params["conversationType"] || params["type"]

    convs =
      ConversationView.ids_for_user(state, uid)
      |> Enum.map(&ConversationView.build(state, uid, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn conv -> blank?(type) or conv["conversationType"] == type end)
      |> Enum.sort_by(fn conv -> -(get_in(conv, ["lastMessage", "sentAt"]) || 0) end)
      |> Pagination.page(params, 30, 50)

    {:reply, {:ok, convs}, state}
  end

  def handle_call({:conversation, uid, receiver_type, receiver_id}, _from, state) do
    case Access.conversation(state, uid, receiver_type, receiver_id) do
      :ok ->
        conv_id = conversation_id_for(uid, receiver_type, receiver_id)
        {:reply, {:ok, ConversationView.build(state, uid, conv_id)}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:add_reaction, uid, id, reaction}, _from, state) do
    with {:ok, message} <- Map.fetch(state["messages"], id),
         :ok <- Access.message(state, uid, message) do
      if message["deletedAt"] do
        {:reply, {:error, Errors.forbidden("Cannot react to a deleted message.")}, state}
      else
        {:reply, reply, state} =
          add_reaction_reply(state, uid, id, URI.decode(to_s(reaction)), message)

        {:reply, reply, state}
      end
    else
      :error -> {:reply, {:error, Errors.message_not_found(id)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:remove_reaction, uid, id, reaction}, _from, state) do
    with {:ok, message} <- Map.fetch(state["messages"], id),
         :ok <- Access.message(state, uid, message) do
      if message["deletedAt"] do
        {:reply, {:error, Errors.forbidden("Cannot unreact to a deleted message.")}, state}
      else
        {:reply, reply, state} =
          remove_reaction_reply(state, uid, id, URI.decode(to_s(reaction)), message)

        {:reply, reply, state}
      end
    else
      :error -> {:reply, {:error, Errors.message_not_found(id)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:toggle_reaction, uid, id, reaction}, _from, state) do
    with {:ok, message} <- Map.fetch(state["messages"], id),
         :ok <- Access.message(state, uid, message) do
      if message["deletedAt"] do
        {:reply, {:error, Errors.forbidden("Cannot react to a deleted message.")}, state}
      else
        reaction = URI.decode(to_s(reaction))

        if get_in(state, ["reactions", id, reaction, uid]) do
          {:reply, reply, state} = remove_reaction_reply(state, uid, id, reaction, message)
          {:reply, reply, state}
        else
          {:reply, reply, state} = add_reaction_reply(state, uid, id, reaction, message)
          {:reply, reply, state}
        end
      end
    else
      :error -> {:reply, {:error, Errors.message_not_found(id)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:reactions, uid, id, reaction}, _from, state) do
    with {:ok, message} <- Map.fetch(state["messages"], id),
         :ok <- Access.message(state, uid, message) do
      rows =
        state
        |> get_in(["reactions", id])
        |> case do
          nil ->
            []

          map when is_binary(reaction) ->
            map |> Map.get(URI.decode(reaction), %{}) |> Map.values()

          map ->
            map |> Map.values() |> Enum.flat_map(&Map.values/1)
        end
        |> Enum.map(fn r -> Map.put(r, "reactedByMe", r["uid"] == uid) end)

      {:reply, {:ok, rows}, state}
    else
      :error -> {:reply, {:error, Errors.message_not_found(id)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  # Loading/persistence

  defp load_or_seed_state do
    state =
      State.default()
      |> RedisPersistence.load_or_seed(&seed_state/0)
      |> Indexes.rebuild()
      |> Conversations.rebuild_latest()
      |> Unread.rebuild()

    persist_ops(
      PersistenceOps.secondary_indexes(state) ++
        PersistenceOps.conversation_latest(state, Map.keys(state["conversation_latest"])) ++
        PersistenceOps.unread_counts(state, Map.keys(state["unread_counts"]))
    )

    state
  end

  defp persist(state) do
    RedisPersistence.replace_all(state)
  end

  defp persist_ops(ops), do: RedisPersistence.write(ops)

  defp refresh_request_state(request, state, refresh) do
    state = RedisPersistence.refresh_keys(State.default(), state, refresh)

    RedisPersistence.refresh_keys(
      State.default(),
      state,
      RequestPlan.followup_refresh(request, state)
    )
  end

  defp pubsub_key_refresh_keys(keys) do
    keys
    |> List.wrap()
    |> Enum.flat_map(fn
      {:user, uid} ->
        user_cache_keys(uid)

      {:group, guid} ->
        group_cache_keys(guid)

      _other ->
        []
    end)
  end

  defp event_refresh_keys(%{"type" => "message", "body" => %{} = message}) do
    message_cache_keys(message) ++ action_subject_message_keys(message)
  end

  defp event_refresh_keys(%{"type" => "reaction", "body" => %{} = body}) do
    message_id = body["messageId"] || body["message_id"] || body["id"]
    message_record_keys(message_id) ++ [{"reactions", message_id}]
  end

  defp event_refresh_keys(%{"type" => "receipts", "sender" => uid, "body" => %{} = body} = event) do
    receiver_type = event["receiverType"] || body["receiverType"] || body["type"] || "user"
    receiver = event["receiver"] || body["receiver"] || body["receiverId"]
    conv_id = body["conversationId"] || conversation_id_for(uid, receiver_type, receiver)

    [
      {"reads", uid},
      {"delivered", uid},
      {"unread_counts", uid},
      {"conversation_latest", conv_id},
      {"conversation_users", conv_id}
    ]
  end

  defp event_refresh_keys(_event), do: []

  defp message_cache_keys(message) do
    conv_id =
      message["conversationId"] ||
        conversation_id_for(message["sender"], message["receiverType"], message["receiver"])

    parent_id = message["parentId"] || message["parentMessageId"]
    muid = message["muid"]

    message_record_keys(message["id"]) ++
      [
        {"reactions", message["id"]},
        {"conversation_messages", conv_id},
        {"conversation_latest", conv_id},
        {"conversation_users", conv_id},
        {"message_muids", muid}
      ] ++
      message_record_keys(parent_id) ++
      if(blank?(parent_id), do: [], else: [{"thread_messages", parent_id}]) ++
      user_cache_keys(message["sender"]) ++ receiver_cache_keys(message)
  end

  defp action_subject_message_keys(message) do
    case get_in(message, ["data", "entities", "on", "entity"]) do
      %{"id" => _id, "conversationId" => _conv_id} = subject -> message_cache_keys(subject)
      %{"id" => id} -> message_record_keys(id) ++ [{"reactions", id}]
      _other -> []
    end
  end

  defp receiver_cache_keys(%{"receiverType" => "group", "receiver" => guid}),
    do: group_cache_keys(guid)

  defp receiver_cache_keys(%{"receiver" => uid}), do: user_cache_keys(uid)
  defp receiver_cache_keys(_message), do: []

  defp user_cache_keys(uid) do
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

  defp group_cache_keys(guid) do
    guid = to_s(guid)

    if blank?(guid) do
      []
    else
      conv_id = group_conversation_id(guid)

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

  defp message_record_keys(value),
    do: if(blank?(value) or to_s(value) == "0", do: [], else: [{"messages", value}])

  defp take_counter(state, counter) do
    fallback = max(to_int(state[counter]), 1)
    value = RedisPersistence.take_counter(counter, fallback)
    value = if value < 1, do: fallback, else: value
    {value, Map.put(state, counter, max(fallback, value + 1))}
  end

  defp seed_state do
    users =
      State.decode_seed(Config.seed_users_json(), State.default_users())
      |> Enum.map(&UserState.normalise/1)

    groups =
      State.decode_seed(Config.seed_groups_json(), State.default_groups())
      |> Enum.map(&normalise_group/1)

    state = State.default()

    state =
      Enum.reduce(users, state, fn user, st ->
        st
        |> UserState.put(user)
        |> UserState.maybe_store_embedded_token(user)
      end)

    state =
      Enum.reduce(groups, state, fn group, st ->
        st
        |> put_in(["groups", group["guid"]], group)
        |> GroupState.ensure_member_map(group["guid"])
      end)

    Indexes.rebuild(state)
  end

  # Message and conversation helpers

  defp build_message(state, sender_uid, params, uploads, opts) do
    receiver = params["receiver"] || params["receiverId"]
    receiver_type = params["receiverType"] || "user"
    receiver_type = receiver_type |> to_s() |> String.downcase()
    admin? = Keyword.get(opts, :admin?, false)

    state =
      if admin? and receiver_type == "group" and not blank?(receiver),
        do: GroupState.ensure_group(state, to_s(receiver)),
        else: state

    cond do
      blank?(receiver) ->
        {:error, Errors.missing("receiver")}

      receiver_type not in ["user", "group"] ->
        {:error, Errors.invalid("receiverType", "receiverType must be user or group.")}

      receiver_type == "group" and not Map.has_key?(state["groups"], to_s(receiver)) ->
        {:error, Errors.group_not_found(receiver)}

      receiver_type == "group" and not admin? and
          not GroupState.member?(state, to_s(receiver), sender_uid) ->
        {:error, Errors.not_member(receiver)}

      true ->
        {sender, state} = UserState.ensure(state, sender_uid)
        {state, receiver_entity} = ensure_receiver_entity(state, receiver_type, to_s(receiver))

        cond do
          not blank?(sender["deactivatedAt"]) and not admin? ->
            {:error, Errors.no_auth()}

          receiver_type == "user" and not blank?(receiver_entity["deactivatedAt"]) and not admin? ->
            {:error, Errors.user_not_found(receiver)}

          true ->
            {id, state} = take_counter(state, "next_id")
            now = Time.now()
            type = params["type"] || MessageData.infer_type(params, uploads)
            category = params["category"] || "message"

            case MessageData.normalise(params, uploads) do
              {:ok, data} ->
                message =
                  Entities.message(%{
                    "id" => id,
                    "muid" => params["muid"],
                    "sender" => sender["uid"],
                    "receiver" => to_s(receiver),
                    "receiverType" => receiver_type,
                    "type" => type,
                    "category" => category,
                    "data" => %{},
                    "sentAt" => now,
                    "updatedAt" => now,
                    "conversationId" => conversation_id_for(sender_uid, receiver_type, receiver),
                    "resource" => params["resource"],
                    "parentId" => params["parentId"] || params["parentMessageId"],
                    "tags" => params["tags"]
                  })

                parent_id = params["parentId"] || params["parentMessageId"]

                case Access.parent_message(
                       state,
                       sender_uid,
                       parent_id,
                       message["conversationId"],
                       admin?: admin?
                     ) do
                  :ok ->
                    data =
                      data
                      |> Map.put_new("reactions", [])
                      |> MessageData.put_entity("sender", "user", UserState.public(sender))
                      |> MessageData.put_entity("receiver", receiver_type, receiver_entity)

                    {:ok, message |> Map.put("data", data) |> MessageState.expose_metadata(),
                     state}

                  {:error, error} ->
                    {:error, error}
                end

              {:error, error} ->
                {:error, error}
            end
        end
    end
  end

  defp enrich_data_entities(state, message, data) do
    sender = UserState.get_or_default(state, message["sender"])

    {_state, receiver_entity} =
      ensure_receiver_entity(state, message["receiverType"], message["receiver"])

    data
    |> Map.put_new("reactions", get_in(message, ["data", "reactions"]) || [])
    |> MessageData.put_entity("sender", "user", UserState.public(sender))
    |> MessageData.put_entity("receiver", message["receiverType"], receiver_entity)
  end

  defp add_reaction_reply(state, uid, id, reaction, message) do
    now = Time.now()
    {reaction_id, state} = take_counter(state, "next_reaction_id")
    user = state |> UserState.get_or_default(uid) |> UserState.public()

    reaction_obj =
      Entities.reaction(%{
        "id" => reaction_id,
        "messageId" => message["id"],
        "reaction" => reaction,
        "uid" => uid,
        "reactedAt" => now,
        "reactedBy" => user
      })

    state =
      update_in(state, ["reactions", id], fn reaction_map ->
        Map.update(reaction_map || %{}, reaction, %{uid => reaction_obj}, fn by_uid ->
          Map.put(by_uid || %{}, uid, reaction_obj)
        end)
      end)

    message = MessageState.refresh_reactions(state, message, nil)
    state = put_in(state, ["messages", id], message)
    reply_message = hydrate_message_for_viewer(state, uid, message)

    persist_ops(
      PersistenceOps.reactions(state, id) ++
        [RedisPersistence.put("messages", id, message)] ++
        PersistenceOps.next_reaction_id(state)
    )

    PubSubFanout.reaction(state, message, reaction_obj, "message_reaction_added", uid)
    PubSubFanout.message_update(state, message)
    {:reply, {:ok, reply_message}, state}
  end

  defp remove_reaction_reply(state, uid, id, reaction, message) do
    reaction_obj =
      get_in(state, ["reactions", id, reaction, uid]) ||
        Entities.reaction(%{
          "messageId" => message["id"],
          "reaction" => reaction,
          "uid" => uid,
          "reactedAt" => Time.now(),
          "reactedBy" => state |> UserState.get_or_default(uid) |> UserState.public()
        })

    state = MessageState.remove_reaction(state, id, reaction, uid)

    message = MessageState.refresh_reactions(state, message, nil)
    state = put_in(state, ["messages", id], message)
    reply_message = hydrate_message_for_viewer(state, uid, message)

    persist_ops(
      PersistenceOps.reactions(state, id) ++ [RedisPersistence.put("messages", id, message)]
    )

    PubSubFanout.reaction(state, message, reaction_obj, "message_reaction_removed", uid)
    PubSubFanout.message_update(state, message)
    {:reply, {:ok, reply_message}, state}
  end

  defp hydrate_messages_for_viewer(messages, state, uid),
    do: Enum.map(messages, &hydrate_message_for_viewer(state, uid, &1))

  defp hydrate_message_for_viewer(state, uid, message),
    do: MessageState.refresh_reactions(state, message, uid)

  defp delete_conversation_indexes(state, conv_ids) do
    {state, %{conversation_ids: conv_ids, touched_user_buckets: touched}} =
      Conversations.delete_indexes(state, conv_ids, [
        "reads",
        "delivered",
        "hidden_conversations",
        "user_conversations",
        "unread_counts"
      ])

    conversation_user_uids =
      conv_ids
      |> Enum.flat_map(fn conv_id -> get_in(state, ["conversation_users", conv_id]) || [] end)
      |> Enum.uniq()

    state = Indexes.remove_conversations(state, conv_ids)

    touched_user_conversation_uids =
      ((touched["user_conversations"] || []) ++ conversation_user_uids)
      |> Enum.uniq()

    ops =
      Enum.map(conv_ids, &RedisPersistence.delete("conversation_messages", &1)) ++
        Enum.map(conv_ids, &RedisPersistence.delete("conversation_latest", &1)) ++
        Enum.map(conv_ids, &RedisPersistence.delete("conversation_users", &1)) ++
        Enum.flat_map(touched["reads"], &PersistenceOps.reads(state, &1)) ++
        Enum.flat_map(touched["delivered"], &PersistenceOps.delivered(state, &1)) ++
        Enum.flat_map(
          touched["hidden_conversations"],
          &PersistenceOps.hidden_conversations(state, &1)
        ) ++
        PersistenceOps.user_conversations(state, touched_user_conversation_uids) ++
        PersistenceOps.unread_counts(
          state,
          ((touched["unread_counts"] || []) ++ conversation_user_uids) |> Enum.uniq()
        )

    {state, ops}
  end

  defp delete_message_records(state, message_ids) do
    messages =
      message_ids
      |> List.wrap()
      |> Enum.map(&to_s/1)
      |> Enum.map(&state["messages"][&1])
      |> Enum.reject(&is_nil/1)

    state = Indexes.remove_messages(state, messages)

    {state, %{message_ids: message_ids, thread_ids: thread_ids}} =
      Conversations.delete_message_records(state, message_ids)

    ops =
      Enum.map(message_ids, &RedisPersistence.delete("messages", &1)) ++
        Enum.map(message_ids, &RedisPersistence.delete("reactions", &1)) ++
        Enum.flat_map(messages, &delete_message_muid_ops/1) ++
        Enum.map(thread_ids, &RedisPersistence.delete("thread_messages", &1))

    {state, ops}
  end

  defp conversation_id_for(uid, receiver_type, receiver),
    do: Conversations.conversation_id_for(uid, receiver_type, receiver)

  defp user_conversation_id(a, b), do: Conversations.user_conversation_id(a, b)

  defp group_conversation_id(guid), do: Conversations.group_conversation_id(guid)

  defp ensure_receiver_entity(state, "user", uid) do
    {user, state} = UserState.ensure(state, uid)
    {state, UserState.public(user)}
  end

  defp ensure_receiver_entity(state, "group", guid) do
    group = state["groups"][guid] || normalise_group(%{"guid" => guid, "name" => guid})
    state = put_in(state, ["groups", guid], group)
    {state, GroupState.with_members_count(group, state)}
  end

  # Auth/users/groups

  defp authenticate_in_state(state, token) when token in [nil, ""],
    do: {{:error, Errors.no_auth()}, state}

  defp authenticate_in_state(state, token) do
    token = to_s(token)

    cond do
      uid = state["tokens"][token] ->
        user = UserState.get_or_default(state, uid)

        if user["deactivatedAt"] do
          {{:error, Errors.no_auth()}, state}
        else
          {{:ok, user}, state}
        end

      Config.accept_uid_tokens?() and String.starts_with?(token, "uid:") ->
        uid = String.replace_prefix(token, "uid:", "")
        {user, state} = UserState.ensure(state, uid)
        state = put_in(state, ["tokens", token], user["uid"])
        {{:ok, user}, state}

      String.starts_with?(token, "local.") ->
        authenticate_local_jwt(state, token)

      true ->
        {{:error, Errors.no_auth()}, state}
    end
  end

  defp authenticate_local_jwt(state, token) do
    with {:ok, auth_token} <- AuthTokens.local_jwt_token(token) do
      authenticate_in_state(state, auth_token)
    else
      _ -> {{:error, Errors.no_auth()}, state}
    end
  end

  defp me_payload(user, token) do
    user
    |> UserState.public()
    |> Map.merge(%{
      "authToken" => token,
      "jwt" => jwt_for(user, token),
      "fat" => token,
      "wsChannel" => "user_#{user["uid"]}",
      "settings" => Config.settings()
    })
  end

  defp jwt_for(user, token) do
    AuthTokens.local_jwt(user["uid"], token)
  end

  defp normalise_group(attrs) do
    Entities.group(attrs)
  end

  # Generic helpers

  defp stringify_keys(%{__struct__: _} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_s(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

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

  defp blank?(value), do: value in [nil, "", false]
  defp contains?(a, b), do: String.contains?(String.downcase(to_s(a)), String.downcase(to_s(b)))
  defp sort_by_key(rows, key), do: Enum.sort_by(rows, &to_s(&1[key]))

  defp map_keys(map) when is_map(map), do: Map.keys(map)
  defp map_keys(_other), do: []

  defp delete_message_muid_ops(message) do
    case to_s(message["muid"]) do
      "" -> []
      muid -> [RedisPersistence.delete("message_muids", muid)]
    end
  end
end
