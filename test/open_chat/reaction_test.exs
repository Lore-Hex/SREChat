defmodule OpenChat.ReactionTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "cannot react to a deleted message" do
    {:ok, msg} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "hello"}
      })

    # Delete message
    {:ok, _} = Store.delete_message("alice", msg["id"])

    # Try to react
    # CometChat might return an error or just ignore it.
    # Usually it's an error.
    assert {:error, _} = Store.add_reaction("bob", msg["id"], "👍")
  end
end
