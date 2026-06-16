defmodule OpenChat.StoreRecordsTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.Records
  alias OpenChat.Store.Records.{Ban, Group, Member, Message, Presence, Reaction, User}

  test "user records are typed internally and expose CometChat-shaped maps" do
    record = Records.new_user(%{uid: "typed-user", metadata: ~s({"ageBand":"teen"})})

    assert %User{} = record
    assert record.uid == "typed-user"
    assert record.metadata == %{"ageBand" => "teen"}

    assert Records.to_map(record) == %{
             "uid" => "typed-user",
             "name" => "typed-user",
             "metadata" => %{"ageBand" => "teen"},
             "role" => "default",
             "status" => "available",
             "lastActiveAt" => record.last_active_at,
             "tags" => []
           }
  end

  test "group and member records normalize compatibility aliases" do
    group =
      Records.new_group(%{
        "id" => "typed-room",
        "ownerUid" => "owner",
        "metadata" => ~s({"topic":"math"})
      })

    member = Records.new_member("typed-room", "alice", "members", 123)

    assert %Group{} = group
    assert Records.to_map(group)["guid"] == "typed-room"
    assert Records.to_map(group)["owner"] == "owner"
    assert Records.to_map(group)["metadata"] == %{"topic" => "math"}

    assert %Member{} = member

    assert Records.to_map(member) == %{
             "uid" => "alice",
             "guid" => "typed-room",
             "scope" => "participant",
             "role" => "participant",
             "joinedAt" => 123
           }
  end

  test "moderation, presence, and reaction records expose stable wire maps" do
    ban = Records.new_ban("typed-room", "bad-user", 321)
    presence = Records.new_presence("typed-room", "visitor", 1_000, 60)

    reaction =
      Records.new_reaction(%{
        messageId: 42,
        reaction: "👍",
        uid: "alice",
        reactedAt: 777,
        reactedBy: %{uid: "alice"}
      })

    assert %Ban{} = ban

    assert Records.to_map(ban) == %{
             "uid" => "bad-user",
             "guid" => "typed-room",
             "bannedAt" => 321
           }

    assert %Presence{} = presence

    assert Records.to_map(presence) == %{
             "uid" => "visitor",
             "guid" => "typed-room",
             "lastSeenAt" => 1_000,
             "expiresAt" => 1_060
           }

    assert %Reaction{} = reaction

    assert Records.to_map(reaction) == %{
             "messageId" => 42,
             "reaction" => "👍",
             "uid" => "alice",
             "reactedAt" => 777,
             "reactedBy" => %{"uid" => "alice"}
           }
  end

  test "message records keep domain shape while omitting nil wire fields" do
    message =
      Records.new_message(%{
        id: 42,
        sender: "alice",
        receiver: "bob",
        receiverType: "USER",
        type: "text",
        category: "message",
        data: %{text: "hello"},
        sentAt: 1_700_000_000,
        conversationId: "user_alice_bob"
      })

    assert %Message{} = message

    assert Records.to_map(message) == %{
             "id" => 42,
             "sender" => "alice",
             "receiver" => "bob",
             "receiverType" => "user",
             "type" => "text",
             "category" => "message",
             "data" => %{"text" => "hello"},
             "sentAt" => 1_700_000_000,
             "updatedAt" => 1_700_000_000,
             "conversationId" => "user_alice_bob"
           }
  end

  test "message records preserve optional edit delete parent and tag fields" do
    message =
      Records.message(%{
        "id" => "77",
        "muid" => "client-77",
        "sender" => "alice",
        "receiver" => "room",
        "receiverType" => "group",
        "type" => "text",
        "category" => "message",
        "data" => %{"text" => "thread"},
        "sentAt" => 10,
        "updatedAt" => 11,
        "conversationId" => "group_room",
        "parentMessageId" => "55",
        "tags" => ["staff"],
        "editedAt" => 12,
        "editedBy" => "alice",
        "deletedAt" => 13,
        "deletedBy" => "moderator"
      })

    assert message["parentId"] == "55"
    assert message["tags"] == ["staff"]
    assert message["editedAt"] == 12
    assert message["deletedBy"] == "moderator"
  end

  test "scope normalization accepts CometChat aliases and falls back safely" do
    assert Records.scope("participants") == "participant"
    assert Records.scope("members") == "participant"
    assert Records.scope("coOwner") == "coOwner"
    assert Records.scope("coowner") == "coOwner"
    assert Records.scope("co-owner") == "coOwner"
    assert Records.scope("co_owner") == "coOwner"
    assert Records.scope("mods") == "moderator"
    assert Records.scope("admins") == "admin"
    assert Records.scope("admin") == "admin"
    assert Records.scope("unknown") == "participant"
    assert Records.scope(nil) == "participant"
  end
end
