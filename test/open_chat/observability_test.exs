defmodule OpenChat.ObservabilityTest do
  use ExUnit.Case, async: false

  setup do
    OpenChat.Observability.reset!()
    :ok
  end

  test "records counters, gauges, histograms, and sanitised HTTP paths" do
    OpenChat.Observability.record_http("GET", "/v3.0/users/alice/messages?limit=5", 200, 42)
    OpenChat.Observability.record_store_call("send_message", true, 17, "ok")

    OpenChat.Observability.record_store_call("authenticate", false, 5, "error", %{
      "code" => "ERR_NO_AUTH"
    })

    OpenChat.Observability.record_api_error(
      "GET",
      "/v3.0/groups/room/messages",
      401,
      %{"code" => "ERR_NO_AUTH"}
    )

    OpenChat.Observability.record_auth_attempt("rest", "ERR_NO_AUTH", true)
    OpenChat.Observability.record_redis_lock([{:conversation, "room"}, {:user, "alice"}], "ok", 3)
    OpenChat.Observability.add_gauge("ws.active", 2)
    OpenChat.Observability.record_ws("auth_success")

    Process.sleep(20)
    snapshot = OpenChat.Observability.snapshot()

    assert snapshot["counters"][
             "http.requests|method=GET,path=/v3.0/users/:id/messages,status=2xx"
           ] == 1

    assert snapshot["counters"][
             "store.calls|mutating=true,outcome=ok,request=send_message"
           ] == 1

    assert snapshot["counters"][
             "store.calls|code=ERR_NO_AUTH,mutating=false,outcome=error,request=authenticate"
           ] == 1

    assert snapshot["counters"][
             "http.errors|code=ERR_NO_AUTH,method=GET,path=/v3.0/groups/:id/messages,status=4xx"
           ] == 1

    assert snapshot["counters"][
             "auth.attempts|outcome=ERR_NO_AUTH,surface=rest,token_present=true"
           ] == 1

    assert snapshot["counters"][
             "redis.lock.attempts|outcome=ok,scopes=conversation+user"
           ] == 1

    assert snapshot["counters"]["ws.events|event=auth_success"] == 1
    assert snapshot["gauges"]["ws.active"] == 2

    assert snapshot["histograms"][
             "http.duration_ms|method=GET,path=/v3.0/users/:id/messages,status=2xx"
           ]["count"] == 1
  end
end
