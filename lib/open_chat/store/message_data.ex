defmodule OpenChat.Store.MessageData do
  @moduledoc false

  alias OpenChat.Media

  @media_types ~w(image video audio file media)

  def infer_type(params, uploads) do
    data = normalise_data(params["data"] || %{})

    cond do
      params["category"] == "custom" -> params["type"] || "custom"
      Map.has_key?(data, "customData") -> "custom"
      uploads != [] -> params["type"] || "file"
      Map.has_key?(data, "url") -> params["type"] || "file"
      true -> "text"
    end
  end

  def normalise(params, uploads) do
    base = normalise_data(params["data"] || %{})
    media_message? = media_message?(params, uploads, base)

    base =
      cond do
        Map.has_key?(params, "text") and not Map.has_key?(base, "text") ->
          Map.put(base, "text", params["text"])

        Map.has_key?(params, "caption") and not Map.has_key?(base, "text") ->
          Map.put(base, "text", params["caption"])

        true ->
          base
      end

    base =
      if media_message? do
        Map.put_new(base, "caption", Map.get(base, "text", ""))
      else
        base
      end

    base =
      if Map.has_key?(params, "metadata") and not Map.has_key?(base, "metadata") do
        Map.put(base, "metadata", normalise_data(params["metadata"]))
      else
        base
      end

    base =
      if Map.has_key?(params, "customData") and not Map.has_key?(base, "customData") do
        Map.put(base, "customData", normalise_data(params["customData"]))
      else
        base
      end

    case upload_attachments(uploads) do
      {:ok, []} ->
        {:ok, base}

      {:ok, attachments} ->
        {:ok,
         base
         |> Map.put("attachments", attachments)}

      {:error, error} ->
        {:error, error}
    end
  end

  def merge(old, new) do
    new = normalise_data(new)

    cond do
      is_map(new) and Map.has_key?(new, "data") ->
        Map.merge(old || %{}, normalise_data(new["data"]))

      is_map(new) ->
        Map.merge(old || %{}, new)

      true ->
        old || %{}
    end
  end

  def put_entity(data, key, entity_type, entity) do
    Map.update(
      data,
      "entities",
      %{key => %{"entityType" => entity_type, "entity" => entity}},
      fn entities ->
        Map.put(entities || %{}, key, %{"entityType" => entity_type, "entity" => entity})
      end
    )
  end

  def ensure_media_wire_shape(%{"type" => type, "data" => data} = message)
      when is_map(data) and type in @media_types do
    cond do
      valid_attachments?(data["attachments"]) ->
        message

      url = attachment_url(data, message) ->
        put_in(message, ["data", "attachments"], [attachment_from(url, data, message)])

      true ->
        downgrade_broken_media(message)
    end
  end

  def ensure_media_wire_shape(message), do: message

  def ensure_media_wire_shapes(value) when is_list(value),
    do: Enum.map(value, &ensure_media_wire_shapes/1)

  def ensure_media_wire_shapes(%{} = value) do
    value
    |> ensure_media_wire_shape()
    |> Map.new(fn {key, nested} -> {key, ensure_media_wire_shapes(nested)} end)
  end

  def ensure_media_wire_shapes(value), do: value

  defp upload_attachments(uploads) do
    uploads
    |> List.wrap()
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while({:ok, []}, fn upload, {:ok, acc} ->
      case Media.persist_upload(upload) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, attachments} -> {:ok, Enum.reverse(attachments)}
      {:error, error} -> {:error, error}
    end
  end

  defp media_message?(params, uploads, base) do
    uploads = uploads |> List.wrap() |> List.flatten() |> Enum.reject(&is_nil/1)
    type = params["type"] |> to_s() |> String.downcase()

    uploads != [] or type in ["image", "video", "audio", "file", "media"] or
      Map.has_key?(base, "url") or Map.has_key?(base, "attachments")
  end

  defp valid_attachments?([%{"url" => url} | _]) when is_binary(url) and url != "", do: true
  defp valid_attachments?(_other), do: false

  defp attachment_url(data, message) do
    first_present([
      data["url"],
      get_in(data, ["metadata", "chatMessage", "media", "uri"]),
      get_in(data, ["metadata", "chatMessage", "media", "url"]),
      get_in(data, ["metadata", "chatMessage", "imageUrls", Access.at(0)]),
      get_in(message, ["metadata", "chatMessage", "media", "uri"]),
      get_in(message, ["metadata", "chatMessage", "media", "url"]),
      get_in(message, ["metadata", "chatMessage", "imageUrls", Access.at(0)])
    ])
  end

  defp attachment_from(url, data, message) do
    name =
      first_present([
        get_in(data, ["metadata", "chatMessage", "media", "name"]),
        get_in(message, ["metadata", "chatMessage", "media", "name"]),
        Path.basename(URI.parse(url).path || ""),
        "media"
      ])

    mime =
      first_present([
        get_in(data, ["metadata", "chatMessage", "media", "type"]),
        get_in(message, ["metadata", "chatMessage", "media", "type"]),
        MIME.from_path(name),
        "application/octet-stream"
      ])

    %{
      "extension" => name |> Path.extname() |> String.trim_leading("."),
      "mimeType" => mime,
      "name" => name,
      "url" => url
    }
  end

  defp downgrade_broken_media(%{"data" => data} = message) do
    text =
      first_present([
        data["text"],
        data["caption"],
        get_in(data, ["metadata", "chatMessage", "message"]),
        get_in(data, ["metadata", "chatMessage", "media", "name"]),
        get_in(message, ["metadata", "chatMessage", "message"]),
        get_in(message, ["metadata", "chatMessage", "media", "name"]),
        ""
      ])

    message
    |> Map.put("type", "text")
    |> put_in(["data", "text"], text)
    |> update_in(["data"], &Map.drop(&1 || %{}, ["attachments", "url"]))
  end

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) -> value != ""
      nil -> false
      false -> false
      _value -> true
    end)
  end

  defp normalise_data(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> stringify_keys(decoded)
      {:ok, decoded} -> decoded
      _other -> value
    end
  end

  defp normalise_data(value) when is_map(value), do: stringify_keys(value)
  defp normalise_data(nil), do: %{}
  defp normalise_data(other), do: other

  defp stringify_keys(%{__struct__: _} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_s(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
