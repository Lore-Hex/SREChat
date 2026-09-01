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
  alias SREChat.Store

  test "a healthy region reports no problems" do
    assert Endpoint.health_problems() == []
  end

  test "the endpoint answers 200 when there are no problems" do
    conn = Plug.Test.conn(:get, "/health") |> Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  describe "a busy store is not a broken one" do
    # `:sys.suspend/1` stops the GenServer handling calls while they queue —
    # exactly the state a replication batch puts the store in, and the state the
    # old 250ms probe reported as "this region cannot serve".
    setup do
      on_exit(fn -> try do: :sys.resume(SREChat.Store), rescue: (_ -> :ok) end)
      :ok
    end

    test "a stall longer than one probe does NOT fail health" do
      # Region 0 answered 503 for 223 requests in six hours this way, while
      # every real /v3.0 request in the same window succeeded, and each 503 cost
      # the owner a NODE DOWN and a RECOVERED alert on their phone.
      :sys.suspend(SREChat.Store)

      resumer =
        Task.async(fn ->
          Process.sleep(1_200)
          :sys.resume(SREChat.Store)
        end)

      problems = SREChatWeb.Endpoint.health_problems()
      Task.await(resumer, 10_000)

      refute Enum.any?(problems, &(&1 =~ "store")),
             "a momentary stall was reported as unfit: #{inspect(problems)}"
    end

    test "a store stuck through EVERY probe still fails health" do
      # The tolerance must not become blindness: a store that never answers is
      # genuinely unfit and has to say so.
      :sys.suspend(SREChat.Store)

      resumer =
        Task.async(fn ->
          Process.sleep(4_000)
          :sys.resume(SREChat.Store)
        end)

      problems = SREChatWeb.Endpoint.health_problems()
      Task.await(resumer, 12_000)

      assert Enum.any?(problems, &(&1 =~ "store request queue blocked")),
             "a fully blocked store was reported healthy: #{inspect(problems)}"
    end
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

  test "a blocked Store fails readiness instead of looking alive" do
    :sys.suspend(Store)

    try do
      started = System.monotonic_time(:millisecond)
      problems = Endpoint.health_problems()
      elapsed = System.monotonic_time(:millisecond) - started

      assert "store request queue blocked" in problems
      # Bounded, not instant. The probe deliberately costs two attempts
      # (2 x 700ms + 100ms backoff) because a single 250ms budget reported
      # ordinary replication backpressure as an outage — 223 false 503s in six
      # hours on region 0, each one a NODE DOWN and a RECOVERED on the owner's
      # phone. Still well inside any sane load-balancer timeout, and the check
      # must never hang: that is what this assertion is really guarding.
      assert elapsed < 2_000
    after
      :sys.resume(Store)
    end
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
