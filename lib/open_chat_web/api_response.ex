defmodule OpenChatWeb.ApiResponse do
  @moduledoc false

  alias OpenChat.Media
  alias OpenChat.Store.MessageData
  alias OpenChatWeb.JSON

  def store(conn, result, success_status \\ 200, error_status \\ 400) do
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

  def messages(conn, messages, params) do
    messages =
      messages
      |> message_wire_order(params)
      |> Enum.map(&MessageData.ensure_media_wire_shape/1)
      |> Media.sign_urls()

    JSON.raw(conn, %{"data" => messages, "meta" => cursor_meta(messages, params)})
  end

  def reactions(conn, result, params) do
    case result do
      {:ok, reactions} ->
        {page, meta} = reactions_page_with_meta(reactions, params)
        JSON.raw(conn, %{"data" => page, "meta" => meta})

      {:error, error} ->
        JSON.error(conn, error, error_status(error, 404))
    end
  end

  def error_status(%{"code" => "ERR_FORBIDDEN"}, _default), do: 403
  def error_status(_error, default), do: default

  def pagination_meta(rows, params) do
    limit = to_int(params["per_page"] || params["limit"] || 30, 30)
    count = length(rows)
    current_page = to_int(params["page"], 1)

    {total, total_pages} =
      cond do
        count == 0 ->
          {0, max(current_page, 1)}

        count >= limit ->
          {current_page * limit + 1, current_page + 1}

        true ->
          {max(current_page - 1, 0) * limit + count, current_page}
      end

    %{
      "pagination" => %{
        "total" => total,
        "count" => count,
        "per_page" => limit,
        "current_page" => current_page,
        "total_pages" => total_pages
      }
    }
  end

  defp cursor_meta(messages, params) do
    limit = params["per_page"] || params["limit"] || 30
    affix = message_cursor_affix(params)

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
    case message_cursor_affix(params) do
      "append" -> messages
      _fetch_previous -> Enum.reverse(messages)
    end
  end

  defp message_cursor_affix(params) do
    params = params || %{}

    after_id = params["afterId"] || params["after_id"] || params["fromId"] || params["from_id"]

    append_timestamp =
      params["fromTimestamp"] || params["fromTimeStamp"] || params["from_timestamp"]

    params["cursorAffix"] || params["affix"] ||
      cond do
        after_id -> "append"
        append_timestamp -> "append"
        true -> "prepend"
      end
  end

  defp reactions_page_with_meta(reactions, params) do
    params = params || %{}
    limit = reaction_limit(params)
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

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp to_int(_value, default), do: default
end
