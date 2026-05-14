defmodule OpenChat.S3Client do
  @moduledoc false

  alias OpenChat.Config

  @metadata_host "169.254.170.2"
  @service "s3"

  def put_object(bucket, key, path, content_type) do
    with {:ok, body} <- File.read(path),
         {:ok, response} <- request("PUT", bucket, key, body, content_type) do
      case response do
        %{status: status} when status in 200..299 ->
          {:ok, response}

        %{status: status, body: body} ->
          {:error, {:s3_status, status, body}}
      end
    end
  end

  def get_object(bucket, key) do
    with {:ok, response} <- request("GET", bucket, key, "", nil) do
      case response do
        %{status: status, body: body, headers: headers} when status in 200..299 ->
          {:ok, %{body: body, content_type: header(headers, "content-type")}}

        %{status: 404} ->
          {:error, :not_found}

        %{status: status, body: body} ->
          {:error, {:s3_status, status, body}}
      end
    end
  end

  def presigned_get_url(bucket, key, expires_in \\ Config.s3_presigned_url_ttl_seconds()) do
    with {:ok, credentials} <- credentials() do
      region = Config.s3_region()
      host = "#{bucket}.s3.#{region}.amazonaws.com"
      now = DateTime.utc_now()
      date = Calendar.strftime(now, "%Y%m%d")
      amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      scope = "#{date}/#{region}/#{@service}/aws4_request"
      expires_in = normalize_expires_in(expires_in)

      query_params =
        [
          {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
          {"X-Amz-Credential", "#{credentials.access_key_id}/#{scope}"},
          {"X-Amz-Date", amz_date},
          {"X-Amz-Expires", to_string(expires_in)},
          {"X-Amz-SignedHeaders", "host"}
        ]
        |> maybe_add_security_token_query(credentials)

      canonical_query = canonical_query(query_params)

      canonical_request =
        [
          "GET",
          "/" <> canonical_key(key),
          canonical_query,
          "host:#{host}\n",
          "host",
          "UNSIGNED-PAYLOAD"
        ]
        |> Enum.join("\n")

      string_to_sign =
        [
          "AWS4-HMAC-SHA256",
          amz_date,
          scope,
          sha256_hex(canonical_request)
        ]
        |> Enum.join("\n")

      signature =
        credentials.secret_access_key
        |> signing_key(date, region)
        |> hmac(string_to_sign)
        |> Base.encode16(case: :lower)

      signed_query = canonical_query(query_params ++ [{"X-Amz-Signature", signature}])

      {:ok, "https://#{host}/#{canonical_key(key)}?#{signed_query}"}
    end
  end

  defp request(method, bucket, key, body, content_type) do
    with {:ok, credentials} <- credentials() do
      region = Config.s3_region()
      host = "#{bucket}.s3.#{region}.amazonaws.com"
      payload_hash = sha256_hex(body)
      now = DateTime.utc_now()
      date = Calendar.strftime(now, "%Y%m%d")
      amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

      headers =
        [
          {"host", host},
          {"x-amz-content-sha256", payload_hash},
          {"x-amz-date", amz_date}
        ]
        |> maybe_add_security_token(credentials)

      authorization =
        authorization_header(
          method,
          key,
          headers,
          payload_hash,
          credentials,
          date,
          amz_date,
          region
        )

      request_headers =
        headers
        |> Kernel.++([{"authorization", authorization}])
        |> Enum.map(fn {name, value} -> {to_charlist(name), to_charlist(value)} end)

      url = ~c"https://#{host}/#{canonical_key(key)}"
      http_options = [timeout: 15_000, connect_timeout: 5_000]
      options = [body_format: :binary]

      response =
        case method do
          "PUT" ->
            :httpc.request(
              :put,
              {url, request_headers, to_charlist(content_type || "application/octet-stream"),
               body},
              http_options,
              options
            )

          "GET" ->
            :httpc.request(:get, {url, request_headers}, http_options, options)
        end

      case response do
        {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
          {:ok,
           %{
             status: status,
             headers: normalize_headers(response_headers),
             body: response_body
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp authorization_header(
         method,
         key,
         headers,
         payload_hash,
         credentials,
         date,
         amz_date,
         region
       ) do
    canonical_uri = "/" <> canonical_key(key)
    {canonical_headers, signed_headers} = canonical_headers(headers)

    canonical_request =
      [
        method,
        canonical_uri,
        "",
        canonical_headers,
        signed_headers,
        payload_hash
      ]
      |> Enum.join("\n")

    scope = "#{date}/#{region}/#{@service}/aws4_request"

    string_to_sign =
      [
        "AWS4-HMAC-SHA256",
        amz_date,
        scope,
        sha256_hex(canonical_request)
      ]
      |> Enum.join("\n")

    signature =
      credentials.secret_access_key
      |> signing_key(date, region)
      |> hmac(string_to_sign)
      |> Base.encode16(case: :lower)

    "AWS4-HMAC-SHA256 Credential=#{credentials.access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
  end

  defp canonical_headers(headers) do
    signed =
      headers
      |> Enum.map(fn {name, value} ->
        {name |> to_string() |> String.downcase(), canonical_header_value(value)}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    canonical =
      signed
      |> Enum.map_join("", fn {name, value} -> "#{name}:#{value}\n" end)

    names =
      signed
      |> Enum.map_join(";", &elem(&1, 0))

    {canonical, names}
  end

  defp canonical_key(key), do: URI.encode(key, &URI.char_unreserved?/1)

  defp canonical_query(params) do
    params
    |> Enum.map(fn {name, value} -> {aws_uri_encode(name), aws_uri_encode(value)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)
  end

  defp aws_uri_encode(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp canonical_header_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp signing_key(secret_access_key, date, region) do
    ("AWS4" <> secret_access_key)
    |> hmac(date)
    |> hmac(region)
    |> hmac(@service)
    |> hmac("aws4_request")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  defp maybe_add_security_token(headers, %{session_token: token}) when token not in [nil, ""] do
    headers ++ [{"x-amz-security-token", token}]
  end

  defp maybe_add_security_token(headers, _credentials), do: headers

  defp maybe_add_security_token_query(params, %{session_token: token})
       when token not in [nil, ""] do
    params ++ [{"X-Amz-Security-Token", token}]
  end

  defp maybe_add_security_token_query(params, _credentials), do: params

  defp normalize_expires_in(value) do
    case Integer.parse(to_string(value)) do
      {int, _rest} when int > 0 -> min(int, 604_800)
      _other -> 3600
    end
  end

  defp credentials do
    case cached_credentials() do
      nil ->
        fetch_credentials()

      credentials ->
        {:ok, credentials}
    end
  end

  defp cached_credentials do
    case :persistent_term.get({__MODULE__, :credentials}, nil) do
      %{expires_at: :never} = credentials ->
        credentials

      %{expires_at: expires_at} = credentials ->
        if expires_at - System.system_time(:second) > 60, do: credentials

      _other ->
        nil
    end
  end

  defp fetch_credentials do
    case env_credentials() || ecs_credentials() do
      {:ok, credentials} ->
        :persistent_term.put({__MODULE__, :credentials}, credentials)
        {:ok, credentials}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp env_credentials do
    access_key_id = System.get_env("AWS_ACCESS_KEY_ID")
    secret_access_key = System.get_env("AWS_SECRET_ACCESS_KEY")

    if blank?(access_key_id) or blank?(secret_access_key) do
      nil
    else
      {:ok,
       %{
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         session_token: System.get_env("AWS_SESSION_TOKEN"),
         expires_at: :never
       }}
    end
  end

  defp ecs_credentials do
    with {:ok, uri} <- ecs_credentials_uri(),
         {:ok, body} <- metadata_get(uri),
         {:ok, decoded} <- Jason.decode(body),
         access_key_id when is_binary(access_key_id) <- decoded["AccessKeyId"],
         secret_access_key when is_binary(secret_access_key) <- decoded["SecretAccessKey"] do
      {:ok,
       %{
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         session_token: decoded["Token"],
         expires_at: expires_at(decoded["Expiration"])
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :aws_credentials_unavailable}
    end
  end

  defp ecs_credentials_uri do
    cond do
      not blank?(System.get_env("AWS_CONTAINER_CREDENTIALS_FULL_URI")) ->
        {:ok, System.fetch_env!("AWS_CONTAINER_CREDENTIALS_FULL_URI")}

      not blank?(System.get_env("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")) ->
        {:ok,
         "http://#{@metadata_host}#{System.fetch_env!("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")}"}

      true ->
        {:error, :aws_credentials_unavailable}
    end
  end

  defp metadata_get(uri) do
    headers =
      case System.get_env("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE") do
        value when value in [nil, ""] ->
          case System.get_env("AWS_CONTAINER_AUTHORIZATION_TOKEN") do
            token when token not in [nil, ""] -> [{~c"authorization", to_charlist(token)}]
            _other -> []
          end

        path ->
          case File.read(path) do
            {:ok, token} -> [{~c"authorization", token |> String.trim() |> to_charlist()}]
            _other -> []
          end
      end

    case :httpc.request(:get, {to_charlist(uri), headers}, [timeout: 5_000], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:error, {:metadata_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expires_at(nil), do: System.system_time(:second) + 300

  defp expires_at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _other -> System.system_time(:second) + 300
    end
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp header(headers, name), do: Map.get(headers, String.downcase(name))

  defp blank?(value), do: value in [nil, ""]
end
