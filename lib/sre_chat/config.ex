defmodule SREChat.Config do
  @moduledoc "Runtime configuration helpers."

  @default_request_body_limit 10_000_000
  @default_upload_max_bytes 10_000_000
  @default_group_max_members 1_000
  @default_group_max_messages 1_000
  @default_group_message_retention_days 30
  @default_group_unread_fanout_limit 1_000
  @default_group_presence_ttl_seconds 1_800
  @default_group_max_presence 5_000
  @default_redis_conversation_refresh_limit 150
  @default_redis_publisher_lanes 4
  @default_dm_history_connect_grace_ms 0
  @default_websocket_heartbeat_ms 25_000
  @default_upload_allowed_mime_types ~w(
    image/jpeg
    image/png
    image/gif
    image/webp
    video/mp4
    video/webm
    audio/mpeg
    audio/mp4
    audio/ogg
    audio/webm
    application/pdf
    text/plain
  )

  def app_id, do: Application.fetch_env!(:sre_chat, :app_id)
  def api_key, do: Application.fetch_env!(:sre_chat, :api_key)

  @doc """
  How message/action/reaction ids are allocated.

  `:global` — the legacy shared Redis counter; single-master, kept as the
  default for SREChat parity. `:region` — coordination-free
  `SREChat.RegionId` allocation; required for multi-master.
  """
  def id_allocator do
    case Application.get_env(:sre_chat, :id_allocator, "global") do
      value when value in [:region, "region"] -> :region
      _other -> :global
    end
  end

  @doc "Cross-region replication: :off (default) or :multi_master."
  def replication_mode do
    case Application.get_env(:sre_chat, :replication_mode, "off") do
      value when value in [:multi_master, "multi_master"] -> :multi_master
      _other -> :off
    end
  end

  @doc """
  Peer regions to replicate from: `[%{index: 1, url: "rediss://..."}]`.

  Parsed from `PEER_REGIONS="1=rediss://host:port/db,2=rediss://..."`. The
  URL is the PEER region's Redis (its oplog lives there); reachability of
  that Redis defines the partition boundary. Cross-cloud links must be
  TLS (`rediss://`) or ride a private tunnel.
  """
  def peer_regions do
    :sre_chat
    |> Application.get_env(:peer_regions, "")
    |> to_s()
    |> String.split(",", trim: true)
    |> Enum.map(fn pair ->
      case String.split(String.trim(pair), "=", parts: 2) do
        [index, url] when url != "" ->
          case Integer.parse(String.trim(index)) do
            {int, ""} when int in 0..7 -> %{index: int, url: String.trim(url)}
            _other -> raise ArgumentError, "PEER_REGIONS entry has a bad index: #{inspect(pair)}"
          end

        _other ->
          raise ArgumentError,
                "PEER_REGIONS entries must be <index>=<redis url>, got: #{inspect(pair)}"
      end
    end)
  end

  @doc "This deployment's region index (0..7). Distinct from the SDK's region string."
  def region_index do
    value = Application.get_env(:sre_chat, :region_index, 0)

    case value do
      int when is_integer(int) and int in 0..7 ->
        int

      other ->
        raise ArgumentError,
              "REGION_INDEX must be an integer between 0 and 7, got: #{inspect(other)}"
    end
  end

  def version, do: Application.get_env(:sre_chat, :version, "dev")
  def reject_weak_admin_api_key?, do: boolean_env(:reject_weak_admin_api_key, false)

  def local_jwt_secret do
    case Application.get_env(:sre_chat, :local_jwt_secret) do
      value when value in [nil, ""] -> runtime_secret(:sre_chat_local_jwt_secret)
      value -> value
    end
  end

  def region, do: Application.fetch_env!(:sre_chat, :region)
  def cors_allowed_origins, do: cors_csv_env(:cors_allowed_origins)
  def host, do: Application.fetch_env!(:sre_chat, :host)
  # The HTTP API host defaults to host(), so production is unchanged. It can be
  # set separately (API_HOST env) for local debugging where the HTTP API must
  # carry a port (e.g. a TLS proxy on :4443) while CHAT_HOST stays a bare name
  # so the SDK's wss://<CHAT_HOST>:<CHAT_WSS_PORT> URL does not become
  # localhost:4443:4443 and crash the client's socket URL builder.
  def api_host, do: Application.get_env(:sre_chat, :api_host) || host()
  def ws_port, do: Application.fetch_env!(:sre_chat, :ws_port)

  # Optional direct-TLS listener (see Application.direct_tls_children/0). Unset
  # means "no second listener", which is the default everywhere.
  def ws_tls_port do
    case Application.get_env(:sre_chat, :ws_tls_port) do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> integer_or_nil(value)
      _ -> nil
    end
  end

  def ws_tls_certfile, do: presence(Application.get_env(:sre_chat, :ws_tls_certfile))
  def ws_tls_keyfile, do: presence(Application.get_env(:sre_chat, :ws_tls_keyfile))

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  defp integer_or_nil(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end
  # Defaults true so production (behind TLS-terminating Caddy) is unchanged.
  # Set CHAT_USE_SSL=false only for a plain-HTTP local backend, where the
  # client SDKs must be told not to upgrade http/ws to https/wss.
  def use_ssl?, do: Application.get_env(:sre_chat, :use_ssl, true)
  # Shared access passcode. When set, every uid-token sign-in must carry a
  # matching "|<passcode>" suffix, so only holders of the passcode get in. nil
  # (default) keeps the deployment open, as for dev/test.
  def access_secret, do: Application.get_env(:sre_chat, :access_secret)

  # Shared secret for POST /hooks/<source>. nil (default) makes the endpoint
  # refuse everything: an open webhook that posts to your pager is worse than a
  # missing one, so it fails closed rather than open.
  def webhook_secret, do: Application.get_env(:sre_chat, :webhook_secret)

  # Who inbound alerts are addressed to. Same default as the agents use, so a
  # deployment that never sets it still lands them somewhere a human reads.
  def owner_uid, do: presence(Application.get_env(:sre_chat, :owner_uid)) || "joseph"

  # This region's SRE agent. Inbound signals go to the owner AND to the agent:
  # the owner so an error is visible even if the agent is dead, the agent so
  # something triages it without waiting for a human to read chat.
  def agent_uid do
    presence(Application.get_env(:sre_chat, :agent_uid)) || "sre-agent-#{region_index()}"
  end
  def extension_domain, do: Application.fetch_env!(:sre_chat, :extension_domain)
  def upload_dir, do: Application.fetch_env!(:sre_chat, :upload_dir)

  def media_storage do
    Application.get_env(:sre_chat, :media_storage, "local")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  def local_media_storage_allowed?, do: boolean_env(:allow_local_media_storage, false)

  def s3_bucket, do: Application.get_env(:sre_chat, :s3_bucket)
  def s3_presigned_url_ttl_seconds, do: integer_env(:s3_presigned_url_ttl_seconds, 3600)

  def s3_region do
    Application.get_env(:sre_chat, :s3_region) ||
      System.get_env("AWS_REGION") ||
      System.get_env("AWS_DEFAULT_REGION") ||
      "us-east-1"
  end

  def s3_client, do: Application.get_env(:sre_chat, :s3_client, SREChat.S3Client)

  def request_body_limit,
    do: Application.get_env(:sre_chat, :request_body_limit, @default_request_body_limit)

  def upload_max_bytes,
    do: Application.get_env(:sre_chat, :upload_max_bytes, @default_upload_max_bytes)

  def upload_allowed_mime_types,
    do: csv_env(:upload_allowed_mime_types, @default_upload_allowed_mime_types)

  def redis_url, do: Application.get_env(:sre_chat, :redis_url)
  def redis_key_prefix, do: Application.fetch_env!(:sre_chat, :redis_key_prefix)
  def redis_snapshot_key, do: Application.fetch_env!(:sre_chat, :redis_snapshot_key)

  def redis_boot_mode do
    :sre_chat
    |> Application.get_env(:redis_boot_mode, "full")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  def seed_users_json, do: Application.fetch_env!(:sre_chat, :seed_users_json)
  def seed_groups_json, do: Application.fetch_env!(:sre_chat, :seed_groups_json)
  def accept_uid_tokens?, do: Application.fetch_env!(:sre_chat, :accept_uid_tokens)

  def group_max_members,
    do: integer_env(:group_max_members, @default_group_max_members)

  def group_max_messages,
    do: integer_env(:group_max_messages, @default_group_max_messages)

  def group_message_retention_days,
    do: integer_env(:group_message_retention_days, @default_group_message_retention_days)

  def group_unread_fanout_limit,
    do: integer_env(:group_unread_fanout_limit, @default_group_unread_fanout_limit)

  def group_presence_ttl_seconds,
    do: integer_env(:group_presence_ttl_seconds, @default_group_presence_ttl_seconds)

  def group_max_presence,
    do: integer_env(:group_max_presence, @default_group_max_presence)

  def redis_conversation_refresh_limit,
    do: integer_env(:redis_conversation_refresh_limit, @default_redis_conversation_refresh_limit)

  def redis_publisher_lanes do
    :redis_publisher_lanes
    |> integer_env(@default_redis_publisher_lanes)
    |> max(1)
    |> min(16)
  end

  def dm_history_connect_grace_ms,
    do:
      non_negative_integer_env(:dm_history_connect_grace_ms, @default_dm_history_connect_grace_ms)

  def websocket_heartbeat_ms,
    do: non_negative_integer_env(:websocket_heartbeat_ms, @default_websocket_heartbeat_ms)

  def public_group_reads_enabled?,
    do: boolean_env(:public_group_reads_enabled, true)

  def public_group_joins_as_visits?,
    do: boolean_env(:public_group_joins_as_visits, false)

  def cors_allowed_origin(origin) do
    origin = origin |> to_s() |> String.trim()
    allowed = cors_allowed_origins()
    normalised_origin = normalise_origin(origin)

    cond do
      "*" in allowed -> "*"
      origin == "" -> nil
      origin in allowed -> origin
      Enum.any?(allowed, &origin_entry_matches?(&1, origin, normalised_origin)) -> origin
      true -> nil
    end
  end

  def settings do
    extensions = [
      # `enabled` is NOT optional to clients. The CometChat iOS SDK force
      # unwraps it while decoding the login response, so an entry without it
      # crashes the app (SIGTRAP in loginCallToServerWith) before the login
      # callback can fire — every iOS login died here, looking like a hang.
      # The JS SDK tolerates its absence, which is why the web client worked
      # and hid this for so long. `version` and `configuration` are included
      # because the SDK reads them too; only `enabled` is load-bearing today.
      %{
        "id" => "reactions",
        "name" => "reactions",
        "enabled" => true,
        "version" => "1.0",
        "configuration" => %{}
      }
    ]

    upper = %{
      "CHAT_HOST" => host(),
      "CHAT_HOST_OVERRIDE" => nil,
      "CHAT_HOST_APP_SPECIFIC" => nil,
      "CHAT_USE_SSL" => use_ssl?(),
      "CHAT_WSS_PORT" => to_string(ws_port()),
      "CHAT_WS_PORT" => to_string(ws_port()),
      "CHAT_API_VERSION" => "v3.0",
      "WS_API_VERSION" => "v3.0",
      "ADMIN_API_HOST" => api_host(),
      "CLIENT_API_HOST" => api_host(),
      "MAIN_DOMAIN" => host(),
      "REGION" => region(),
      "MODE" => "DEFAULT",
      "APP_VERSION" => 4,
      "ANALYTICS_PING_DISABLED" => true,
      "ANALYTICS_HOST" => host(),
      "ANALYTICS_VERSION" => "v1",
      "ANALYTICS_USE_SSL" => use_ssl?(),
      "POLLING_ENABLED" => false,
      "DENY_FALLBACK_TO_POLLING" => false,
      "EXTENSION_DOMAIN" => extension_domain(),
      "extensions" => extensions,
      "SECURED_MEDIA_HOST" => nil,
      "settingsHash" => "open-chat-0.1.0",
      "settingsHashReceivedAt" => SREChat.Time.now()
    }

    upper
  end

  # The iOS SDK's settings model uses camelCase PROPERTY names (chatWssPort,
  # chatHost, the webRTC* group) mapped by CodingKeys onto these UPPER_SNAKE
  # JSON keys — which is why both spellings appear in its binary. UPPER_SNAKE is
  # the wire format for BOTH SDKs; there is no per-client casing.
  #
  # Recorded because the wrong reading of that evidence cost a lot: serving
  # camelCase made the settings decode leave chat_wss_port nil, and
  # CometChatSocketController.connect() then bailed at its own port guard
  # WITHOUT dialling and without an error — a silent no-socket that looks
  # exactly like a client that refuses to connect. The real blocker was always
  # the malformed JWT (see AuthTokens.local_jwt); with a decodable JWT and these
  # UPPER_SNAKE settings the native socket connects in about a second.
  def ios_settings, do: settings()

  # Kept so the router has a stable predicate if a future divergence is needed;
  # today both clients get the same payload.
  def ios_client?(resource) when is_binary(resource),
    do: String.starts_with?(resource, "ios")

  def ios_client?(_), do: false

  defp runtime_secret(key) do
    case :persistent_term.get(key, nil) do
      nil ->
        secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        :persistent_term.put(key, secret)
        secret

      secret ->
        secret
    end
  end

  defp csv_env(key, fallback) do
    case Application.get_env(:sre_chat, key) do
      value when value in [nil, ""] ->
        fallback

      value when is_list(value) ->
        value

      value ->
        value
        |> to_string()
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp integer_env(key, fallback) do
    case Application.get_env(:sre_chat, key, fallback) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        case Integer.parse(to_string(value)) do
          {int, _rest} when int > 0 -> int
          _other -> fallback
        end
    end
  end

  defp non_negative_integer_env(key, fallback) do
    case Application.get_env(:sre_chat, key, fallback) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        case Integer.parse(to_string(value)) do
          {int, _rest} when int >= 0 -> int
          _other -> fallback
        end
    end
  end

  defp boolean_env(key, fallback) do
    case Application.get_env(:sre_chat, key, fallback) do
      value when value in [true, "true", "TRUE", "1", 1, "yes", "YES"] -> true
      value when value in [false, "false", "FALSE", "0", 0, "no", "NO"] -> false
      _other -> fallback
    end
  end

  defp origin_entry_matches?(entry, origin, normalised_origin) do
    entry = entry |> to_s() |> String.trim()

    cond do
      entry == "" ->
        false

      normalised_origin != nil and normalise_origin(entry) == normalised_origin ->
        true

      wildcard_origin_match?(entry, origin) ->
        true

      true ->
        false
    end
  end

  defp normalise_origin(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) ->
        scheme = String.downcase(scheme)
        host = String.downcase(host)
        port_suffix = if default_port?(scheme, port), do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port_suffix}"

      _other ->
        nil
    end
  rescue
    _error -> nil
  end

  defp wildcard_origin_match?(entry, origin) do
    with %URI{scheme: entry_scheme, host: <<"*.", suffix::binary>>, port: entry_port} <-
           URI.parse(entry),
         %URI{scheme: origin_scheme, host: origin_host, port: origin_port} <- URI.parse(origin),
         true <- is_binary(entry_scheme) and is_binary(origin_scheme),
         true <- String.downcase(entry_scheme) == String.downcase(origin_scheme),
         true <- origin_port_allowed?(entry_scheme, entry_port, origin_port),
         true <- is_binary(origin_host) do
      suffix = String.downcase(suffix)
      origin_host = String.downcase(origin_host)
      origin_host != suffix and String.ends_with?(origin_host, "." <> suffix)
    else
      _other -> false
    end
  rescue
    _error -> false
  end

  defp default_port?("http", 80), do: true
  defp default_port?("https", 443), do: true
  defp default_port?(_scheme, nil), do: true
  defp default_port?(_scheme, _port), do: false

  defp origin_port_allowed?(scheme, entry_port, origin_port) do
    cond do
      entry_port == origin_port ->
        true

      default_port?(String.downcase(to_s(scheme)), entry_port) ->
        default_port?(scheme, origin_port)

      true ->
        false
    end
  end

  defp cors_csv_env(key) do
    case Application.get_env(:sre_chat, key, "*") do
      nil ->
        ["*"]

      "" ->
        []

      value when is_list(value) ->
        value

      value ->
        value
        |> to_string()
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
