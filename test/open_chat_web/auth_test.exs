defmodule OpenChatWeb.AuthTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OpenChatWeb.Auth
  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "token/1 extracts from authtoken header" do
    conn = conn(:get, "/") |> put_req_header("authtoken", "t1")
    assert Auth.token(conn) == "t1"
  end

  test "token/1 extracts from authorization bearer header" do
    conn = conn(:get, "/") |> put_req_header("authorization", "Bearer t2")
    assert Auth.token(conn) == "t2"

    conn = conn(:get, "/") |> put_req_header("authorization", "bearer t3")
    assert Auth.token(conn) == "t3"
  end

  test "token/1 extracts from params" do
    conn = conn(:get, "/?authToken=t4") |> fetch_query_params()
    assert Auth.token(conn) == "t4"
  end

  test "admin? returns true for valid apikey" do
    old_key = Application.get_env(:open_chat, :api_key)
    Application.put_env(:open_chat, :api_key, "secret")

    conn = conn(:get, "/") |> put_req_header("apikey", "secret")
    assert Auth.admin?(conn)

    conn = conn(:get, "/") |> put_req_header("apikey", "wrong")
    refute Auth.admin?(conn)

    Application.put_env(:open_chat, :api_key, old_key)
  end

  test "with_user/2 calls fun with user if authenticated" do
    {:ok, %{"authToken" => token}} = Store.create_auth_token("alice")
    conn = conn(:get, "/") |> put_req_header("authtoken", token)

    Auth.with_user(conn, fn _conn, user, t ->
      assert user["uid"] == "alice"
      assert t == token
      :ok
    end)
  end

  test "with_user/2 returns 401 if unauthenticated" do
    conn = conn(:get, "/") |> put_req_header("authtoken", "invalid")
    conn = Auth.with_user(conn, fn _, _, _ -> :ok end)

    assert conn.status == 401
    assert conn.resp_body =~ "ERR_NO_AUTH"
  end
end
