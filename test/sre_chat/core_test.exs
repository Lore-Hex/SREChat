defmodule SREChat.CoreTest do
  use ExUnit.Case, async: false
  import Plug.Test

  test "settings expose the SDK host, websocket, extension, and version fields" do
    settings = SREChat.Config.settings()

    assert settings["CHAT_HOST"] == "localhost"
    assert settings["CHAT_API_VERSION"] == "v3.0"
    assert settings["WS_API_VERSION"] == "v3.0"
    assert settings["CHAT_WSS_PORT"] == "4001"
    assert [%{"id" => "reactions"}] = settings["extensions"]
    assert is_integer(settings["settingsHashReceivedAt"])
  end

  test "error helpers keep CometChat-compatible codes and details" do
    assert SREChat.Errors.no_auth()["code"] == "ERR_NO_AUTH"
    assert SREChat.Errors.missing("uid")["details"] == %{"parameter" => "uid"}
    assert SREChat.Errors.invalid("password", "Bad password.")["code"] == "INVALID_PASSWORD"
    assert SREChat.Errors.user_not_found("u1")["details"] == %{"uid" => "u1"}
    assert SREChat.Errors.group_not_found("g1")["details"] == %{"guid" => "g1"}
    assert SREChat.Errors.message_not_found("1")["details"] == %{"id" => "1"}
  end

  test "JSON helpers wrap ok, raw, and error responses consistently" do
    ok_conn = SREChatWeb.JSON.ok(conn(:get, "/"), %{"value" => 1}, 201)
    assert ok_conn.status == 201
    assert Jason.decode!(ok_conn.resp_body) == %{"data" => %{"value" => 1}}

    raw_conn = SREChatWeb.JSON.raw(conn(:get, "/"), %{"meta" => %{"count" => 2}})
    assert raw_conn.status == 200
    assert Jason.decode!(raw_conn.resp_body) == %{"meta" => %{"count" => 2}}

    media_conn =
      SREChatWeb.JSON.raw(conn(:get, "/"), %{
        "data" => [
          %{
            "type" => "image",
            "data" => %{
              "metadata" => %{
                "chatMessage" => %{"media" => %{"name" => "missing.png"}}
              }
            }
          }
        ]
      })

    [message] = Jason.decode!(media_conn.resp_body)["data"]
    assert message["type"] == "text"
    assert get_in(message, ["data", "text"]) == "missing.png"

    error = SREChat.Errors.forbidden("Nope.")
    error_conn = SREChatWeb.JSON.error(conn(:get, "/"), error, 403)
    assert error_conn.status == 403
    assert Jason.decode!(error_conn.resp_body) == %{"error" => error}
  end

  test "PubSub can broadcast to single and multiple registered keys" do
    assert {:ok, _} = SREChat.PubSub.subscribe({:user, "core-a"})
    assert {:ok, _} = SREChat.PubSub.subscribe({:group, "core-room"})

    user_event = %{"type" => "user-event"}
    room_event = %{"type" => "room-event"}

    assert :ok = SREChat.PubSub.broadcast({:user, "core-a"}, user_event)
    assert_receive {:comet_event, ^user_event}

    assert :ok =
             SREChat.PubSub.broadcast(
               [{:user, "core-a"}, {:group, "core-room"}],
               room_event
             )

    assert_receive {:comet_event, ^room_event}
    assert_receive {:comet_event, ^room_event}
  end

  test "PubSub system events are separate from client events" do
    assert {:ok, _} = SREChat.PubSub.subscribe({:user, "system-core-a"})

    event = %{"type" => "membership_changed"}
    assert :ok = SREChat.PubSub.broadcast_system({:user, "system-core-a"}, event)

    assert_receive {:sre_chat_system_event, ^event}
    refute_receive {:comet_event, ^event}, 20
  end

  test "time helpers return monotonic wall-clock shaped values" do
    seconds = SREChat.Time.now()
    millis = SREChat.Time.now_ms()

    assert is_integer(seconds)
    assert is_integer(millis)
    assert millis >= seconds * 1000
    assert millis < seconds * 1000 + 2000
  end
end
