defmodule OpenChat.UserListTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "list_users excludes deactivated users" do
    Store.ensure_user("active_1")
    Store.ensure_user("deactivated_1")
    Store.delete_user("deactivated_1")

    {:ok, users} = Store.list_users()
    uids = Enum.map(users, & &1["uid"])

    assert "active_1" in uids
    refute "deactivated_1" in uids
  end

  test "get_user_for returns deactivated user with offline status" do
    Store.ensure_user("deactivated_2")
    Store.delete_user("deactivated_2")

    assert {:ok, user} = Store.get_user_for("alice", "deactivated_2")
    assert user["uid"] == "deactivated_2"
    assert user["status"] == "offline"
  end
end
