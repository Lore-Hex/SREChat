defmodule OpenChatWeb.ApiRouter do
  @moduledoc false
  use Plug.Router
  import Plug.Conn
  alias OpenChat.{Config, Errors, Media, Store, Time}
  alias OpenChat.Store.AuthTokens
  alias OpenChatWeb.{ApiResponse, Auth, JSON}

  plug(:match)
  plug(:dispatch)

  get "/settings" do
    JSON.ok(conn, Config.settings())
  end

  post "/users/:uid/auth_tokens" do
    with_admin_or_open(conn, fn conn ->
      case Store.create_auth_token(uid) do
        {:ok, data} -> JSON.ok(conn, data)
        {:error, e} -> JSON.error(conn, e, 400)
      end
    end)
  end

  post "/admin/users/auth" do
    with_admin_or_open(conn, fn conn ->
      uid = conn.params["uid"] || get_in(conn.body_params, ["uid"])

      if blank?(uid),
        do: JSON.error(conn, Errors.missing("uid"), 400),
        else: JSON.ok(conn, elem(Store.create_auth_token(uid), 1))
    end)
  end

  delete "/admin/users/auth/:token" do
    with_admin_or_open(conn, fn conn ->
      {:ok, data} = Store.revoke_auth_token(token)
      JSON.ok(conn, data)
    end)
  end

  get "/me" do
    with_user(conn, fn conn, _user, token ->
      case Store.me(token) do
        {:ok, me} -> JSON.ok(conn, me)
        {:error, e} -> JSON.error(conn, e, 401)
      end
    end)
  end

  put "/me" do
    with_user(conn, fn conn, _user, token ->
      case Store.me(token) do
        {:ok, me} -> JSON.ok(conn, me)
        {:error, e} -> JSON.error(conn, e, 401)
      end
    end)
  end

  delete "/me" do
    with_user(conn, fn conn, _user, token ->
      Store.revoke_auth_token(token)
      JSON.ok(conn, %{"success" => true})
    end)
  end

  post "/me/jwt" do
    with_user(conn, fn conn, user, token ->
      JSON.ok(conn, %{
        "jwt" => AuthTokens.local_jwt(user["uid"], token)
      })
    end)
  end

  post "/user_sessions" do
    with_user(conn, fn conn, user, _token ->
      JSON.ok(conn, %{
        "uid" => user["uid"],
        "sessionId" => conn.params["deviceId"] || conn.params["sessionId"] || "session",
        "createdAt" => Time.now()
      })
    end)
  end

  get "/users" do
    with_user(conn, fn conn, _user, _token ->
      {:ok, users} = Store.list_users(conn.query_params)
      JSON.ok(conn, users)
    end)
  end

  post "/users" do
    with_admin_or_open(conn, fn conn ->
      case Store.upsert_user(conn.body_params) do
        {:ok, user} -> JSON.ok(conn, user, 201)
        {:error, e} -> JSON.error(conn, e, 400)
      end
    end)
  end

  put "/users" do
    with_admin_or_open(conn, fn conn ->
      uids = conn.body_params["uidsToActivate"] || conn.body_params["uids"] || []
      {:ok, data} = Store.reactivate_users(uids)
      JSON.ok(conn, data)
    end)
  end

  get "/users/:uid" do
    with_user(conn, fn conn, user, _token ->
      case Store.get_user_for(user["uid"], uid) do
        {:ok, user} -> JSON.ok(conn, user)
        :error -> JSON.error(conn, Errors.user_not_found(uid), 404)
      end
    end)
  end

  put "/users/:uid" do
    with_admin_or_open(conn, fn conn ->
      case Store.upsert_user(Map.put(conn.body_params, "uid", uid)) do
        {:ok, user} -> JSON.ok(conn, user)
        {:error, e} -> JSON.error(conn, e, 400)
      end
    end)
  end

  delete "/users/:uid" do
    with_admin_or_open(conn, fn conn ->
      case Store.delete_user(uid) do
        {:ok, data} -> JSON.ok(conn, data)
        {:error, e} -> JSON.error(conn, e, 404)
      end
    end)
  end

  get "/blockedusers" do
    with_user(conn, fn conn, user, _token ->
      {:ok, users, meta} = Store.blocked_users(user["uid"], conn.query_params)
      JSON.raw(conn, %{"data" => users, "meta" => meta})
    end)
  end

  post "/blockedusers" do
    with_user(conn, fn conn, user, _token ->
      blocked_uids = conn.body_params["blockedUids"] || conn.body_params["uids"] || []
      {:ok, data} = Store.block_users(user["uid"], blocked_uids)
      JSON.ok(conn, data)
    end)
  end

  delete "/blockedusers" do
    with_user(conn, fn conn, user, _token ->
      blocked_uids = conn.body_params["blockedUids"] || conn.body_params["uids"] || []
      {:ok, data} = Store.unblock_users(user["uid"], blocked_uids)
      JSON.ok(conn, data)
    end)
  end

  get "/groups" do
    with_user(conn, fn conn, _user, _token ->
      {:ok, groups} = Store.list_groups(conn.query_params)
      JSON.ok(conn, groups)
    end)
  end

  post "/groups" do
    with_admin_or_open(conn, fn conn ->
      case Store.upsert_group(conn.body_params) do
        {:ok, group} -> JSON.ok(conn, group, 201)
        {:error, e} -> JSON.error(conn, e, 400)
      end
    end)
  end

  get "/groups/:guid" do
    with_user(conn, fn conn, _user, _token ->
      case Store.get_group(guid) do
        {:ok, group} -> JSON.ok(conn, group)
        :error -> JSON.error(conn, Errors.group_not_found(guid), 404)
      end
    end)
  end

  put "/groups/:guid" do
    with_admin_or_open(conn, fn conn ->
      case Store.upsert_group(Map.put(conn.body_params, "guid", guid)) do
        {:ok, group} -> JSON.ok(conn, group)
        {:error, e} -> JSON.error(conn, e, 400)
      end
    end)
  end

  delete "/groups/:guid" do
    with_admin_or_open(conn, fn conn ->
      {:ok, data} = Store.delete_group(guid)
      JSON.ok(conn, data)
    end)
  end

  get "/groups/:guid/members" do
    with_admin_or_user(
      conn,
      fn conn -> group_members_response(conn, guid) end,
      fn conn ->
        with_user(conn, fn conn, _user, _token ->
          group_members_response(conn, guid)
        end)
      end
    )
  end

  post "/groups/:guid/members" do
    if sdk_join_request?(conn) do
      join_group_response(conn, guid)
    else
      with_admin_or_user(
        conn,
        fn conn -> set_group_scopes_response(conn, guid) end,
        fn conn -> join_group_response(conn, guid) end
      )
    end
  end

  put "/groups/:guid/members" do
    with_admin_or_user(
      conn,
      fn conn -> set_group_scopes_response(conn, guid) end,
      fn conn ->
        with_user(conn, fn conn, user, _token ->
          uids = conn.body_params["uids"] || conn.body_params["participants"] || []
          scope = conn.body_params["scope"] || "participant"

          store_response(conn, Store.add_group_members(guid, uids, scope, actor_uid: user["uid"]))
        end)
      end
    )
  end

  delete "/groups/:guid/members" do
    with_user(conn, fn conn, user, _token ->
      {:ok, data} = Store.leave_group(guid, user["uid"])
      JSON.ok(conn, data)
    end)
  end

  delete "/groups/:guid/members/:uid" do
    cond do
      Auth.admin?(conn) ->
        {:ok, data} = Store.leave_group(guid, uid)
        JSON.ok(conn, data)

      not blank?(api_key_header(conn)) ->
        JSON.error(conn, Errors.forbidden("Invalid apiKey."), 403)

      not blank?(Auth.token(conn)) ->
        with_user(conn, fn conn, user, _token ->
          if user["uid"] == uid do
            {:ok, data} = Store.leave_group(guid, uid)
            JSON.ok(conn, data)
          else
            JSON.error(conn, Errors.forbidden("Users can only remove their own membership."), 403)
          end
        end)

      true ->
        JSON.error(conn, Errors.forbidden("Invalid apiKey."), 403)
    end
  end

  put "/groups/:guid/members/:uid" do
    with_admin_or_open(conn, fn conn ->
      scope = conn.body_params["scope"] || "participant"

      case Store.add_group_members(guid, [uid], scope) do
        {:ok, data} -> JSON.ok(conn, data)
        {:error, e} -> JSON.error(conn, e, 400)
      end
    end)
  end

  get "/groups/:guid/bannedusers" do
    with_admin_or_open(conn, fn conn ->
      {:ok, data} = Store.banned_group_members(guid, conn.query_params)
      JSON.ok(conn, data)
    end)
  end

  post "/groups/:guid/bannedusers/:uid" do
    with_admin_or_open(conn, fn conn ->
      {:ok, data} = Store.ban_group_member(guid, uid)
      JSON.ok(conn, data)
    end)
  end

  delete "/groups/:guid/bannedusers/:uid" do
    with_admin_or_open(conn, fn conn ->
      {:ok, data} = Store.unban_group_member(guid, uid)
      JSON.ok(conn, data)
    end)
  end

  get "/users/:list_id/messages" do
    with_user(conn, fn conn, user, _token ->
      case Store.messages_for_user(user["uid"], list_id, conn.query_params) do
        {:ok, messages} ->
          wait_for_dm_history_connect_grace()
          messages_response(conn, messages, conn.query_params)

        {:error, e} ->
          JSON.error(conn, e, 400)
      end
    end)
  end

  get "/groups/:list_id/messages" do
    with_user(conn, fn conn, user, _token ->
      case Store.messages_for_group(user["uid"], list_id, conn.query_params) do
        {:ok, messages} -> messages_response(conn, messages, conn.query_params)
        {:error, e} -> JSON.error(conn, e, 400)
      end
    end)
  end

  get "/messages/:list_id/thread" do
    with_user(conn, fn conn, user, _token ->
      case Store.messages_for_thread(user["uid"], list_id, conn.query_params) do
        {:ok, messages} -> messages_response(conn, messages, conn.query_params)
        {:error, e} -> JSON.error(conn, e, error_status(e, 400))
      end
    end)
  end

  post "/messages/:parent_id/thread" do
    with_user(conn, fn conn, user, _token ->
      params = conn.body_params |> Map.put("parentId", parent_id)
      send_message_response(conn, user["uid"], params)
    end)
  end

  get "/messages/:message_id/reactions/:reaction" do
    with_user(conn, fn conn, user, _token ->
      reactions_response(
        conn,
        Store.reactions(user["uid"], message_id, reaction),
        conn.query_params
      )
    end)
  end

  get "/messages/:message_id/reactions" do
    with_user(conn, fn conn, user, _token ->
      reactions_response(conn, Store.reactions(user["uid"], message_id), conn.query_params)
    end)
  end

  post "/messages/:message_id/reactions/:reaction" do
    with_user(conn, fn conn, user, _token ->
      reaction_response(conn, :add, user["uid"], message_id, reaction)
    end)
  end

  delete "/messages/:message_id/reactions/:reaction" do
    with_user(conn, fn conn, user, _token ->
      reaction_response(conn, :remove, user["uid"], message_id, reaction)
    end)
  end

  get "/messages" do
    with_user(conn, fn conn, user, _token ->
      params = Map.merge(conn.query_params, conn.params)

      cond do
        truthy?(params["unread"]) and truthy?(params["count"]) ->
          {:ok, rows} = Store.unread_counts(user["uid"], params)
          JSON.ok(conn, rows)

        legacy_direct_messages_query?(params) ->
          peer_uid = params["sender"] || params["receiver"] || params["uid"]

          case Store.messages_for_user(user["uid"], peer_uid, params) do
            {:ok, messages} -> messages_response(conn, messages, params)
            {:error, e} -> JSON.error(conn, e, 400)
          end

        legacy_group_messages_query?(params) ->
          guid = params["receiver"] || params["guid"] || params["group"]

          case Store.messages_for_group(user["uid"], guid, params) do
            {:ok, messages} -> messages_response(conn, messages, params)
            {:error, e} -> JSON.error(conn, e, 400)
          end

        true ->
          JSON.ok(conn, [])
      end
    end)
  end

  post "/messages" do
    with_admin_or_user(
      conn,
      fn conn ->
        sender_uid = conn.body_params["sender"] || conn.body_params["senderUid"] || "system"
        send_message_response(conn, sender_uid, conn.body_params, 201, admin?: true)
      end,
      fn conn ->
        with_user(conn, fn conn, user, _token ->
          send_message_response(conn, user["uid"], conn.body_params, 201)
        end)
      end
    )
  end

  get "/messages/:message_id" do
    with_user(conn, fn conn, user, _token ->
      case Store.get_message_for(user["uid"], message_id) do
        {:ok, message} -> JSON.ok(conn, message)
        {:error, e} -> JSON.error(conn, e, error_status(e, 400))
        :error -> JSON.error(conn, Errors.message_not_found(message_id), 404)
      end
    end)
  end

  put "/messages/:message_id" do
    with_admin_or_user(
      conn,
      fn conn ->
        store_response(
          conn,
          Store.edit_message(
            "system",
            message_id,
            conn.body_params,
            origin_opts(conn, admin?: true)
          )
        )
      end,
      fn conn ->
        with_user(conn, fn conn, user, _token ->
          store_response(
            conn,
            Store.edit_message(user["uid"], message_id, conn.body_params, origin_opts(conn))
          )
        end)
      end
    )
  end

  delete "/messages/:message_id" do
    with_admin_or_user(
      conn,
      fn conn ->
        store_response(
          conn,
          Store.delete_message("system", message_id, origin_opts(conn, admin?: true))
        )
      end,
      fn conn ->
        with_user(conn, fn conn, user, _token ->
          store_response(conn, Store.delete_message(user["uid"], message_id, origin_opts(conn)))
        end)
      end
    )
  end

  post "/messages/:message_id/interactions" do
    with_user(conn, fn conn, user, _token ->
      case Store.get_message_for(user["uid"], message_id) do
        {:ok, message} ->
          {receiver_type, receiver_id} = receipt_target(user["uid"], message)
          read_message_id = conn.body_params["messageId"] || conn.body_params["id"] || message_id

          store_response(
            conn,
            Store.mark_read(user["uid"], receiver_type, receiver_id, read_message_id)
          )

        {:error, e} ->
          JSON.error(conn, e, error_status(e, 400))

        :error ->
          JSON.error(conn, Errors.message_not_found(message_id), 404)
      end
    end)
  end

  get "/user/messages/:muid" do
    with_user(conn, fn conn, user, _token ->
      case Store.find_message_by_muid_for(user["uid"], muid) do
        {:ok, message} -> JSON.ok(conn, message)
        {:error, e} -> JSON.error(conn, e, error_status(e, 400))
        :error -> JSON.error(conn, Errors.message_not_found(muid), 404)
      end
    end)
  end

  get "/conversations" do
    with_user(conn, fn conn, user, _token ->
      {:ok, conversations} = Store.conversations(user["uid"], conn.query_params)

      JSON.raw(conn, %{
        "data" => conversations,
        "meta" => ApiResponse.pagination_meta(conversations, conn.query_params)
      })
    end)
  end

  get "/users/:uid/conversation" do
    with_user(conn, fn conn, user, _token ->
      case Store.conversation(user["uid"], "user", uid) do
        {:ok, conversation} -> JSON.ok(conn, conversation || %{})
        {:error, e} -> JSON.error(conn, e, error_status(e, 400))
      end
    end)
  end

  get "/groups/:guid/conversation" do
    with_user(conn, fn conn, user, _token ->
      case Store.conversation(user["uid"], "group", guid) do
        {:ok, conversation} -> JSON.ok(conn, conversation || %{})
        {:error, e} -> JSON.error(conn, e, error_status(e, 400))
      end
    end)
  end

  post "/users/:uid/conversation/read" do
    mark_conversation_read(conn, "user", uid)
  end

  post "/groups/:guid/conversation/read" do
    mark_conversation_read(conn, "group", guid)
  end

  delete "/users/:uid/conversation/read" do
    mark_conversation_unread(conn, "user", uid)
  end

  delete "/groups/:guid/conversation/read" do
    mark_conversation_unread(conn, "group", guid)
  end

  post "/users/:uid/conversation/delivered" do
    mark_conversation_delivered(conn, "user", uid)
  end

  post "/groups/:guid/conversation/delivered" do
    mark_conversation_delivered(conn, "group", guid)
  end

  delete "/users/:uid/conversation" do
    with_user(conn, fn conn, user, _token ->
      case Store.hide_conversation(user["uid"], "user", uid) do
        {:ok, data} -> JSON.ok(conn, Map.put(data, "uid", uid))
        {:error, e} -> JSON.error(conn, e, error_status(e, 400))
      end
    end)
  end

  delete "/groups/:guid/conversation" do
    with_user(conn, fn conn, user, _token ->
      case Store.hide_conversation(user["uid"], "group", guid) do
        {:ok, data} -> JSON.ok(conn, Map.put(data, "guid", guid))
        {:error, e} -> JSON.error(conn, e, error_status(e, 400))
      end
    end)
  end

  delete "/conversations/:conversation_id" do
    with_admin_or_open(conn, fn conn ->
      {:ok, data} = Store.delete_conversation(conversation_id)
      JSON.ok(conn, data)
    end)
  end

  match "/extensions/:name/*path" do
    handle_extension(conn, name, Enum.join(path, "/"))
  end

  match "/v1/*path" do
    handle_extension(conn, "reactions", "v1/" <> Enum.join(path, "/"))
  end

  get "/media/:file" do
    serve_media(conn, file)
  end

  head "/media/:file" do
    serve_media(conn, file)
  end

  match "/*path" do
    if extension_host?(conn) do
      handle_extension(conn, extension_name_from_host(conn), Enum.join(path, "/"))
    else
      JSON.error(
        conn,
        Errors.error(
          "ERR_ROUTE_NOT_FOUND",
          "No OpenChat route matched #{conn.method} #{conn.request_path}"
        ),
        404
      )
    end
  end

  defp mark_conversation_read(conn, receiver_type, receiver_id) do
    mark_conversation_receipt(conn, receiver_type, receiver_id, &Store.mark_read/4)
  end

  defp mark_conversation_unread(conn, receiver_type, receiver_id) do
    mark_conversation_receipt(conn, receiver_type, receiver_id, &Store.mark_unread/4)
  end

  defp mark_conversation_delivered(conn, receiver_type, receiver_id) do
    mark_conversation_receipt(conn, receiver_type, receiver_id, &Store.mark_delivered/4)
  end

  defp mark_conversation_receipt(conn, receiver_type, receiver_id, marker) do
    with_user(conn, fn conn, user, _token ->
      message_id =
        conn.body_params["messageId"] || conn.body_params["id"] || conn.params["messageId"] || "0"

      store_response(conn, marker.(user["uid"], receiver_type, receiver_id, message_id), 200, 404)
    end)
  end

  defp group_members_response(conn, guid) do
    store_response(conn, Store.group_members(guid, conn.query_params), 200, 404)
  end

  defp api_key_header(conn), do: conn |> get_req_header("apikey") |> List.first()

  defp legacy_direct_messages_query?(params) do
    (params["receiverType"] == "user" or params["receiver_type"] == "user") and
      not blank?(params["sender"] || params["receiver"] || params["uid"])
  end

  defp legacy_group_messages_query?(params) do
    (params["receiverType"] == "group" or params["receiver_type"] == "group") and
      not blank?(params["receiver"] || params["guid"] || params["group"])
  end

  defp receipt_target(_uid, %{"receiverType" => "group"} = message),
    do: {"group", message["receiver"]}

  defp receipt_target(uid, message) do
    peer_uid =
      if to_s(message["sender"]) == to_s(uid),
        do: message["receiver"],
        else: message["sender"]

    {"user", peer_uid}
  end

  defp set_group_scopes_response(conn, guid) do
    store_response(conn, Store.set_group_scopes(guid, conn.body_params || %{}))
  end

  defp join_group_response(conn, guid) do
    with_user(conn, fn conn, user, _token ->
      params = Map.merge(conn.body_params || %{}, conn.params || %{})

      case Store.join_group(guid, user["uid"], params) do
        {:ok, group} -> JSON.ok(conn, join_group_payload(group))
        {:error, e} -> JSON.error(conn, e, 400)
      end
    end)
  end

  defp sdk_join_request?(conn) do
    not blank?(Auth.token(conn)) and
      not Enum.any?(["participants", "members", "moderators", "admins", "uids"], fn key ->
        Map.has_key?(conn.body_params || %{}, key)
      end)
  end

  defp send_message_response(conn, sender_uid, params, status \\ 200, opts \\ []) do
    result =
      Store.send_message(
        sender_uid,
        params,
        uploads_from_params(conn.params),
        origin_opts(conn, opts)
      )

    store_response(conn, result, status)
  end

  defp wait_for_dm_history_connect_grace do
    case Config.dm_history_connect_grace_ms() do
      ms when is_integer(ms) and ms > 0 ->
        # CometChat JS marks messages read over WebSocket immediately after
        # fetchPrevious(); this keeps OpenChat from outrunning the SDK's
        # connection-status transition on fast history responses.
        Process.sleep(ms)

      _other ->
        :ok
    end
  end

  defp origin_opts(conn, opts \\ []) do
    case request_resource(conn) do
      "" -> opts
      resource -> Keyword.put(opts, :resource, resource)
    end
  end

  defp request_resource(conn) do
    conn
    |> get_req_header("resource")
    |> List.first()
    |> to_s()
  end

  defp reaction_response(conn, :add, uid, message_id, reaction) do
    store_response(conn, Store.add_reaction(uid, message_id, reaction, origin_opts(conn)))
  end

  defp reaction_response(conn, :remove, uid, message_id, reaction) do
    store_response(conn, Store.remove_reaction(uid, message_id, reaction, origin_opts(conn)))
  end

  defp reaction_response(conn, :toggle, uid, message_id, reaction) do
    store_response(conn, Store.toggle_reaction(uid, message_id, reaction, origin_opts(conn)))
  end

  defp store_response(conn, result, success_status \\ 200, error_status \\ 400) do
    ApiResponse.store(conn, result, success_status, error_status)
  end

  defp error_status(error, default), do: ApiResponse.error_status(error, default)

  defp handle_extension(conn, _name, _path) do
    with_user(conn, fn conn, user, _token ->
      params = Map.merge(conn.query_params || %{}, conn.body_params || %{})
      message_id = params["messageId"] || params["msgId"] || params["id"] || params["message_id"]
      reaction = params["reaction"] || params["emoji"] || params["emojiCode"]

      action =
        case params["action"] || params["operation"] do
          value when is_binary(value) -> String.downcase(value)
          _other -> nil
        end

      method = String.downcase(conn.method)

      cond do
        blank?(message_id) ->
          JSON.error(conn, Errors.missing("messageId"), 400)

        blank?(reaction) ->
          JSON.error(conn, Errors.missing("reaction"), 400)

        action in ["delete", "remove", "removed", "unreact"] ->
          reaction_response(conn, :remove, user["uid"], message_id, reaction)

        action in ["add", "added", "react"] ->
          reaction_response(conn, :add, user["uid"], message_id, reaction)

        method == "delete" ->
          reaction_response(conn, :remove, user["uid"], message_id, reaction)

        true ->
          reaction_response(conn, :toggle, user["uid"], message_id, reaction)
      end
    end)
  end

  defp serve_media(conn, file) do
    decoded = URI.decode(file)
    filename = Path.basename(decoded)

    cond do
      decoded != filename or not Media.stored_name?(filename) ->
        media_not_found(conn)

      Config.media_storage() == "s3" ->
        media_not_found(conn)

      true ->
        case Media.fetch(filename) do
          {:ok, %{path: path, content_type: content_type}} ->
            conn
            |> put_resp_content_type(
              content_type || MIME.from_path(path) || "application/octet-stream"
            )
            |> send_file(200, path)

          {:ok, %{body: body, content_type: content_type}} ->
            conn
            |> put_resp_content_type(content_type || "application/octet-stream")
            |> send_resp(200, body)

          _other ->
            media_not_found(conn)
        end
    end
  end

  defp media_not_found(conn) do
    JSON.error(conn, Errors.error("ERR_MEDIA_NOT_FOUND", "Media file was not found."), 404)
  end

  defp with_user(conn, fun) do
    Auth.with_user(conn, fun)
  end

  defp with_admin_or_open(conn, fun) do
    Auth.with_admin(conn, fun)
  end

  defp with_admin_or_user(conn, admin_fun, user_fun) do
    Auth.with_admin_or_user(conn, admin_fun, user_fun)
  end

  defp uploads_from_params(params) do
    [
      params["files"],
      params["files[]"],
      params["file"],
      params["attachment"],
      params["attatchment"]
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp extension_host?(conn) do
    host = conn.host || ""
    String.starts_with?(host, "reactions-") or String.contains?(host, ".extensions.")
  end

  defp extension_name_from_host(conn) do
    conn.host |> to_string() |> String.split("-") |> List.first() || "reactions"
  end

  defp messages_response(conn, messages, params) do
    ApiResponse.messages(conn, messages, params)
  end

  defp reactions_response(conn, result, params) do
    ApiResponse.reactions(conn, result, params)
  end

  defp join_group_payload(group) do
    Map.put(group, "data", %{
      "entities" => %{
        "for" => %{"entityType" => "group", "entity" => group}
      }
    })
  end

  defp blank?(v), do: v in [nil, "", false]
  defp truthy?(v), do: v in [true, 1, "1", "true", "TRUE", "yes"]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
