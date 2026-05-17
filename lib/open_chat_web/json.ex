defmodule OpenChatWeb.JSON do
  @moduledoc false
  import Plug.Conn
  alias OpenChat.Store.MessageData

  def ok(conn, data, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"data" => MessageData.ensure_media_wire_shapes(data)}))
  end

  def raw(conn, body, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(MessageData.ensure_media_wire_shapes(body)))
  end

  def error(conn, error, status \\ 400) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => error}))
  end
end
