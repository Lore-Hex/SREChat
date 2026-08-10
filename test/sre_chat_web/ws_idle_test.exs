defmodule SREChatWeb.WsIdleTest do
  @moduledoc """
  Transport-layer answer to the reported web-client disconnect: does an
  AUTHENTICATED, COMPLETELY SILENT connection survive past cowboy's 60s
  default idle_timeout, held open only by the server's own heartbeat?

  A browser tab in the background is exactly this client: JS timers are
  throttled so the SDK cannot send its app-level pings, but the browser's
  network stack still answers protocol pings natively. If the server-side
  stack holds here, the reported disconnects live in the proxy layer or
  the SDK's own watchdog — not in this codebase.

  Tagged :idle (excluded by default): the decisive test necessarily
  spans the 60-second window it is interrogating.

      mix test --include idle test/sre_chat_web/ws_idle_test.exs
  """

  use ExUnit.Case, async: false

  alias SREChat.RawWsClient

  @observe_ms 95_000

  @tag :idle
  @tag timeout: 180_000
  test "a silent authenticated socket outlives the cowboy idle window" do
    port = RawWsClient.listener_port()
    assert is_integer(port), "no cowboy listener found"

    {:ok, socket} = RawWsClient.connect(port)

    :ok =
      RawWsClient.send_text(
        socket,
        Jason.encode!(%{"type" => "auth", "body" => %{"auth" => "uid:idle-user"}})
      )

    {verdict, events} = RawWsClient.observe(socket, @observe_ms)

    pings = Enum.count(events, &match?({_ms, :server_ping}, &1))

    assert verdict == :alive, """
    server closed a silent authenticated socket: #{inspect(events)}
    (heartbeat should have held it open past the idle window)
    """

    # 95s at a 25s heartbeat: at least 3 pings must have arrived, or the
    # heartbeat is not actually running and only luck kept the socket up.
    assert pings >= 3, "expected >=3 server heartbeat pings, saw #{pings}: #{inspect(events)}"
  end

  @tag :idle
  @tag timeout: 120_000
  test "an unauthenticated socket is closed by the auth timeout, not left hanging" do
    port = RawWsClient.listener_port()
    {:ok, socket} = RawWsClient.connect(port)

    {verdict, events} = RawWsClient.observe(socket, 45_000)

    assert verdict == :closed,
           "unauthenticated sockets must be reaped by the 30s auth timeout: #{inspect(events)}"

    {closed_at, _} = List.last(events)
    assert closed_at >= 25_000 and closed_at <= 40_000
  end
end
