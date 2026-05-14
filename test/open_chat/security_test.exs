defmodule OpenChat.SecurityTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "deactivated user cannot perform any actions" do
    {:ok, %{"uid" => uid}} = Store.create_auth_token("victim")
    Store.delete_user("victim")

    # Cannot send message
    assert {:error, _} =
             Store.send_message(uid, %{
               "receiver" => "alice",
               "receiverType" => "user",
               "data" => %{"text" => "hi"}
             })

    # Cannot join group
    assert {:error, _} = Store.join_group("lobby", uid)

    # Cannot add reaction
    {:ok, msg} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "react me"}
      })

    assert {:error, _} = Store.add_reaction(uid, msg["id"], "👍")
  end

  test "cannot message or interact with deactivated users" do
    Store.ensure_user("dead_user")
    Store.delete_user("dead_user")

    # Cannot send message to them
    assert {:error, %{"code" => "ERR_UID_NOT_FOUND"}} =
             Store.send_message("alice", %{
               "receiver" => "dead_user",
               "receiverType" => "user",
               "data" => %{"text" => "you there?"}
             })

    # Cannot block them (actually block might be okay, but list_users hides them)
    # CometChat usually doesn't block "not found" users.
  end

  test "soft deleted message interactions" do
    {:ok, msg} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "original"}
      })

    Store.delete_message("alice", msg["id"])

    # Cannot edit
    assert {:error, %{"message" => "Deleted messages cannot be edited or deleted."}} =
             Store.edit_message("alice", msg["id"], %{"data" => %{"text" => "edited"}})

    # Cannot react
    assert {:error, %{"message" => "Cannot react to a deleted message."}} =
             Store.add_reaction("bob", msg["id"], "👍")

    # Cannot unreact
    assert {:error, %{"message" => "Cannot unreact to a deleted message."}} =
             Store.remove_reaction("bob", msg["id"], "👍")
  end
end
