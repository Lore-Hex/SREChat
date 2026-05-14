defmodule OpenChat.StoreExtendedTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "user blocking and unblocking" do
    {:ok, _} = Store.ensure_user("alice")
    {:ok, _} = Store.ensure_user("bob")
    {:ok, _} = Store.ensure_user("carol")

    {:ok, result} = Store.block_users("alice", ["bob", "carol"])
    assert result["bob"]["success"]
    assert result["carol"]["success"]

    {:ok, blocked, meta} = Store.blocked_users("alice")
    assert length(blocked) == 2
    assert Enum.any?(blocked, &(&1["uid"] == "bob"))
    assert Enum.any?(blocked, &(&1["uid"] == "carol"))
    assert meta["pagination"]["total"] == 2

    # Check blockedByMe direction
    {:ok, blocked, _} = Store.blocked_users("alice", %{"direction" => "blockedByMe"})
    assert length(blocked) == 2

    # Check hasBlockedMe direction
    {:ok, blocked, _} = Store.blocked_users("bob", %{"direction" => "hasBlockedMe"})
    assert length(blocked) == 1
    assert List.first(blocked)["uid"] == "alice"

    # Unblock
    {:ok, result} = Store.unblock_users("alice", ["bob"])
    assert result["bob"]["success"]

    {:ok, blocked, _} = Store.blocked_users("alice")
    assert length(blocked) == 1
    assert List.first(blocked)["uid"] == "carol"
  end

  test "group deletion cleans up members and messages" do
    {:ok, _} = Store.join_group("lobby", "alice")

    {:ok, msg} =
      Store.send_message("alice", %{
        "receiver" => "lobby",
        "receiverType" => "group",
        "type" => "text",
        "data" => %{"text" => "hello"}
      })

    assert {:ok, _} = Store.get_group("lobby")
    assert {:ok, _} = Store.get_message(msg["id"])

    {:ok, result} = Store.delete_group("lobby")
    assert result["success"]

    assert :error = Store.get_group("lobby")
    assert :error = Store.get_message(msg["id"])

    assert {:error, %{"code" => "ERR_GUID_NOT_FOUND"}} = Store.group_members("lobby")
  end

  test "searching users and groups" do
    {:ok, _} = Store.upsert_user(%{"uid" => "user_abc", "name" => "Apple"})
    {:ok, _} = Store.upsert_user(%{"uid" => "user_def", "name" => "Banana"})

    {:ok, users} = Store.list_users(%{"search" => "Apple"})
    assert length(users) == 1
    assert List.first(users)["name"] == "Apple"

    {:ok, users} = Store.list_users(%{"search" => "user_"})
    assert length(users) >= 2

    {:ok, _} = Store.upsert_group(%{"guid" => "group_abc", "name" => "Cherry"})
    {:ok, groups} = Store.list_groups(%{"search" => "Cherry"})
    assert length(groups) == 1
  end

  test "pagination" do
    # Create 50 users
    Enum.each(1..50, fn i ->
      Store.ensure_user("user_#{i}")
    end)

    {:ok, users} = Store.list_users(%{"limit" => "10"})
    assert length(users) == 10
  end

  test "banning and unbanning group members" do
    {:ok, _} = Store.join_group("lobby", "alice")
    {:ok, _} = Store.ban_group_member("lobby", "alice")

    {:ok, banned} = Store.banned_group_members("lobby")
    assert Enum.any?(banned, &(&1["uid"] == "alice"))

    # Alice should not be able to join anymore
    assert {:error, %{"code" => "ERR_FORBIDDEN"}} = Store.join_group("lobby", "alice")

    {:ok, _} = Store.unban_group_member("lobby", "alice")
    {:ok, _} = Store.join_group("lobby", "alice")
    assert {:ok, _} = Store.get_group("lobby")
  end
end
