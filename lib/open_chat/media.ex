defmodule OpenChat.Media do
  @moduledoc false

  alias OpenChat.{Config, Errors}

  def persist_upload(%Plug.Upload{} = upload) do
    filename = safe_filename(upload.filename)
    mime = media_type(upload.content_type, filename)

    with {:ok, stat} <- File.stat(upload.path),
         :ok <- validate_size(stat.size),
         :ok <- validate_mime(mime),
         {:ok, stored_name} <- store(upload.path, filename, mime) do
      {:ok,
       %{
         "extension" => stored_name |> Path.extname() |> String.trim_leading("."),
         "mimeType" => mime,
         "name" => filename,
         "size" => stat.size,
         "url" => media_url(stored_name)
       }}
    else
      {:error, %{"code" => _} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Errors.error("ERR_UPLOAD_FAILED", "Upload could not be stored.", %{
           "reason" => inspect(reason)
         })}
    end
  end

  def persist_upload(%{"path" => path, "filename" => filename} = upload) do
    persist_upload(%Plug.Upload{
      path: path,
      filename: filename,
      content_type: upload["content_type"] || upload["contentType"]
    })
  end

  def persist_upload(_other) do
    {:error, Errors.invalid("file", "Expected a multipart file upload.")}
  end

  def media_url(filename) do
    base = Application.get_env(:open_chat, :public_media_base_url)

    if blank?(base),
      do: "/media/#{URI.encode(filename)}",
      else: String.trim_trailing(base, "/") <> "/media/#{URI.encode(filename)}"
  end

  def sign_urls(value) when is_list(value), do: Enum.map(value, &sign_urls/1)

  def sign_urls(%{} = value) do
    value
    |> sign_media_map()
    |> Map.new(fn {key, nested} -> {key, sign_urls(nested)} end)
  end

  def sign_urls(value), do: value

  def stored_name?(filename) when is_binary(filename) do
    Regex.match?(~r/^[A-Za-z0-9_-]{8,}-[A-Za-z0-9._-]+$/, filename)
  end

  def stored_name?(_filename), do: false

  def fetch(stored_name) when is_binary(stored_name) do
    with :ok <- validate_stored_name(stored_name) do
      case media_storage() do
        "s3" -> fetch_s3(stored_name)
        _local -> fetch_local(stored_name)
      end
    end
  end

  def fetch(_stored_name), do: {:error, :not_found}

  defp sign_media_map(map) do
    if media_storage() == "s3" do
      map
      |> sign_attachment_urls()
      |> sign_own_url()
    else
      map
    end
  end

  defp sign_attachment_urls(%{"attachments" => attachments} = map) when is_list(attachments) do
    Map.put(map, "attachments", Enum.map(attachments, &sign_attachment_url/1))
  end

  defp sign_attachment_urls(map), do: map

  defp sign_attachment_url(%{} = attachment), do: sign_own_url(attachment)
  defp sign_attachment_url(attachment), do: attachment

  defp sign_own_url(%{"url" => url} = map) when is_binary(url) do
    case stored_name_from_url(url) do
      nil -> map
      stored_name -> Map.put(map, "url", signed_media_url(stored_name))
    end
  end

  defp sign_own_url(map), do: map

  defp signed_media_url(stored_name) do
    client = Config.s3_client()
    bucket = Config.s3_bucket()

    cond do
      blank?(bucket) ->
        media_url(stored_name)

      not function_exported?(client, :presigned_get_url, 3) ->
        media_url(stored_name)

      true ->
        case client.presigned_get_url(bucket, stored_name, Config.s3_presigned_url_ttl_seconds()) do
          {:ok, url} -> url
          _other -> media_url(stored_name)
        end
    end
  end

  defp stored_name_from_url(url) do
    uri = URI.parse(url)
    query = uri.query || ""

    cond do
      String.contains?(query, "X-Amz-Signature=") ->
        nil

      is_binary(uri.path) ->
        stored_name_from_path(uri.path, uri.host)

      true ->
        nil
    end
  rescue
    _error -> nil
  end

  defp stored_name_from_path(path, host) do
    segments = String.split(path, "/", trim: true)

    candidate =
      cond do
        Enum.at(segments, -2) == "media" -> List.last(segments)
        s3_host?(host) -> List.last(segments)
        true -> nil
      end

    candidate = if is_binary(candidate), do: URI.decode(candidate), else: nil
    if stored_name?(candidate), do: candidate
  end

  defp s3_host?(host) when is_binary(host), do: String.contains?(host, ".s3.")
  defp s3_host?(_host), do: false

  defp validate_size(size) do
    max = Config.upload_max_bytes()

    if size <= max do
      :ok
    else
      {:error,
       Errors.error("ERR_UPLOAD_TOO_LARGE", "Upload exceeds the configured size limit.", %{
         "maxBytes" => max,
         "size" => size
       })}
    end
  end

  defp validate_mime(mime) do
    allowed = Config.upload_allowed_mime_types()

    if mime in allowed do
      :ok
    else
      {:error,
       Errors.error("ERR_UPLOAD_TYPE_NOT_ALLOWED", "Upload media type is not allowed.", %{
         "mimeType" => mime,
         "allowedMimeTypes" => allowed
       })}
    end
  end

  defp store(path, filename, mime) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)
    stored_name = id <> "-" <> filename

    case media_storage() do
      "s3" -> store_s3(path, stored_name, mime)
      _local -> store_local(path, stored_name)
    end
  end

  defp store_local(path, stored_name) do
    dest = Path.join(Config.upload_dir(), stored_name)

    with :ok <- File.mkdir_p(Config.upload_dir()),
         :ok <- File.cp(path, dest) do
      {:ok, stored_name}
    end
  end

  defp store_s3(path, stored_name, mime) do
    bucket = Config.s3_bucket()

    if blank?(bucket) do
      {:error, Errors.error("ERR_UPLOAD_FAILED", "S3 bucket is not configured.")}
    else
      case Config.s3_client().put_object(bucket, stored_name, path, mime) do
        {:ok, _result} -> {:ok, stored_name}
        {:error, %{"code" => _} = error} -> {:error, error}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_local(stored_name) do
    path = Path.join(Config.upload_dir(), stored_name)

    if File.exists?(path) do
      {:ok, %{path: path, content_type: MIME.from_path(path) || "application/octet-stream"}}
    else
      {:error, :not_found}
    end
  end

  defp fetch_s3(stored_name) do
    bucket = Config.s3_bucket()

    cond do
      blank?(bucket) ->
        {:error, :not_found}

      true ->
        case Config.s3_client().get_object(bucket, stored_name) do
          {:ok, %{body: body, content_type: content_type}} ->
            {:ok, %{body: body, content_type: content_type || media_type(nil, stored_name)}}

          {:error, :not_found} ->
            {:error, :not_found}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp validate_stored_name(stored_name) do
    if stored_name?(stored_name), do: :ok, else: {:error, :not_found}
  end

  defp media_storage do
    Config.media_storage()
    |> String.trim()
    |> String.downcase()
  end

  defp media_type(content_type, filename) do
    content_type
    |> to_s()
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> MIME.from_path(filename) || "application/octet-stream"
      type -> type
    end
  end

  defp safe_filename(filename) do
    filename
    |> to_s()
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.trim(".")
    |> case do
      "" -> "upload"
      name -> name
    end
  end

  defp blank?(value), do: value in [nil, "", false]
  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
