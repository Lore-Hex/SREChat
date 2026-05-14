defmodule OpenChat.MutationEdgeCaseTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "cannot send message to a deactivated user" do
    Store.ensure_user("active_sender")
    Store.ensure_user("deactivated_receiver")
    Store.delete_user("deactivated_receiver")

    result =
      Store.send_message("active_sender", %{
        "receiver" => "deactivated_receiver",
        "receiverType" => "user",
        "data" => %{"text" => "hello"}
      })

    # This should probably fail
    assert {:error, %{"code" => "ERR_UID_NOT_FOUND"}} = result
  end

  test "cannot send message from a deactivated user (as non-admin)" do
    Store.ensure_user("deactivated_sender")
    Store.delete_user("deactivated_sender")

    result =
      Store.send_message(
        "deactivated_sender",
        %{
          "receiver" => "alice",
          "receiverType" => "user",
          "data" => %{"text" => "hello"}
        },
        [],
        admin?: false
      )

    assert {:error, %{"code" => "ERR_NO_AUTH"}} = result
  end

  test "deleting an already deleted message returns the same action" do
    {:ok, msg} =
      Store.send_message("alice", %{
        "receiver" => "bob",
        "receiverType" => "user",
        "data" => %{"text" => "delete me"}
      })

    {:ok, action1} = Store.delete_message("alice", msg["id"])
    assert action1["data"]["action"] == "deleted"

    # Second delete
    result = Store.delete_message("alice", msg["id"])
    assert {:error, %{"message" => "Deleted messages cannot be edited or deleted."}} = result
  end

  # CometChat parity: a message whose metadata sets `incrementUnreadCount: false`
  # must NOT contribute to the recipient's unread count. Snowy explicitly sets
  # the opposite (`true`) on every custom message, so this test pins both branches.
  test "messages with metadata.incrementUnreadCount=false do not bump unread; true does" do
    # No-bump branch.
    assert {:ok, _silent} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "type" => "custom",
               "category" => "message",
               "data" => %{
                 "customData" => %{"kind" => "silent-notice"},
                 "metadata" => %{"incrementUnreadCount" => false}
               }
             })

    assert {:ok, []} = Store.unread_counts("bob", %{"receiverType" => "user"})

    # Bump branch — snowy's actual production setting.
    assert {:ok, _audible} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "type" => "custom",
               "category" => "message",
               "data" => %{
                 "customData" => %{"kind" => "loud"},
                 "metadata" => %{"incrementUnreadCount" => true}
               }
             })

    assert {:ok, [%{"entityId" => "alice", "count" => 1}]} =
             Store.unread_counts("bob", %{"receiverType" => "user"})

    # Common falsy string the server may see after JSON round-trip.
    assert {:ok, _string_false} =
             Store.send_message("alice", %{
               "receiver" => "bob",
               "receiverType" => "user",
               "type" => "custom",
               "category" => "message",
               "data" => %{
                 "customData" => %{"kind" => "silent-string"},
                 "metadata" => %{"incrementUnreadCount" => "false"}
               }
             })

    assert {:ok, [%{"entityId" => "alice", "count" => 1}]} =
             Store.unread_counts("bob", %{"receiverType" => "user"})
  end
end
