defmodule OpenChat.ErrorsTest do
  use ExUnit.Case, async: true

  alias OpenChat.Errors

  test "error/3 returns a CometChat-shaped error map and defaults details to an empty map" do
    assert Errors.error("BAD", "Bad request") == %{
             "code" => "BAD",
             "name" => "BAD",
             "message" => "Bad request",
             "details" => %{}
           }

    assert Errors.error("BAD", "Bad request", %{"hint" => "fix"}) == %{
             "code" => "BAD",
             "name" => "BAD",
             "message" => "Bad request",
             "details" => %{"hint" => "fix"}
           }

    assert Errors.error("BAD", "Bad request", nil)["details"] == %{}
  end

  test "named builders match the CometChat error codes the SDK looks for" do
    assert Errors.not_initialized()["code"] == "NOT_INITIALIZED"
    assert Errors.no_auth()["code"] == "ERR_NO_AUTH"

    assert %{"code" => "ERR_UID_NOT_FOUND", "details" => %{"uid" => "alice"}, "message" => msg} =
             Errors.user_not_found("alice")

    assert msg == "User alice was not found."

    assert %{"code" => "ERR_GUID_NOT_FOUND", "details" => %{"guid" => "room-1"}} =
             Errors.group_not_found("room-1")

    assert %{"code" => "ERR_NOT_A_MEMBER", "details" => %{"guid" => "room-1"}, "message" => msg} =
             Errors.not_member("room-1")

    assert msg == "The logged-in user is not a member of group room-1."

    assert %{
             "code" => "ERR_MESSAGE_NOT_FOUND",
             "details" => %{"id" => "abc"},
             "message" => "Message abc was not found."
           } = Errors.message_not_found("abc")

    assert Errors.forbidden()["code"] == "ERR_FORBIDDEN"

    assert Errors.forbidden("Custom")["message"] == "Custom"
  end

  test "missing/1 reports the offending parameter, and invalid/2 upper-cases it into the code" do
    assert Errors.missing("authToken") == %{
             "code" => "MISSING_PARAMETERS",
             "name" => "MISSING_PARAMETERS",
             "message" => "Missing required parameter: authToken.",
             "details" => %{"parameter" => "authToken"}
           }

    assert Errors.invalid("limit", "Must be positive") == %{
             "code" => "INVALID_LIMIT",
             "name" => "INVALID_LIMIT",
             "message" => "Must be positive",
             "details" => %{"parameter" => "limit"}
           }

    # accepts atoms too via to_string
    assert Errors.invalid(:offset, "x")["code"] == "INVALID_OFFSET"
  end
end
