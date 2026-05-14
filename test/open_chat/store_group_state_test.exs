defmodule OpenChat.StoreGroupStateTest do
  use ExUnit.Case, async: false

  alias OpenChat.Time
  alias OpenChat.Store.{Conversations, Entities, GroupState, State}

  test "ensure_group creates a public system-owned group and member bucket" do
    state = GroupState.ensure_group(State.default(), :room)

    assert get_in(state, ["groups", "room", "guid"]) == "room"
    assert get_in(state, ["groups", "room", "owner"]) == "system"
    assert get_in(state, ["groups", "room", "type"]) == "public"
    assert get_in(state, ["members", "room"]) == %{}

    assert GroupState.ensure_group(state, "room") == state
  end

  test "add_member indexes membership and materialises unread counts" do
    conv_id = Conversations.group_conversation_id("room")

    state =
      State.default()
      |> put_group("room")
      |> put_in(["presence", "room"], %{"alice" => %{"uid" => "alice"}})
      |> put_in(["conversation_messages", conv_id], ["1", "2"])
      |> put_in(["messages", "1"], group_message(1, conv_id, "owner"))
      |> put_in(["messages", "2"], group_message(2, conv_id, "owner"))
      |> GroupState.add_member("room", "alice", "moderator")

    assert get_in(state, ["members", "room", "alice", "scope"]) == "moderator"
    assert get_in(state, ["user_groups", "alice"]) == ["room"]
    assert get_in(state, ["presence", "room", "alice"]) == nil
    assert get_in(state, ["unread_counts", "alice", conv_id]) == 2
  end

  test "remove_member clears group and unread indexes" do
    conv_id = Conversations.group_conversation_id("room")

    state =
      State.default()
      |> put_group("room")
      |> put_in(["unread_counts", "alice"], %{conv_id => 7})
      |> GroupState.add_member("room", "alice", "participant")
      |> GroupState.remove_member("room", "alice")

    assert get_in(state, ["members", "room", "alice"]) == nil
    assert get_in(state, ["user_groups", "alice"]) == nil
    assert get_in(state, ["unread_counts", "alice", conv_id]) == nil
  end

  test "transient joins require public non-member visitor semantics" do
    with_open_chat_env(%{public_group_joins_as_visits: false}, fn ->
      state = State.default() |> put_group("room")
      group = get_in(state, ["groups", "room"])

      refute GroupState.transient_join?(state, group, "room", "alice", %{})
      assert GroupState.transient_join?(state, group, "room", "alice", %{"visitor" => true})
      refute GroupState.transient_join?(state, group, "room", "alice", %{"durable" => true})

      state = GroupState.add_member(state, "room", "alice", "participant")
      refute GroupState.transient_join?(state, group, "room", "alice", %{"visitor" => true})
    end)
  end

  test "read access respects membership public-read config and bans" do
    state = State.default() |> put_group("room")

    with_open_chat_env(%{public_group_reads_enabled: true}, fn ->
      assert GroupState.read_allowed?(state, "room", "visitor")
      refute GroupState.read_allowed?(state, "room", "")

      banned = put_in(state, ["banned", "room"], %{"visitor" => %{"uid" => "visitor"}})
      refute GroupState.read_allowed?(banned, "room", "visitor")
    end)

    with_open_chat_env(%{public_group_reads_enabled: false}, fn ->
      refute GroupState.read_allowed?(state, "room", "visitor")

      member_state = GroupState.add_member(state, "room", "visitor", "participant")
      assert GroupState.read_allowed?(member_state, "room", "visitor")
    end)
  end

  test "member limits reject only new members over the configured cap" do
    with_open_chat_env(%{group_max_members: 2}, fn ->
      state =
        State.default()
        |> put_group("room")
        |> GroupState.add_member("room", "alice", "participant")
        |> GroupState.add_member("room", "bob", "participant")

      assert GroupState.member_limit_reached?(state, "room", "carol")
      refute GroupState.member_limit_reached?(state, "room", "alice")

      error = GroupState.member_limit_error("room")
      assert error["code"] == "ERR_LIMIT_EXCEEDED"
      assert error["details"]["limit"] == 2
    end)
  end

  test "presence updates purge expired rows and cap large public rooms" do
    now = Time.now()

    with_open_chat_env(%{group_presence_ttl_seconds: 10, group_max_presence: 2}, fn ->
      state =
        State.default()
        |> put_group("room")
        |> put_in(["presence", "room"], %{
          "expired" => %{"uid" => "expired", "lastSeenAt" => now + 10, "expiresAt" => now - 1},
          "recent" => %{"uid" => "recent", "lastSeenAt" => now + 1, "expiresAt" => now + 100},
          "older" => %{"uid" => "older", "lastSeenAt" => now - 1, "expiresAt" => now + 100}
        })
        |> GroupState.mark_presence("room", "alice")

      assert Map.has_key?(get_in(state, ["presence", "room"]), "alice")
      assert Map.has_key?(get_in(state, ["presence", "room"]), "recent")
      refute Map.has_key?(get_in(state, ["presence", "room"]), "older")
      refute Map.has_key?(get_in(state, ["presence", "room"]), "expired")
      assert get_in(state, ["presence", "room", "alice", "expiresAt"]) >= now + 10
    end)
  end

  test "moderation authorization accepts admins and moderators and rejects outsiders" do
    state =
      State.default()
      |> put_group("room", %{"owner" => "owner"})
      |> GroupState.add_member("room", "mod", "moderator")

    assert GroupState.authorize_moderation(state, "room", []) == :ok
    assert GroupState.authorize_moderation(state, "room", admin?: true) == :ok
    assert GroupState.authorize_moderation(state, "room", actor_uid: "owner") == :ok
    assert GroupState.authorize_moderation(state, "room", actor_uid: "mod") == :ok

    assert {:error, %{"code" => "ERR_FORBIDDEN"}} =
             GroupState.authorize_moderation(state, "room", actor_uid: "outsider")
  end

  defp put_group(state, guid, attrs \\ %{}) do
    group = Entities.group(Map.merge(%{"guid" => guid, "type" => "public"}, attrs))

    state
    |> put_in(["groups", guid], group)
    |> GroupState.ensure_member_map(guid)
  end

  defp group_message(id, conv_id, sender) do
    %{
      "id" => id,
      "sender" => sender,
      "receiver" => "room",
      "receiverType" => "group",
      "conversationId" => conv_id,
      "data" => %{}
    }
  end

  defp with_open_chat_env(overrides, fun) do
    old = Map.new(overrides, fn {key, _value} -> {key, Application.get_env(:open_chat, key)} end)

    Enum.each(overrides, fn {key, value} ->
      Application.put_env(:open_chat, key, value)
    end)

    try do
      fun.()
    after
      Enum.each(old, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:open_chat, key),
          else: Application.put_env(:open_chat, key, value)
      end)
    end
  end
end
