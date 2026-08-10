defmodule SREChat.Store.Access do
  @moduledoc false

  alias SREChat.Errors
  alias SREChat.Store.{Conversations, GroupPermissions}

  def message(state, uid, message, opts \\ []) do
    uid = to_s(uid)

    cond do
      Keyword.get(opts, :admin?, false) ->
        :ok

      blank?(uid) ->
        forbidden()

      direct_message_participant?(message, uid) ->
        :ok

      group_message_participant?(state, message, uid) ->
        :ok

      true ->
        forbidden()
    end
  end

  def conversation(state, uid, receiver_type, receiver_id, opts \\ []) do
    uid = to_s(uid)
    receiver_type = receiver_type |> to_s() |> String.downcase()
    receiver_id = to_s(receiver_id)

    cond do
      Keyword.get(opts, :admin?, false) ->
        :ok

      blank?(uid) or blank?(receiver_id) ->
        forbidden()

      receiver_type == "user" ->
        :ok

      receiver_type == "group" and group_participant?(state, receiver_id, uid) ->
        :ok

      true ->
        forbidden()
    end
  end

  def receipt(state, uid, receiver_type, receiver_id, message_id, opts \\ []) do
    with :ok <- conversation(state, uid, receiver_type, receiver_id, opts) do
      validate_receipt_message(state, uid, receiver_type, receiver_id, message_id, opts)
    end
  end

  def parent_message(_state, _uid, nil, _conversation_id, _opts), do: :ok
  def parent_message(_state, _uid, "", _conversation_id, _opts), do: :ok

  def parent_message(state, uid, parent_id, conversation_id, opts) do
    parent_id = to_s(parent_id)

    case get_in(state, ["messages", parent_id]) do
      nil ->
        {:error, Errors.message_not_found(parent_id)}

      parent ->
        cond do
          to_s(parent["conversationId"]) != to_s(conversation_id) ->
            forbidden("Thread replies must stay in the parent message conversation.")

          true ->
            message(state, uid, parent, opts)
        end
    end
  end

  defp validate_receipt_message(_state, _uid, _receiver_type, _receiver_id, message_id, _opts)
       when message_id in [nil, "", "0", 0],
       do: :ok

  defp validate_receipt_message(state, uid, receiver_type, receiver_id, message_id, opts) do
    receiver_type = receiver_type |> to_s() |> String.downcase()
    conversation_id = Conversations.conversation_id_for(uid, receiver_type, receiver_id)
    message_id = to_s(message_id)

    case get_in(state, ["messages", message_id]) do
      nil ->
        {:error, Errors.message_not_found(message_id)}

      message ->
        cond do
          to_s(message["conversationId"]) != conversation_id ->
            forbidden("Receipts can only target messages in the requested conversation.")

          true ->
            message(state, uid, message, opts)
        end
    end
  end

  defp direct_message_participant?(%{"receiverType" => "user"} = message, uid) do
    uid in [to_s(message["sender"]), to_s(message["receiver"])]
  end

  defp direct_message_participant?(_message, _uid), do: false

  defp group_message_participant?(state, %{"receiverType" => "group", "receiver" => guid}, uid) do
    group_participant?(state, guid, uid)
  end

  defp group_message_participant?(_state, _message, _uid), do: false

  defp group_participant?(state, guid, uid) do
    Map.has_key?(get_in(state, ["members", to_s(guid)]) || %{}, uid) or
      GroupPermissions.can_moderate?(state, guid, uid)
  end

  defp forbidden(message \\ "You can access only conversations you participate in."),
    do: {:error, Errors.forbidden(message)}

  defp blank?(value), do: value in [nil, "", false]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
