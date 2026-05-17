defmodule OpenChat.CoreTest do
  use ExUnit.Case, async: false
  import Plug.Test

  test "settings expose the SDK host, websocket, extension, and version fields" do
    settings = OpenChat.Config.settings()

    assert settings["CHAT_HOST"] == "localhost"
    assert settings["CHAT_API_VERSION"] == "v3.0"
    assert settings["WS_API_VERSION"] == "v3.0"
    assert settings["CHAT_WSS_PORT"] == "4001"
    assert [%{"id" => "reactions"}] = settings["extensions"]
    assert is_integer(settings["settingsHashReceivedAt"])
  end

  test "error helpers keep CometChat-compatible codes and details" do
    assert OpenChat.Errors.no_auth()["code"] == "ERR_NO_AUTH"
    assert OpenChat.Errors.missing("uid")["details"] == %{"parameter" => "uid"}
    assert OpenChat.Errors.invalid("password", "Bad password.")["code"] == "INVALID_PASSWORD"
    assert OpenChat.Errors.user_not_found("u1")["details"] == %{"uid" => "u1"}
    assert OpenChat.Errors.group_not_found("g1")["details"] == %{"guid" => "g1"}
    assert OpenChat.Errors.message_not_found("1")["details"] == %{"id" => "1"}
  end

  test "JSON helpers wrap ok, raw, and error responses consistently" do
    ok_conn = OpenChatWeb.JSON.ok(conn(:get, "/"), %{"value" => 1}, 201)
    assert ok_conn.status == 201
    assert Jason.decode!(ok_conn.resp_body) == %{"data" => %{"value" => 1}}

    raw_conn = OpenChatWeb.JSON.raw(conn(:get, "/"), %{"meta" => %{"count" => 2}})
    assert raw_conn.status == 200
    assert Jason.decode!(raw_conn.resp_body) == %{"meta" => %{"count" => 2}}

    media_conn =
      OpenChatWeb.JSON.raw(conn(:get, "/"), %{
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

    error = OpenChat.Errors.forbidden("Nope.")
    error_conn = OpenChatWeb.JSON.error(conn(:get, "/"), error, 403)
    assert error_conn.status == 403
    assert Jason.decode!(error_conn.resp_body) == %{"error" => error}
  end

  test "PubSub can broadcast to single and multiple registered keys" do
    assert {:ok, _} = OpenChat.PubSub.subscribe({:user, "core-a"})
    assert {:ok, _} = OpenChat.PubSub.subscribe({:group, "core-room"})

    user_event = %{"type" => "user-event"}
    room_event = %{"type" => "room-event"}

    assert :ok = OpenChat.PubSub.broadcast({:user, "core-a"}, user_event)
    assert_receive {:comet_event, ^user_event}

    assert :ok =
             OpenChat.PubSub.broadcast(
               [{:user, "core-a"}, {:group, "core-room"}],
               room_event
             )

    assert_receive {:comet_event, ^room_event}
    assert_receive {:comet_event, ^room_event}
  end

  test "PubSub system events are separate from client events" do
    assert {:ok, _} = OpenChat.PubSub.subscribe({:user, "system-core-a"})

    event = %{"type" => "membership_changed"}
    assert :ok = OpenChat.PubSub.broadcast_system({:user, "system-core-a"}, event)

    assert_receive {:open_chat_system_event, ^event}
    refute_receive {:comet_event, ^event}, 20
  end

  test "time helpers return monotonic wall-clock shaped values" do
    seconds = OpenChat.Time.now()
    millis = OpenChat.Time.now_ms()

    assert is_integer(seconds)
    assert is_integer(millis)
    assert millis >= seconds * 1000
    assert millis < seconds * 1000 + 2000
  end
end
