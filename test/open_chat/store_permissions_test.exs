defmodule OpenChat.Store.PermissionsTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.{Access, GroupPermissions, MessagePermissions, State}

  describe "GroupPermissions.can_moderate?/3" do
    test "owners and elevated member scopes pass" do
      state =
        State.default()
        |> put_in(["groups", "room"], %{"owner" => "alice"})
        |> put_in(["members", "room"], %{
          "alice" => %{},
          "mod" => %{"scope" => "moderator"},
          "admin" => %{"role" => "admin"},
          "co" => %{"scope" => "coOwner"},
          "plain" => %{}
        })

      assert GroupPermissions.can_moderate?(state, "room", "alice")
      assert GroupPermissions.can_moderate?(state, "room", "mod")
      assert GroupPermissions.can_moderate?(state, "room", "admin")
      assert GroupPermissions.can_moderate?(state, "room", "co")
      refute GroupPermissions.can_moderate?(state, "room", "plain")
    end

    test "rejects blank uids and missing groups" do
      state = put_in(State.default(), ["members", "room"], %{"alice" => %{}})

      refute GroupPermissions.can_moderate?(state, "room", "")
      refute GroupPermissions.can_moderate?(state, "room", nil)
      refute GroupPermissions.can_moderate?(state, "missing", "alice")
    end

    test "honors ownerUid and ownerUuid aliases" do
      uid_owned =
        State.default()
        |> put_in(["groups", "room"], %{"ownerUid" => "alice"})

      uuid_owned =
        State.default()
        |> put_in(["groups", "room"], %{"ownerUuid" => "bob"})

      assert GroupPermissions.can_moderate?(uid_owned, "room", "alice")
      assert GroupPermissions.can_moderate?(uuid_owned, "room", "bob")
    end
  end

  describe "MessagePermissions.authorize/5" do
    test "admin? bypass returns :ok even for non-participants" do
      assert :ok =
               MessagePermissions.authorize(
                 State.default(),
                 "stranger",
                 %{"sender" => "alice"},
                 :delete,
                 admin?: true
               )
    end

    test "senders may edit and delete their own messages" do
      message = %{"sender" => "alice", "receiverType" => "user"}
      assert :ok = MessagePermissions.authorize(State.default(), "alice", message, :edit)
      assert :ok = MessagePermissions.authorize(State.default(), "alice", message, :delete)
    end

    test "group moderators can edit and delete other members' messages" do
      state = put_in(State.default(), ["groups", "room"], %{"owner" => "mod"})

      message = %{"sender" => "alice", "receiverType" => "group", "receiver" => "room"}

      assert :ok = MessagePermissions.authorize(state, "mod", message, :delete)
    end

    test "non-senders without moderator rights are forbidden with action-specific messages" do
      message = %{"sender" => "alice", "receiverType" => "user", "receiver" => "bob"}

      assert {:error, %{"code" => "ERR_FORBIDDEN", "message" => edit_msg}} =
               MessagePermissions.authorize(State.default(), "bob", message, :edit)

      assert {:error, %{"message" => delete_msg}} =
               MessagePermissions.authorize(State.default(), "bob", message, :delete)

      assert edit_msg =~ "edit only your own"
      assert delete_msg =~ "delete only your own"
    end

    test "blank actors and missing actors are forbidden" do
      assert {:error, _} =
               MessagePermissions.authorize(State.default(), "", %{"sender" => "alice"}, :edit)

      assert {:error, _} =
               MessagePermissions.authorize(State.default(), nil, %{"sender" => "alice"}, :delete)
    end

    test "action messages cannot be edited but follow delete permissions" do
      action_msg = %{"sender" => "alice", "category" => "action", "receiverType" => "user"}

      assert {:error, %{"message" => "Action messages cannot be edited."}} =
               MessagePermissions.authorize(State.default(), "alice", action_msg, :edit)

      assert :ok = MessagePermissions.authorize(State.default(), "alice", action_msg, :delete)

      assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
               MessagePermissions.authorize(State.default(), "bob", action_msg, :delete)
    end

    test "group moderators can delete action messages" do
      state =
        State.default()
        |> put_in(["groups", "room"], %{"owner" => "owner"})
        |> put_in(["members", "room"], %{
          "mod" => %{"scope" => "moderator"},
          "participant" => %{"scope" => "participant"}
        })

      action_msg = %{
        "sender" => "system",
        "category" => "action",
        "receiverType" => "group",
        "receiver" => "room"
      }

      assert :ok = MessagePermissions.authorize(state, "owner", action_msg, :delete)
      assert :ok = MessagePermissions.authorize(state, "mod", action_msg, :delete)

      assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
               MessagePermissions.authorize(state, "participant", action_msg, :delete)
    end

    test "already-deleted messages can never be edited or deleted" do
      deleted_msg = %{"sender" => "alice", "deletedAt" => "2026-01-01T00:00:00Z"}

      assert {:error, %{"message" => "Deleted messages cannot be edited or deleted."}} =
               MessagePermissions.authorize(State.default(), "alice", deleted_msg, :delete)
    end
  end

  describe "Access.message/4" do
    test "admin override always permits the message" do
      assert :ok =
               Access.message(
                 State.default(),
                 "outsider",
                 %{"sender" => "alice", "receiver" => "bob", "receiverType" => "user"},
                 admin?: true
               )
    end

    test "direct messages permit only the sender and receiver" do
      message = %{"sender" => "alice", "receiver" => "bob", "receiverType" => "user"}

      assert :ok = Access.message(State.default(), "alice", message)
      assert :ok = Access.message(State.default(), "bob", message)
      assert {:error, _} = Access.message(State.default(), "carol", message)
    end

    test "group messages permit members and moderators" do
      state =
        State.default()
        |> put_in(["groups", "room"], %{"owner" => "mod"})
        |> put_in(["members", "room"], %{"alice" => %{}})

      message = %{"sender" => "alice", "receiver" => "room", "receiverType" => "group"}

      assert :ok = Access.message(state, "alice", message)
      assert :ok = Access.message(state, "mod", message)
      assert {:error, _} = Access.message(state, "outsider", message)
    end

    test "blank uids are forbidden" do
      assert {:error, _} =
               Access.message(State.default(), "", %{
                 "sender" => "alice",
                 "receiverType" => "user",
                 "receiver" => "bob"
               })
    end
  end

  describe "Access.conversation/5" do
    test "user conversations are open to any authenticated user" do
      assert :ok = Access.conversation(State.default(), "stranger", "user", "alice")
    end

    test "group conversations require membership or moderator role" do
      state = put_in(State.default(), ["members", "room"], %{"alice" => %{}})

      assert :ok = Access.conversation(state, "alice", "group", "room")
      assert {:error, _} = Access.conversation(state, "outsider", "group", "room")
    end

    test "admin? overrides membership checks and blank receivers are forbidden" do
      assert :ok = Access.conversation(State.default(), "x", "group", "room", admin?: true)
      assert {:error, _} = Access.conversation(State.default(), "alice", "group", "")
      assert {:error, _} = Access.conversation(State.default(), "", "user", "bob")
    end
  end

  describe "Access.receipt/6" do
    test "receipts at the start of a conversation are accepted without a message lookup" do
      assert :ok = Access.receipt(State.default(), "alice", "user", "bob", "0")
      assert :ok = Access.receipt(State.default(), "alice", "user", "bob", nil)
    end

    test "receipts must reference a message in the matching conversation" do
      conv_id = "user_alice_bob"

      state =
        put_in(State.default(), ["messages"], %{
          "1" => %{
            "id" => "1",
            "sender" => "alice",
            "receiver" => "bob",
            "receiverType" => "user",
            "conversationId" => conv_id
          },
          "2" => %{
            "id" => "2",
            "sender" => "carol",
            "receiver" => "dave",
            "receiverType" => "user",
            "conversationId" => "user_carol_dave"
          }
        })

      assert :ok = Access.receipt(state, "alice", "user", "bob", "1")

      assert {:error, %{"code" => "ERR_MESSAGE_NOT_FOUND"}} =
               Access.receipt(state, "alice", "user", "bob", "missing")

      assert {:error, %{"code" => "ERR_FORBIDDEN", "message" => msg}} =
               Access.receipt(state, "alice", "user", "bob", "2")

      assert msg =~ "Receipts can only target messages"
    end
  end

  describe "Access.parent_message/5" do
    test "nil and blank parent ids are accepted" do
      assert :ok = Access.parent_message(State.default(), "alice", nil, "conv", [])
      assert :ok = Access.parent_message(State.default(), "alice", "", "conv", [])
    end

    test "parents must exist and stay in the requested conversation" do
      conv_id = "group_room"

      state =
        State.default()
        |> put_in(["members", "room"], %{"alice" => %{}})
        |> put_in(["messages"], %{
          "10" => %{
            "id" => "10",
            "receiver" => "room",
            "receiverType" => "group",
            "conversationId" => conv_id
          },
          "11" => %{
            "id" => "11",
            "receiver" => "room",
            "receiverType" => "group",
            "conversationId" => "different"
          }
        })

      assert :ok = Access.parent_message(state, "alice", "10", conv_id, [])

      assert {:error, %{"code" => "ERR_MESSAGE_NOT_FOUND"}} =
               Access.parent_message(state, "alice", "missing", conv_id, [])

      assert {:error, %{"code" => "ERR_FORBIDDEN", "message" => msg}} =
               Access.parent_message(state, "alice", "11", conv_id, [])

      assert msg =~ "Thread replies must stay in the parent message conversation."
    end
  end
end
