defmodule OpenChatWeb.WsIdleTimeoutConfigTest do
  use ExUnit.Case, async: false

  alias OpenChatWeb.WSHandler

  setup do
    previous = Application.get_env(:open_chat, :websocket_heartbeat_ms)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:open_chat, :websocket_heartbeat_ms)
        value -> Application.put_env(:open_chat, :websocket_heartbeat_ms, value)
      end
    end)

    :ok
  end

  test "idle timeout gives three missed heartbeats, floored at 75s" do
    Application.put_env(:open_chat, :websocket_heartbeat_ms, 25_000)
    assert WSHandler.idle_timeout_ms() == 75_000

    Application.put_env(:open_chat, :websocket_heartbeat_ms, 40_000)
    assert WSHandler.idle_timeout_ms() == 120_000

    Application.put_env(:open_chat, :websocket_heartbeat_ms, 5_000)
    assert WSHandler.idle_timeout_ms() == 75_000
  end

  test "disabling the heartbeat disables the idle timeout with it" do
    # Cowboy's silent 60s default with no heartbeat means every quiet
    # browser tab dies within a minute — the reported failure mode. The
    # operator who turns the heartbeat off owns liveness at the proxy.
    Application.put_env(:open_chat, :websocket_heartbeat_ms, 0)
    assert WSHandler.idle_timeout_ms() == :infinity
  end
end
