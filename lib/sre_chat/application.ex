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
      ] ++ replication_children()

    case Supervisor.start_link(children, strategy: :one_for_one, name: SREChat.Supervisor) do
      {:ok, _pid} = result ->
        Logger.info("SREChat listening on :#{port}")
        result

      other ->
        other
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
