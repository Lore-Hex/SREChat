defmodule OpenChatWeb.ApiRouter do
  @moduledoc false
  use Plug.Router
  import Plug.Conn
  alias OpenChat.{Config, Errors, Media, Store, Time}
  alias OpenChat.Store.AuthTokens
  alias OpenChat.Store.MessageData
  alias OpenChatWeb.{Auth, JSON}

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
    with_admin_or_user(
      conn,
      fn conn -> set_group_scopes_response(conn, guid) end,
      fn conn ->
        with_user(conn, fn conn, user, _token ->
          params = Map.merge(conn.body_params || %{}, conn.params || %{})

          case Store.join_group(guid, user["uid"], params) do
            {:ok, group} -> JSON.ok(conn, join_group_payload(group))
            {:error, e} -> JSON.error(conn, e, 400)
          end
        end)
      end
    )
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
    with_admin_or_open(conn, fn conn ->
      {:ok, data} = Store.leave_group(guid, uid)
      JSON.ok(conn, data)
    end)
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
        {:ok, messages} -> messages_response(conn, messages, conn.query_params)
        {:error, e} -> JSON.error(conn, e, 400)
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

      if truthy?(params["unread"]) and truthy?(params["count"]) do
        {:ok, rows} = Store.unread_counts(user["uid"], params)
        JSON.ok(conn, rows)
      else
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
          Store.edit_message("system", message_id, conn.body_params, admin?: true)
        )
      end,
      fn conn ->
        with_user(conn, fn conn, user, _token ->
          store_response(conn, Store.edit_message(user["uid"], message_id, conn.body_params))
        end)
      end
    )
  end

  delete "/messages/:message_id" do
    with_admin_or_user(
      conn,
      fn conn ->
        store_response(conn, Store.delete_message("system", message_id, admin?: true))
      end,
      fn conn ->
        with_user(conn, fn conn, user, _token ->
          store_response(conn, Store.delete_message(user["uid"], message_id))
        end)
      end
    )
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
        "meta" => pagination_meta(conversations, conn.query_params)
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

  defp set_group_scopes_response(conn, guid) do
    store_response(conn, Store.set_group_scopes(guid, conn.body_params || %{}))
  end

  defp send_message_response(conn, sender_uid, params, status \\ 200, opts \\ []) do
    result = Store.send_message(sender_uid, params, uploads_from_params(conn.params), opts)
    store_response(conn, result, status)
  end

  defp reaction_response(conn, :add, uid, message_id, reaction) do
    store_response(conn, Store.add_reaction(uid, message_id, reaction))
  end

  defp reaction_response(conn, :remove, uid, message_id, reaction) do
    store_response(conn, Store.remove_reaction(uid, message_id, reaction))
  end

  defp reaction_response(conn, :toggle, uid, message_id, reaction) do
    store_response(conn, Store.toggle_reaction(uid, message_id, reaction))
  end

  defp store_response(conn, result, success_status \\ 200, error_status \\ 400) do
    case result do
      {:ok, data} ->
        JSON.ok(
          conn,
          data |> MessageData.ensure_media_wire_shape() |> Media.sign_urls(),
          success_status
        )

      {:error, error} ->
        JSON.error(conn, error, error_status(error, error_status))
    end
  end

  defp error_status(%{"code" => "ERR_FORBIDDEN"}, _default), do: 403
  defp error_status(_error, default), do: default

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

    if decoded == filename and Media.stored_name?(filename) do
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
          JSON.error(conn, Errors.error("ERR_MEDIA_NOT_FOUND", "Media file was not found."), 404)
      end
    else
      JSON.error(conn, Errors.error("ERR_MEDIA_NOT_FOUND", "Media file was not found."), 404)
    end
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
    messages =
      messages
      |> message_wire_order(params)
      |> Enum.map(&MessageData.ensure_media_wire_shape/1)
      |> Media.sign_urls()

    JSON.raw(conn, %{"data" => messages, "meta" => cursor_meta(messages, params)})
  end

  defp reactions_response(conn, result, params) do
    case result do
      {:ok, reactions} ->
        {page, meta} = reactions_page_with_meta(reactions, params)
        JSON.raw(conn, %{"data" => page, "meta" => meta})

      {:error, error} ->
        JSON.error(conn, error, error_status(error, 404))
    end
  end

  defp join_group_payload(group) do
    Map.put(group, "data", %{
      "entities" => %{
        "for" => %{"entityType" => "group", "entity" => group}
      }
    })
  end

  defp cursor_meta(messages, params) do
    limit = params["per_page"] || params["limit"] || 30
    affix = params["cursorAffix"] || params["affix"] || "prepend"

    cursor_message =
      case affix do
        "append" -> List.last(messages) || %{}
        _other -> List.first(messages) || %{}
      end

    pagination_meta(messages, Map.put(params, "limit", limit))
    |> Map.put(
      "cursor",
      %{
        "id" => cursor_message["id"] || 0,
        "sentAt" => cursor_message["sentAt"] || 0,
        "affix" => affix
      }
    )
  end

  defp message_wire_order(messages, params) do
    case params["cursorAffix"] || params["affix"] || "prepend" do
      "append" -> messages
      _fetch_previous -> Enum.reverse(messages)
    end
  end

  defp reactions_page_with_meta(reactions, params) do
    params = params || %{}
    limit = params |> reaction_limit()
    affix = params["cursorAffix"] || params["affix"] || "prepend"
    cursor_field = params["cursorField"] || "id"
    cursor_value = params["cursorValue"] || params[cursor_field]
    cursor_id = params["cursorId"] || params["cursor_id"] || params["id"]

    page =
      reactions
      |> sort_reactions(cursor_field, affix)
      |> filter_reaction_cursor(cursor_field, cursor_value, cursor_id, affix)
      |> Enum.take(limit)

    meta =
      reactions_pagination_meta(reactions, page, limit, params)
      |> put_reaction_cursor(page, cursor_field, affix)

    {page, meta}
  end

  defp sort_reactions(reactions, field, "append") do
    Enum.sort_by(reactions, &reaction_sort_key(&1, field), :asc)
  end

  defp sort_reactions(reactions, field, _affix) do
    Enum.sort_by(reactions, &reaction_sort_key(&1, field), :desc)
  end

  defp reaction_sort_key(reaction, "reactedAt") do
    {to_int(reaction["reactedAt"], 0), to_int(reaction["id"], 0)}
  end

  defp reaction_sort_key(reaction, _field) do
    {to_int(reaction["id"], 0), to_int(reaction["reactedAt"], 0)}
  end

  defp filter_reaction_cursor(reactions, _field, nil, _cursor_id, _affix), do: reactions
  defp filter_reaction_cursor(reactions, _field, "", _cursor_id, _affix), do: reactions

  defp filter_reaction_cursor(reactions, "reactedAt", cursor_value, cursor_id, "append")
       when cursor_id != nil and cursor_id != "" do
    cursor_key = {to_int(cursor_value, 0), to_int(cursor_id, 0)}
    Enum.filter(reactions, &(reaction_sort_key(&1, "reactedAt") > cursor_key))
  end

  defp filter_reaction_cursor(reactions, "reactedAt", cursor_value, cursor_id, _affix)
       when cursor_id != nil and cursor_id != "" do
    cursor_key = {to_int(cursor_value, 0), to_int(cursor_id, 0)}
    Enum.filter(reactions, &(reaction_sort_key(&1, "reactedAt") < cursor_key))
  end

  defp filter_reaction_cursor(reactions, field, cursor_value, _cursor_id, "append") do
    cursor_value = to_int(cursor_value, 0)
    Enum.filter(reactions, &(reaction_cursor_value(&1, field) > cursor_value))
  end

  defp filter_reaction_cursor(reactions, field, cursor_value, _cursor_id, _affix) do
    cursor_value = to_int(cursor_value, 0)
    Enum.filter(reactions, &(reaction_cursor_value(&1, field) < cursor_value))
  end

  defp reaction_cursor_value(reaction, "reactedAt"), do: to_int(reaction["reactedAt"], 0)
  defp reaction_cursor_value(reaction, _field), do: to_int(reaction["id"], 0)

  defp reactions_pagination_meta(reactions, page, limit, params) do
    total = length(reactions)

    %{
      "pagination" => %{
        "total" => total,
        "count" => length(page),
        "per_page" => limit,
        "current_page" => to_int(params["page"], 1),
        "total_pages" => if(total == 0, do: 0, else: ceil(total / limit))
      }
    }
  end

  defp put_reaction_cursor(meta, [], _field, _affix), do: meta

  defp put_reaction_cursor(meta, page, field, affix) do
    cursor_reaction = List.last(page)

    cursor = %{
      "cursorField" => field,
      "cursorValue" => reaction_cursor_value(cursor_reaction, field),
      "cursorId" => to_int(cursor_reaction["id"], 0),
      "cursorAffix" => affix,
      "affix" => affix
    }

    Map.put(meta, if(affix == "append", do: "next", else: "previous"), cursor)
  end

  defp reaction_limit(params) do
    params["per_page"]
    |> Kernel.||(params["limit"])
    |> Kernel.||(10)
    |> to_int(10)
    |> max(1)
    |> min(20)
  end

  defp pagination_meta(rows, params) do
    limit = params["per_page"] || params["limit"] || 30

    %{
      "pagination" => %{
        "total" => length(rows),
        "count" => length(rows),
        "per_page" => to_int(limit, 30),
        "current_page" => to_int(params["page"], 1),
        "total_pages" => 1
      }
    }
  end

  defp blank?(v), do: v in [nil, "", false]
  defp truthy?(v), do: v in [true, 1, "1", "true", "TRUE", "yes"]

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp to_int(_value, default), do: default
end
