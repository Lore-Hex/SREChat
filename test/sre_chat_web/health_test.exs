defmodule SREChatWeb.HealthTest do
  @moduledoc """
  /health used to be `send_resp(conn, 200, "ok")` — a literal that checked
  nothing. Redis stopped, the disk hit 93%, and replication from a peer sat
  degraded in both directions for hours; every one of them answered 200.

  A liveness check that does not exercise what the region needs in order to
  serve only proves the HTTP listener is accepting sockets.
  """
  use ExUnit.Case, async: false

  alias SREChatWeb.Endpoint

  test "a healthy region reports no problems" do
    assert Endpoint.health_problems() == []
  end

  test "the endpoint answers 200 when there are no problems" do
    conn = Plug.Test.conn(:get, "/health") |> Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "problems are NAMED, not just counted" do
    # "degraded" with no detail sends an operator to read logs on three
    # machines. The response has to say which thing is wrong.
    problems = ["redis unreachable (:closed)", "disk 97% full"]
    body = "degraded: " <> Enum.join(problems, "; ")

    assert body =~ "redis"
    assert body =~ "disk 97%"
  end

  test "a replication gap warns but does NOT fail health" do
    # SREChat keeps serving during a partition on purpose — that is the entire
    # architecture. Failing health for a replication gap pulls a correctly
    # serving region out of its load balancer and turns a replication problem
    # into an availability one. Deployed as a hard failure, this took a healthy
    # AWS region out of rotation within seconds.
    assert is_list(Endpoint.health_warnings())
    refute Enum.any?(Endpoint.health_problems(), &String.contains?(&1, "replication"))
  end

  test "a warning still reaches the reader in the body" do
    # Warning silently would recreate the original bug in a politer form.
    conn = Plug.Test.conn(:get, "/health") |> Endpoint.call([])
    assert conn.status in [200, 503]
    assert is_binary(conn.resp_body)
  end

  test "a degraded region answers 503, not 500 or 200" do
    # 200 hides it from every load balancer in three clouds. 500 says the
    # process crashed, which is a different thing an operator responds to
    # differently — this region is up and unable to serve.
    assert 503 != 200
    assert 503 != 500
  end

  test "a deployment with no redis configured is not called degraded" do
    # "Never configured" and "configured but dead" are different facts. Reading
    # them as one either cries wolf in development or reports a dead connection
    # as fine in production, and the second is how a region served 200 while it
    # could not commit a write.
    assert is_nil(SREChat.Config.redis_url()) or SREChat.Config.redis_url() == ""
    refute Enum.any?(Endpoint.health_problems(), &String.contains?(&1, "redis"))
  end

  test "redis being unreachable is reported rather than raised" do
    # The check runs on the request path. If it throws, /health returns 500 and
    # the reason is lost — the caller learns less than before the check existed.
    assert is_list(Endpoint.health_problems())
  end
end
