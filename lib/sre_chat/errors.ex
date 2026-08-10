defmodule SREChat.Errors do
  @moduledoc false

  def error(code, message, details \\ %{}) do
    %{
      "code" => code,
      "name" => code,
      "message" => message,
      "details" => details || %{}
    }
  end

  def not_initialized,
    do: error("NOT_INITIALIZED", "Please call CometChat.init() before calling CometChat methods.")

  def no_auth, do: error("ERR_NO_AUTH", "A valid authToken is required.")

  def user_not_found(uid),
    do: error("ERR_UID_NOT_FOUND", "User #{uid} was not found.", %{"uid" => uid})

  def group_not_found(guid),
    do: error("ERR_GUID_NOT_FOUND", "Group #{guid} was not found.", %{"guid" => guid})

  def not_member(guid),
    do:
      error("ERR_NOT_A_MEMBER", "The logged-in user is not a member of group #{guid}.", %{
        "guid" => guid
      })

  def missing(param),
    do:
      error("MISSING_PARAMETERS", "Missing required parameter: #{param}.", %{"parameter" => param})

  def invalid(param, message),
    do: error("INVALID_#{String.upcase(to_string(param))}", message, %{"parameter" => param})

  def message_not_found(id),
    do: error("ERR_MESSAGE_NOT_FOUND", "Message #{id} was not found.", %{"id" => id})

  def forbidden(message \\ "You are not allowed to perform this operation."),
    do: error("ERR_FORBIDDEN", message)
end
