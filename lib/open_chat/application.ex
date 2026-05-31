defmodule OpenChat.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    ensure_security_config!()
    ensure_media_storage!()

    port = Application.fetch_env!(:open_chat, :port)

    children = [
      {Registry, keys: :duplicate, name: OpenChat.PubSub},
      OpenChat.Store,
      OpenChat.RedisBus,
      {Plug.Cowboy,
       scheme: :http, plug: OpenChatWeb.Endpoint, options: [port: port, dispatch: dispatch()]}
    ]

    Logger.info("OpenChat listening on :#{port}")
    Supervisor.start_link(children, strategy: :one_for_one, name: OpenChat.Supervisor)
  end

  def ensure_security_config! do
    ensure_admin_api_key!()
  end

  defp ensure_admin_api_key! do
    api_key = OpenChat.Config.api_key()

    if OpenChat.Config.reject_weak_admin_api_key?() and weak_secret?(api_key) do
      raise ArgumentError,
            "COMETCHAT_API_KEY must be blank to disable admin routes or a random value with at least 32 characters"
    end

    :ok
  end

  def ensure_media_storage! do
    case OpenChat.Config.media_storage() do
      "local" ->
        if OpenChat.Config.local_media_storage_allowed?() do
          upload_dir = Application.fetch_env!(:open_chat, :upload_dir)
          File.mkdir_p!(upload_dir)
        else
          raise ArgumentError,
                "MEDIA_STORAGE=local is not allowed in this environment; use MEDIA_STORAGE=s3"
        end

      "s3" ->
        if blank?(OpenChat.Config.s3_bucket()) do
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

  defp dispatch do
    [
      {:_,
       [
         {"/socket", OpenChatWeb.WSHandler, []},
         {"/ws", OpenChatWeb.WSHandler, []},
         {"/", OpenChatWeb.WSHandler, []},
         {:_, Plug.Cowboy.Handler, {OpenChatWeb.Endpoint, []}}
       ]}
    ]
  end

  defp blank?(value), do: value in [nil, ""]
end
