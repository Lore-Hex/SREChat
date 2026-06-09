defmodule OpenChatWeb.Endpoint do
  @moduledoc false
  use Plug.Router
  alias OpenChatWeb.{Auth, JSON}

  @parser_opts_key {__MODULE__, :parser_opts}

  plug(:cors)
  plug(:security_headers)
  plug(:instrument_request)
  plug(:parse_body)

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/v3/observability" do
    observability(conn)
  end

  get "/v3.0/observability" do
    observability(conn)
  end

  defp cors(conn, _opts) do
    origin = conn |> Plug.Conn.get_req_header("origin") |> List.first()

    conn
    |> put_allow_origin(OpenChat.Config.cors_allowed_origin(origin))
    |> Plug.Conn.put_resp_header(
      "access-control-allow-methods",
      "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    )
    |> Plug.Conn.put_resp_header(
      "access-control-allow-headers",
      "Authorization,Content-Type,Accept,appId,apiKey,authToken,resource,sdk,chatApiVersion,settingsHash,settingsHashReceivedAt"
    )
    |> Plug.Conn.put_resp_header("access-control-expose-headers", "*")
  end

  defp put_allow_origin(conn, nil), do: conn

  defp put_allow_origin(conn, origin) do
    Plug.Conn.put_resp_header(conn, "access-control-allow-origin", origin)
  end

  defp security_headers(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
    |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
    |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
    |> Plug.Conn.put_resp_header("vary", "origin")
  end

  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, parser_opts())
  end

  defp instrument_request(conn, _opts) do
    start = System.monotonic_time()

    Plug.Conn.register_before_send(conn, fn conn ->
      duration_ms = OpenChat.Observability.duration_ms(start)
      OpenChat.Observability.record_http(conn.method, conn.request_path, conn.status, duration_ms)

      if conn.status >= 500 or duration_ms >= 1_000 do
        require Logger

        Logger.warning(
          "HTTP #{conn.method} #{sanitize_request_path(conn.request_path)} status=#{conn.status} duration_ms=#{duration_ms}"
        )
      end

      conn
    end)
  end

  defp parser_opts do
    case :persistent_term.get(@parser_opts_key, nil) do
      nil ->
        opts =
          Plug.Parsers.init(
            parsers: [:urlencoded, :multipart, :json],
            pass: ["*/*"],
            json_decoder: Jason,
            length: OpenChat.Config.request_body_limit()
          )

        :persistent_term.put(@parser_opts_key, opts)
        opts

      opts ->
        opts
    end
  end

  options _ do
    send_resp(conn, 204, "")
  end

  forward("/v3", to: OpenChatWeb.ApiRouter)
  forward("/v3.0", to: OpenChatWeb.ApiRouter)
  forward("/", to: OpenChatWeb.ApiRouter)

  defp observability(conn) do
    if Auth.admin?(conn) do
      JSON.raw(conn, OpenChat.Observability.snapshot())
    else
      JSON.error(conn, OpenChat.Errors.forbidden("Invalid apiKey."), 403)
    end
  end

  defp sanitize_request_path(path) do
    path
    |> to_string()
    |> String.split("/", trim: true)
    |> Enum.map(fn segment ->
      if String.length(segment) > 24 or String.match?(segment, ~r/^\d+$/),
        do: ":id",
        else: segment
    end)
    |> then(&("/" <> Enum.join(&1, "/")))
  end
end
