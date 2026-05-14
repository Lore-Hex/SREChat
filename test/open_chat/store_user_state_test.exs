defmodule OpenChat.StoreUserStateTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.{State, UserState}

  test "ensure creates a normalised user once and preserves existing records" do
    {alice, state} = UserState.ensure(State.default(), :alice)

    assert alice["uid"] == "alice"
    assert alice["name"] == "alice"
    assert get_in(state, ["users", "alice"]) == alice

    updated = Map.put(alice, "name", "Alice")
    state = UserState.put(state, updated)

    assert {^updated, ^state} = UserState.ensure(state, "alice")
  end

  test "public views strip auth tokens and include viewer block state" do
    user = UserState.normalise(%{"uid" => "bob", "authToken" => "secret"})

    state =
      State.default()
      |> UserState.put(user)
      |> put_in(["blocks", "alice"], %{"bob" => true})
      |> put_in(["blocks", "bob"], %{"alice" => true})

    assert {:ok, public} = UserState.fetch_public(state, "alice", "bob")
    refute Map.has_key?(public, "authToken")
    assert public["blockedByMe"] == true
    assert public["hasBlockedMe"] == true
  end

  test "embedded tokens and default users are behind the user state boundary" do
    state =
      State.default()
      |> UserState.maybe_store_embedded_token(%{"uid" => "alice", "authToken" => "tok"})

    assert get_in(state, ["tokens", "tok"]) == "alice"
    assert state == UserState.maybe_store_embedded_token(state, %{"uid" => "bob"})

    fallback = UserState.get_or_default(state, :missing)
    assert fallback["uid"] == "missing"
    assert fallback["name"] == "missing"
  end

  test "missing users return the same not-found shape as the Store API" do
    assert UserState.fetch_public(State.default(), nil, "missing") == :error
  end
end
