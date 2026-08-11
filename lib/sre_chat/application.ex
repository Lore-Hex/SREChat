defmodule SREChat.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    ensure_security_config!()
    ensure_media_storage!()
    SREChat.Replication.ensure_valid_config!()

    port = Application.fetch_env!(:sre_chat, :port)

    children =
      [
        SREChat.Observability,
        {Registry, keys: :duplicate, name: SREChat.PubSub},
        SREChat.Store,
        SREChat.RedisBus,
        {Plug.Cowboy,
         scheme: :http, plug: SREChatWeb.Endpoint, options: [port: port, dispatch: dispatch()]}
      ] ++ direct_tls_children() ++ replication_children()

    case Supervisor.start_link(children, strategy: :one_for_one, name: SREChat.Supervisor) do
      {:ok, _pid} = result ->
        Logger.info("SREChat listening on :#{port}")
        result

      other ->
        other
    end
  end

  # An optional SECOND listener that terminates TLS itself, so a client can
  # reach the WebSocket without a reverse proxy in the path.
  #
  # Caddy injects its own headers into the 101 that completes a WebSocket
  # handshake (a duplicate `Server`, and `Alt-Svc` when HTTP/3 is on) and
  # cannot be told not to — `header_down` has no effect on a response whose
  # connection has already been hijacked for the upgrade. The CometChat iOS
  # SDK intermittently rejects that handshake and then re-sends the upgrade
  # request over its own upgraded socket, which is a protocol violation, so
  # cowboy closes it and the SDK retries into a storm.
  #
  # Answering the handshake directly removes every proxy-added header from the
  # equation. Off unless WS_TLS_PORT is set, so nothing changes for a
  # deployment that does not want it.
  defp direct_tls_children do
    with port when is_integer(port) and port > 0 <- SREChat.Config.ws_tls_port(),
         cert when is_binary(cert) <- SREChat.Config.ws_tls_certfile(),
         key when is_binary(key) <- SREChat.Config.ws_tls_keyfile(),
         true <- File.exists?(cert) and File.exists?(key) do
      Logger.info("SREChat direct-TLS listener on :#{port}")

      [
        {Plug.Cowboy,
         scheme: :https,
         plug: SREChatWeb.Endpoint,
         options: [
           port: port,
           dispatch: dispatch(),
           certfile: cert,
           keyfile: key,
           otp_app: :sre_chat
         ]}
      ]
    else
      _ -> []
    end
  end

  def ensure_security_config! do
    ensure_admin_api_key!()
  end

  defp ensure_admin_api_key! do
    api_key = SREChat.Config.api_key()

    if SREChat.Config.reject_weak_admin_api_key?() and weak_secret?(api_key) do
      raise ArgumentError,
            "COMETCHAT_API_KEY must be blank to disable admin routes or a random value with at least 32 characters"
    end

    :ok
  end

  def ensure_media_storage! do
    case SREChat.Config.media_storage() do
      "local" ->
        if SREChat.Config.local_media_storage_allowed?() do
          upload_dir = Application.fetch_env!(:sre_chat, :upload_dir)
          File.mkdir_p!(upload_dir)
        else
          raise ArgumentError,
                "MEDIA_STORAGE=local is not allowed in this environment; use MEDIA_STORAGE=s3"
        end

      "s3" ->
        if blank?(SREChat.Config.s3_bucket()) do
          raise ArgumentError, "S3_BUCKET is required when MEDIA_STORAGE=s3"
        end

        :ok

      other ->
        raise ArgumentError, "unsupported MEDIA_STORAGE=#{inspect(other)}; expected local or s3"
    end
  end

  defp weak_secret?(value) when value in [nil, ""], do: false

  defp weak_secret?(value) do
    value = value |> to_string() |> String.trim()
    String.downcase(value) in ["none", "null", "undefined"] or String.length(value) < 32
  end

  defp replication_children do
    if SREChat.Replication.enabled?() and SREChat.Config.peer_regions() != [] do
      [SREChat.Replication.Supervisor]
    else
      []
    end
  end

  defp dispatch do
    [
      {:_,
       [
         {"/socket", SREChatWeb.WSHandler, []},
         {"/ws", SREChatWeb.WSHandler, []},
         {"/", SREChatWeb.WSHandler, []},
         {:_, Plug.Cowboy.Handler, {SREChatWeb.Endpoint, []}}
       ]}
    ]
  end

  defp blank?(value), do: value in [nil, ""]
end
