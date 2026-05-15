defmodule OpenChat.StoreRequestPlanTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store.{AuthTokens, Conversations, RequestPlan}

  test "message writes lock one conversation and refresh only touched records" do
    conversation_id = Conversations.user_conversation_id("plan-a", "plan-b")

    plan =
      RequestPlan.build(
        {:send_message, "plan-a",
         %{"receiver" => "plan-b", "receiverType" => "user", "data" => %{"text" => "hi"}}, [], []}
      )

    assert plan.mutating?
    assert plan.locks == [{:conversation, conversation_id}]

    assert plan.refresh == [
             {"users", "plan-a"},
             {:counter, "next_id"},
             {"conversation_messages", conversation_id},
             {"conversation_latest", conversation_id},
             {"unread_counts", "plan-a"},
             {"unread_counts", "plan-b"},
             {"users", "plan-b"}
           ]
  end

  test "uid token auth plans both token and user keys" do
    plan = RequestPlan.build({:me, "uid:plan-user"})

    assert plan.mutating?
    assert plan.locks == [{:token, "uid:plan-user"}, {:user, "plan-user"}]
    assert plan.refresh == [{"users", "plan-user"}, {"tokens", "uid:plan-user"}]
  end

  test "group membership actions reserve message IDs through the shared counter" do
    join_plan = RequestPlan.build({:join_group, "plan-room", "plan-user", %{}})
    leave_plan = RequestPlan.build({:leave_group, "plan-room", "plan-user"})

    assert join_plan.mutating?

    assert join_plan.refresh == [
             {"groups", "plan-room"},
             {"members", "plan-room"},
             {"banned", "plan-room"},
             {"users", "plan-user"},
             {"user_groups", "plan-user"},
             {"unread_counts", "plan-user"},
             {:counter, "next_id"}
           ]

    assert leave_plan.mutating?

    assert leave_plan.refresh == [
             {"groups", "plan-room"},
             {"members", "plan-room"},
             {"banned", "plan-room"},
             {"user_groups", "plan-user"},
             {"unread_counts", "plan-user"},
             {:counter, "next_id"}
           ]
  end

  test "local JWT auth plans against the underlying token" do
    jwt = AuthTokens.local_jwt("jwt-plan-user", "uid:jwt-plan-user")

    plan = RequestPlan.build({:authenticate, jwt})

    assert plan.mutating?
    assert plan.locks == [{:token, "uid:jwt-plan-user"}, {:user, "jwt-plan-user"}]
    assert plan.refresh == [{"users", "jwt-plan-user"}, {"tokens", "uid:jwt-plan-user"}]
  end

  test "opaque auth tokens follow up by refreshing the mapped user key" do
    state = %{"tokens" => %{"opaque-plan-token" => "mapped-plan-user"}}

    assert RequestPlan.followup_refresh({:me, "opaque-plan-token"}, state) == [
             {"users", "mapped-plan-user"}
           ]
  end

  test "read plans do not take Redis locks" do
    plan = RequestPlan.build({:get_message, "123"})

    refute plan.mutating?
    assert plan.locks == []
    assert plan.refresh == [{"messages", "123"}, {"reactions", "123"}]
  end

  test "legacy extension reaction toggle takes the same lock as native reactions" do
    plan = RequestPlan.build({:toggle_reaction, "alice", "123", "🔥"})

    assert plan.mutating?
    assert plan.locks == [{:message, "123"}]

    assert plan.refresh == [
             {"messages", "123"},
             {"reactions", "123"},
             {"users", "alice"},
             {:counter, "next_reaction_id"}
           ]
  end

  test "message action follow-up refresh covers actor and group moderator records" do
    state = %{
      "messages" => %{
        "42" => %{
          "sender" => "sender",
          "receiverType" => "group",
          "receiver" => "room",
          "conversationId" => "group_room"
        }
      }
    }

    assert RequestPlan.followup_refresh({:delete_message, "moderator", "42", []}, state) == [
             {"users", "moderator"},
             {"users", "sender"},
             {"conversation_messages", "group_room"},
             {"conversation_latest", "group_room"},
             {"conversation_users", "group_room"},
             {"unread_counts", "moderator"},
             {"groups", "room"},
             {"members", "room"},
             {"banned", "room"}
           ]
  end

  test "actor-aware read and receipt plans refresh access-control records by key" do
    direct_conversation = Conversations.user_conversation_id("alice", "bob")

    assert RequestPlan.build({:messages_for_thread, "alice", "55", %{}}).refresh == [
             {"messages", "55"},
             {"thread_messages", "55"}
           ]

    assert RequestPlan.build({:find_message_by_muid_for, "alice", "client-muid", []}).refresh == [
             {"message_muids", "client-muid"}
           ]

    assert RequestPlan.build({:mark_read, "alice", "user", "bob", "55"}).refresh == [
             {"conversation_messages", direct_conversation},
             {"conversation_latest", direct_conversation},
             {"users", "bob"},
             {"messages", "55"},
             {"reads", "alice"},
             {"unread_counts", "alice"}
           ]

    assert RequestPlan.build({:mark_delivered, "alice", "group", "room", "77"}).refresh == [
             {"conversation_messages", "group_room"},
             {"conversation_latest", "group_room"},
             {"groups", "room"},
             {"members", "room"},
             {"banned", "room"},
             {"messages", "77"},
             {"delivered", "alice"}
           ]

    assert RequestPlan.build(
             {:send_message, "alice",
              %{
                "receiver" => "bob",
                "receiverType" => "user",
                "parentId" => "55",
                "data" => %{"text" => "reply"}
              }, [], []}
           ).refresh == [
             {"users", "alice"},
             {:counter, "next_id"},
             {"conversation_messages", direct_conversation},
             {"conversation_latest", direct_conversation},
             {"unread_counts", "alice"},
             {"unread_counts", "bob"},
             {"messages", "55"},
             {"users", "bob"}
           ]
  end

  test "broad store requests use indexed refreshes instead of whole-state refreshes" do
    requests = [
      {:list_users, %{}},
      {:blocked_users, "alice", %{"direction" => "hasBlockedMe"}},
      {:list_groups, %{}},
      {:delete_group, "room"},
      {:groups_for_user, "alice"},
      {:get_message_for, "alice", "1", []},
      {:find_message_by_muid, "client-id"},
      {:find_message_by_muid_for, "alice", "client-id", []},
      {:messages_for_thread, "alice", "1", %{}},
      {:mark_read, "alice", "user", "bob", "1"},
      {:mark_delivered, "alice", "user", "bob", "1"},
      {:add_reaction, "alice", "1", "👍"},
      {:reactions, "alice", "1", nil},
      {:unread_counts, "alice", %{}},
      {:conversations, "alice", %{}},
      {:delete_conversation, "user_alice_bob"}
    ]

    for request <- requests do
      plan = RequestPlan.build(request)
      refute :all in plan.refresh
      refute plan.refresh == []
    end

    assert RequestPlan.build({:conversations, "alice", %{}}).refresh == [
             {"user_conversations", "alice"},
             {"user_groups", "alice"},
             {"reads", "alice"},
             {"delivered", "alice"},
             {"hidden_conversations", "alice"},
             {"unread_counts", "alice"}
           ]
  end

  test "delete and group-send plans keep latest-message and unread buckets scoped" do
    delete_conversation = RequestPlan.build({:delete_conversation, "user_alice_bob"})

    assert delete_conversation.mutating?

    assert delete_conversation.refresh == [
             {"conversation_messages", "user_alice_bob"},
             {"conversation_latest", "user_alice_bob"},
             {"conversation_users", "user_alice_bob"},
             {"conversation_messages", "group_user_alice_bob"},
             {"conversation_latest", "group_user_alice_bob"},
             {"conversation_users", "group_user_alice_bob"}
           ]

    assert RequestPlan.build({:delete_group, "room"}).refresh == [
             {"groups", "room"},
             {"members", "room"},
             {"banned", "room"},
             {"conversation_messages", "group_room"},
             {"conversation_latest", "group_room"},
             {"conversation_users", "group_room"}
           ]

    state = %{
      "members" => %{
        "room" => %{
          "alice" => %{"uid" => "alice"},
          "bob" => %{"uid" => "bob"},
          "carol" => %{"uid" => "carol"}
        }
      },
      "conversation_users" => %{"group_room" => ["alice", "bob", "carol"]}
    }

    assert RequestPlan.followup_refresh(
             {:send_message, "alice",
              %{"receiver" => "room", "receiverType" => "group", "data" => %{"text" => "hi"}}, [],
              []},
             state
           ) == [
             {"unread_counts", "alice"},
             {"unread_counts", "bob"},
             {"unread_counts", "carol"}
           ]

    assert RequestPlan.followup_refresh({:delete_conversation, "group_room"}, state) == [
             {"unread_counts", "alice"},
             {"unread_counts", "bob"},
             {"unread_counts", "carol"}
           ]
  end

  test "large group send follow-up refreshes cap unread buckets to the sender" do
    with_open_chat_env(%{group_unread_fanout_limit: 2}, fn ->
      state = %{
        "members" => %{
          "room" => %{
            "alice" => %{"uid" => "alice"},
            "bob" => %{"uid" => "bob"},
            "carol" => %{"uid" => "carol"}
          }
        }
      }

      assert RequestPlan.followup_refresh(
               {:send_message, "alice",
                %{"receiver" => "room", "receiverType" => "group", "data" => %{"text" => "hi"}},
                [], []},
               state
             ) == [{"unread_counts", "alice"}]
    end)
  end

  defp with_open_chat_env(overrides, fun) do
    previous =
      Map.new(overrides, fn {key, _value} ->
        {key, Application.get_env(:open_chat, key)}
      end)

    Enum.each(overrides, fn {key, value} ->
      Application.put_env(:open_chat, key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:open_chat, key)
        {key, value} -> Application.put_env(:open_chat, key, value)
      end)
    end
  end
end
