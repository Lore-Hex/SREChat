defmodule SREChat.HttpCase do
  use ExUnit.CaseTemplate
  import Plug.Test

  using do
    quote do
      import Plug.Test
      alias SREChatWeb.Endpoint
      import SREChat.HttpCase
    end
  end

  setup do
    SREChat.Store.reset!()
    :ok
  end

  def json(conn) do
    Jason.decode!(conn.resp_body)
  end

  def auth_conn(method, path, body \\ %{}, token \\ "uid:alice") do
    conn(method, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authtoken", token)
    |> SREChatWeb.Endpoint.call([])
  end

  def admin_conn(method, path, body \\ %{}) do
    conn(method, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("apikey", "local-api-key")
    |> SREChatWeb.Endpoint.call([])
  end
end
