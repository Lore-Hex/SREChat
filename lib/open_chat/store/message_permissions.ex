defmodule OpenChat.Store.MessagePermissions do
  @moduledoc false

  alias OpenChat.Errors
  alias OpenChat.Store.GroupPermissions

  def authorize(state, actor_uid, message, action, opts \\ []) do
    actor_uid = to_s(actor_uid)

    cond do
      Keyword.get(opts, :admin?, false) ->
        :ok

      blank?(actor_uid) ->
        forbidden(action)

      action == :edit and action_message?(message) ->
        Errors.forbidden("Action messages cannot be edited.")

      deleted?(message) ->
        Errors.forbidden("Deleted messages cannot be edited or deleted.")

      message_sender?(message, actor_uid) ->
        :ok

      group_moderator?(state, message, actor_uid) ->
        :ok

      true ->
        forbidden(action)
    end
    |> case do
      :ok -> :ok
      error -> {:error, error}
    end
  end

  defp forbidden(:edit),
    do: Errors.forbidden("You can edit only your own messages unless you moderate the group.")

  defp forbidden(:delete),
    do: Errors.forbidden("You can delete only your own messages unless you moderate the group.")

  defp action_message?(message), do: message["category"] == "action"
  defp deleted?(message), do: not blank?(message["deletedAt"])
  defp message_sender?(message, uid), do: to_s(message["sender"]) == uid

  defp group_moderator?(state, %{"receiverType" => "group", "receiver" => guid}, uid) do
    GroupPermissions.can_moderate?(state, guid, uid)
  end

  defp group_moderator?(_state, _message, _uid), do: false

  defp blank?(value), do: value in [nil, "", false]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
