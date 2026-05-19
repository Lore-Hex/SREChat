defmodule OpenChat.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
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
