defmodule OpenChat.Store.UserState do
  @moduledoc false

  alias OpenChat.Store.{Entities, State}

  @type uid :: String.t()

  @spec ensure(State.t(), term()) :: {map(), State.t()}
  def ensure(state, uid) do
    uid = to_s(uid)

    case State.get_record(state, :users, uid) do
      nil ->
        user = normalise(%{"uid" => uid, "name" => uid})
        {user, State.put_record(state, :users, uid, user)}

      user ->
        {user, state}
    end
  end

  @spec fetch_public(State.t(), uid() | nil, term()) :: {:ok, map()} | :error
  def fetch_public(state, viewer_uid, uid) do
    case State.fetch_record(state, :users, uid) do
      {:ok, user} -> {:ok, public_with_block_state(state, viewer_uid, user)}
      :error -> :error
    end
  end

  @spec get_or_default(State.t(), term()) :: map()
  def get_or_default(state, uid) do
    State.get_record(state, :users, uid) || normalise(%{"uid" => uid})
  end

  @spec put(State.t(), map()) :: State.t()
  def put(state, %{"uid" => uid} = user), do: State.put_record(state, :users, uid, user)

  @spec normalise(map()) :: map()
  def normalise(attrs), do: Entities.user(attrs)

  @spec public(map() | nil) :: map() | nil
  def public(user), do: Entities.public_user(user)

  @spec public_with_block_state(State.t(), uid() | nil, map()) :: map()
  def public_with_block_state(_state, nil, user), do: public(user)

  def public_with_block_state(state, viewer_uid, user) do
    user = public(user)
    target_uid = user["uid"]

    user
    |> Map.put("blockedByMe", blocked?(state, viewer_uid, target_uid))
    |> Map.put("hasBlockedMe", blocked?(state, target_uid, viewer_uid))
  end

  @spec maybe_store_embedded_token(State.t(), map()) :: State.t()
  def maybe_store_embedded_token(state, %{"authToken" => token, "uid" => uid})
      when is_binary(token) and token != "" do
    State.put_record(state, :tokens, token, uid)
  end

  def maybe_store_embedded_token(state, _user), do: state

  @spec blocked?(State.t(), term(), term()) :: boolean()
  def blocked?(state, blocker_uid, blocked_uid),
    do: get_in(state, ["blocks", to_s(blocker_uid), to_s(blocked_uid)]) == true

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
