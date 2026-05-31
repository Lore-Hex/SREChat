defmodule OpenChatWeb.Endpoint do
  @moduledoc false
  use Plug.Router
  @parser_opts_key {__MODULE__, :parser_opts}

  plug(:cors)
  plug(:security_headers)
  plug(:parse_body)

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
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
end
