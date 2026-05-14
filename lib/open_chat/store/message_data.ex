defmodule OpenChat.Store.MessageData do
  @moduledoc false

  alias OpenChat.Media

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
