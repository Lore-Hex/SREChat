defmodule OpenChat.LoadPerfTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias OpenChat.Store
  alias OpenChatWeb.Endpoint

  @moduletag :load
  @reaction_emojis ["👍", "🔥", "🎧", "🎉"]

  setup do
    old_redis_url = Application.get_env(:open_chat, :redis_url)
    Application.put_env(:open_chat, :redis_url, nil)
    restart_store!()

    on_exit(fn ->
      Application.put_env(:open_chat, :redis_url, old_redis_url)
      restart_store!()
    end)

    :ok
  end

  test "store sustains high-volume direct message writes and paginated reads" do
    users = env_int("OPENCHAT_LOAD_USERS", 100)
    messages = env_int("OPENCHAT_LOAD_MESSAGES", 2_000)
    minimum = env_int("OPENCHAT_MIN_STORE_MSG_PER_SEC", 300)

    {sent, seconds} =
      timed(fn ->
        Enum.map(1..messages, fn i ->
          sender = load_user(i, users)
          receiver = load_user(i + 1, users)

          assert {:ok, message} =
                   Store.send_message(sender, %{
                     "receiver" => receiver,
                     "receiverType" => "user",
                     "type" => "text",
                     "data" => %{"text" => "load #{i}"}
                   })

          message
        end)
      end)

    ids = message_ids(sent)
    assert Enum.uniq(ids) == ids
    assert_rate("store direct messages", messages, seconds, minimum)
    assert_direct_histories_recorded(sent)

    assert {:ok, [_ | _]} =
             Store.messages_for_user(load_user(2, users), load_user(1, users), %{"limit" => 100})

    assert {:ok, [_ | _]} = Store.conversations(load_user(1, users), %{"limit" => 50})
  end

  test "concurrent Store writers preserve monotonic IDs under same-conversation contention" do
    concurrency = env_int("OPENCHAT_LOAD_CONCURRENCY", 16)
    per_worker = env_int("OPENCHAT_LOAD_WORKER_MESSAGES", 150)
    total = concurrency * per_worker
    minimum = env_int("OPENCHAT_MIN_CONCURRENT_STORE_MSG_PER_SEC", 200)

    {sent, seconds} =
      timed(fn ->
        concurrent_map(1..total, concurrency, fn i ->
          assert {:ok, message} =
                   Store.send_message("concurrent-store-a", %{
                     "receiver" => "concurrent-store-b",
                     "receiverType" => "user",
                     "type" => "text",
                     "data" => %{"text" => "concurrent store #{i}"}
                   })

          message
        end)
      end)

    ids = message_ids(sent)
    assert length(ids) == total
    assert ids |> MapSet.new() |> MapSet.size() == total
    assert Enum.min(ids) == 1
    assert Enum.max(ids) == total
    assert_rate("concurrent store messages", total, seconds, minimum)
    assert_direct_histories_recorded(sent)
  end

  test "deep conversations keep unread and conversation reads on cursor indexes" do
    messages = env_int("OPENCHAT_LOAD_DEEP_CONVERSATION_MESSAGES", 2_000)
    reads = env_int("OPENCHAT_LOAD_DEEP_CONVERSATION_READS", 600)
    minimum = env_int("OPENCHAT_MIN_DEEP_CURSOR_READ_PER_SEC", 300)

    sent =
      Enum.map(1..messages, fn i ->
        assert {:ok, message} =
                 Store.send_message("deep-cursor-a", %{
                   "receiver" => "deep-cursor-b",
                   "receiverType" => "user",
                   "type" => "text",
                   "data" => %{"text" => "deep #{i}"}
                 })

        message
      end)

    latest_id = List.last(sent)["id"]
    assert_direct_histories_recorded(sent)

    {results, seconds} =
      timed(fn ->
        concurrent_map(1..reads, env_int("OPENCHAT_LOAD_DEEP_READ_CONCURRENCY", 16), fn _i ->
          assert {:ok, [%{"entityId" => "deep-cursor-a", "count" => ^messages}]} =
                   Store.unread_counts("deep-cursor-b")

          assert {:ok, [conversation]} = Store.conversations("deep-cursor-b", %{"limit" => 1})
          assert conversation["latestMessageId"] == to_string(latest_id)
          assert conversation["unreadMessageCount"] == messages
          conversation["latestMessageId"]
        end)
      end)

    assert length(results) == reads
    assert_rate("deep conversation cursor reads", reads * 2, seconds, minimum)
  end

  test "group fanout plus read and delivered receipts keep conversation cursors stable" do
    members = env_int("OPENCHAT_LOAD_GROUP_MEMBERS", 150)
    messages = env_int("OPENCHAT_LOAD_GROUP_MESSAGES", 600)
    minimum = env_int("OPENCHAT_MIN_GROUP_MSG_PER_SEC", 100)
    guid = "load-room"
    uids = Enum.map(1..members, &"group-user-#{&1}")

    assert {:ok, _group} = Store.upsert_group(%{"guid" => guid, "type" => "public"})
    assert {:ok, _members} = Store.add_group_members(guid, uids)

    {sent, seconds} =
      timed(fn ->
        Enum.map(1..messages, fn i ->
          sender = Enum.at(uids, rem(i, members))

          assert {:ok, message} =
                   Store.send_message(sender, %{
                     "receiver" => guid,
                     "receiverType" => "group",
                     "type" => "text",
                     "data" => %{"text" => "group load #{i}"}
                   })

          message
        end)
      end)

    assert_rate("group messages", messages, seconds, minimum)
    last_id = List.last(sent)["id"]
    assert_group_history_recorded(List.first(uids), guid, sent)

    receipt_users = Enum.take(uids, min(members, 100))

    {_receipts, receipt_seconds} =
      timed(fn ->
        concurrent_map(receipt_users, env_int("OPENCHAT_LOAD_RECEIPT_CONCURRENCY", 16), fn uid ->
          assert {:ok, delivered} = Store.mark_delivered(uid, "group", guid, last_id)
          assert {:ok, read} = Store.mark_read(uid, "group", guid, last_id)
          {delivered, read}
        end)
      end)

    assert_rate(
      "group receipt writes",
      length(receipt_users) * 2,
      receipt_seconds,
      env_int("OPENCHAT_MIN_RECEIPT_PER_SEC", 100)
    )

    Enum.each(receipt_users, fn uid ->
      assert {:ok, conversation} = Store.conversation(uid, "group", guid)
      assert conversation["lastDeliveredMessageId"] == to_string(last_id)
      assert conversation["lastReadMessageId"] == to_string(last_id)
    end)
  end

  test "top public room load keeps transient visits, fanout, and history bounded" do
    durable_members = env_int("OPENCHAT_LOAD_TOP_ROOM_DURABLE_MEMBERS", 80)
    visitors = env_int("OPENCHAT_LOAD_TOP_ROOM_VISITORS", 1_000)
    messages = env_int("OPENCHAT_LOAD_TOP_ROOM_MESSAGES", 800)
    retained = env_int("OPENCHAT_LOAD_TOP_ROOM_RETAINED_MESSAGES", 120)
    fanout_limit = env_int("OPENCHAT_LOAD_TOP_ROOM_FANOUT_LIMIT", 20)
    concurrency = env_int("OPENCHAT_LOAD_TOP_ROOM_CONCURRENCY", 32)
    minimum = env_int("OPENCHAT_MIN_TOP_ROOM_OP_PER_SEC", 150)
    guid = "top-public-room"
    member_uids = Enum.map(1..durable_members, &"top-room-member-#{&1}")
    visitor_uids = Enum.map(1..visitors, &"top-room-visitor-#{&1}")

    with_open_chat_env(
      %{
        group_max_members: durable_members,
        group_max_messages: retained,
        group_message_retention_days: 365,
        group_unread_fanout_limit: fanout_limit,
        public_group_reads_enabled: true
      },
      fn ->
        assert {:ok, _group} = Store.upsert_group(%{"guid" => guid, "type" => "public"})
        assert {:ok, _members} = Store.add_group_members(guid, member_uids)

        {_visits, visit_seconds} =
          timed(fn ->
            concurrent_map(visitor_uids, concurrency, fn uid ->
              assert {:ok, view} = Store.join_group(guid, uid, %{"transient" => true})
              assert view["transient"] == true
              view["membersCount"]
            end)
          end)

        assert_rate("top room transient visits", visitors, visit_seconds, minimum)

        assert {:ok, members} = Store.group_members(guid)
        assert length(members) == durable_members
        assert {:ok, []} = Store.groups_for_user(List.first(visitor_uids))

        {sent, message_seconds} =
          timed(fn ->
            concurrent_map(1..messages, concurrency, fn i ->
              sender = Enum.at(member_uids, rem(i, durable_members))

              assert {:ok, message} =
                       Store.send_message(sender, %{
                         "receiver" => guid,
                         "receiverType" => "group",
                         "type" => "text",
                         "data" => %{"text" => "top room #{i}"}
                       })

              message
            end)
          end)

        assert_rate("top room bounded messages", messages, message_seconds, minimum)

        first = Enum.min_by(sent, & &1["id"])
        latest = Enum.max_by(sent, & &1["id"])

        retained_messages =
          sent
          |> Enum.sort_by(&to_int(&1["id"]), :desc)
          |> Enum.take(min(retained, messages))

        if messages > retained do
          assert :error = Store.get_message(first["id"])
        end

        assert_group_history_recorded(List.first(member_uids), guid, retained_messages)

        assert {:ok, messages_page} = Store.messages_for_group(List.first(visitor_uids), guid)
        assert length(messages_page) == min(retained, 30)
        assert List.first(messages_page)["id"] == latest["id"]

        if durable_members > fanout_limit do
          assert {:ok, []} =
                   Store.unread_counts(List.last(member_uids), %{"receiverType" => "group"})
        end
      end
    )
  end

  test "HTTP endpoint sustains message send and fetch load through Plug" do
    messages = env_int("OPENCHAT_LOAD_HTTP_MESSAGES", 500)
    minimum = env_int("OPENCHAT_MIN_HTTP_MSG_PER_SEC", 100)

    {sent, seconds} =
      timed(fn ->
        Enum.map(1..messages, fn i ->
          body = %{
            "receiver" => "http-load-b",
            "receiverType" => "user",
            "type" => "text",
            "data" => %{"text" => "http #{i}"}
          }

          response =
            conn(:post, "/v3.0/messages", Jason.encode!(body))
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("authtoken", "uid:http-load-a")
            |> Endpoint.call([])

          assert response.status == 201
          get_in(Jason.decode!(response.resp_body), ["data"])
        end)
      end)

    assert_rate("HTTP messages", messages, seconds, minimum)
    ids = message_ids(sent)
    assert ids |> MapSet.new() |> MapSet.size() == messages
    assert_http_user_history_recorded("uid:http-load-b", "http-load-a", sent)

    response =
      conn(:get, "/v3.0/users/http-load-a/messages?limit=100")
      |> Plug.Conn.put_req_header("authtoken", "uid:http-load-b")
      |> Endpoint.call([])

    assert response.status == 200
    assert %{"data" => [_ | _]} = Jason.decode!(response.resp_body)
  end

  test "concurrent HTTP endpoint load preserves unique message IDs" do
    concurrency = env_int("OPENCHAT_LOAD_HTTP_CONCURRENCY", 12)
    per_worker = env_int("OPENCHAT_LOAD_HTTP_WORKER_MESSAGES", 50)
    total = concurrency * per_worker
    minimum = env_int("OPENCHAT_MIN_CONCURRENT_HTTP_MSG_PER_SEC", 100)

    {sent, seconds} =
      timed(fn ->
        concurrent_map(1..total, concurrency, fn i ->
          body = %{
            "receiver" => "http-concurrent-b",
            "receiverType" => "user",
            "type" => "text",
            "data" => %{"text" => "http concurrent #{i}"}
          }

          response =
            conn(:post, "/v3.0/messages", Jason.encode!(body))
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("authtoken", "uid:http-concurrent-a")
            |> Endpoint.call([])

          assert response.status == 201
          get_in(Jason.decode!(response.resp_body), ["data"])
        end)
      end)

    ids = message_ids(sent)
    assert length(ids) == total
    assert ids |> MapSet.new() |> MapSet.size() == total
    assert_rate("concurrent HTTP messages", total, seconds, minimum)
    assert_http_user_history_recorded("uid:http-concurrent-b", "http-concurrent-a", sent)
  end

  test "HTTP auth-token history load preserves visibility under concurrent reads" do
    with_redis(fn _context ->
      messages = env_int("OPENCHAT_LOAD_HTTP_AUTH_MESSAGES", 300)
      reads = env_int("OPENCHAT_LOAD_HTTP_AUTH_READS", 120)
      concurrency = env_int("OPENCHAT_LOAD_HTTP_AUTH_READ_CONCURRENCY", 24)
      min_send_rate = env_int("OPENCHAT_MIN_HTTP_AUTH_MSG_PER_SEC", 20)
      min_read_rate = env_int("OPENCHAT_MIN_HTTP_AUTH_READ_PER_SEC", 20)
      max_read_p95_ms = env_int("OPENCHAT_MAX_HTTP_AUTH_HISTORY_P95_MS", 750)

      sender = "http-auth-load-a"
      receiver = "http-auth-load-b"
      {:ok, _sender} = Store.upsert_user(%{"uid" => sender, "name" => sender})
      {:ok, _receiver} = Store.upsert_user(%{"uid" => receiver, "name" => receiver})
      {:ok, %{"authToken" => sender_token}} = Store.create_auth_token(sender)
      {:ok, %{"authToken" => receiver_token}} = Store.create_auth_token(receiver)

      {sent, send_seconds} =
        timed(fn ->
          Enum.map(1..messages, fn i ->
            body = %{
              "receiver" => receiver,
              "receiverType" => "user",
              "type" => "text",
              "data" => %{"text" => "http auth #{i}"}
            }

            {response, _ms} =
              timed_conn(fn ->
                conn(:post, "/v3.0/messages", Jason.encode!(body))
                |> Plug.Conn.put_req_header("content-type", "application/json")
                |> Plug.Conn.put_req_header("authtoken", sender_token)
                |> Endpoint.call([])
              end)

            assert response.status == 201
            get_in(Jason.decode!(response.resp_body), ["data"])
          end)
        end)

      expected_ids =
        sent
        |> Enum.take(-100)
        |> Enum.map(&to_s(&1["id"]))
        |> MapSet.new()

      {read_pages, read_seconds} =
        timed(fn ->
          concurrent_map(1..reads, concurrency, fn _i ->
            {response, ms} =
              timed_conn(fn ->
                conn(:get, "/v3.0/users/#{sender}/messages?limit=100")
                |> Plug.Conn.put_req_header("authtoken", receiver_token)
                |> Endpoint.call([])
              end)

            assert response.status == 200
            page = get_in(Jason.decode!(response.resp_body), ["data"])
            ids = page |> Enum.map(&to_s(&1["id"])) |> MapSet.new()
            assert MapSet.subset?(expected_ids, ids)
            {length(page), ms}
          end)
        end)

      read_latencies_ms = Enum.map(read_pages, fn {_count, ms} -> ms end)
      read_p95_ms = percentile(read_latencies_ms, 0.95)

      assert_rate("HTTP auth-token messages", messages, send_seconds, min_send_rate)
      assert_rate("HTTP auth-token history reads", reads, read_seconds, min_read_rate)
      IO.puts("HTTP auth-token history p95: #{Float.round(read_p95_ms, 1)}ms")
      assert read_p95_ms <= max_read_p95_ms
    end)
  end

  test "concurrent reaction load preserves rows, summaries, extension metadata, and history" do
    users = env_int("OPENCHAT_LOAD_REACTION_USERS", 36)
    messages = env_int("OPENCHAT_LOAD_REACTION_MESSAGES", 30)
    concurrency = env_int("OPENCHAT_LOAD_REACTION_CONCURRENCY", 24)
    minimum = env_int("OPENCHAT_MIN_REACTION_OP_PER_SEC", 100)
    guid = "reaction-load-room"
    uids = Enum.map(1..users, &"reaction-user-#{&1}")
    viewer = List.first(uids)

    sent = create_reaction_room_messages(guid, uids, messages, "reaction load")
    ops = reaction_ops(sent, uids, @reaction_emojis)

    {_added, add_seconds} =
      timed(fn ->
        concurrent_map(ops, concurrency, fn op ->
          assert {:ok, _message} = Store.add_reaction(op.uid, op.message_id, op.reaction)
          op
        end)
      end)

    assert_rate("reaction adds", length(ops), add_seconds, minimum)
    assert_group_reaction_state(OpenChat.Store, viewer, guid, sent, ops)

    remove_ops = Enum.filter(ops, &(rem(&1.index, 5) == 0))

    {_removed, remove_seconds} =
      timed(fn ->
        concurrent_map(remove_ops, concurrency, fn op ->
          assert {:ok, _message} = Store.remove_reaction(op.uid, op.message_id, op.reaction)
          op
        end)
      end)

    after_remove = reaction_ops_minus(ops, remove_ops)
    assert_rate("reaction removes", length(remove_ops), remove_seconds, minimum)
    assert_group_reaction_state(OpenChat.Store, viewer, guid, sent, after_remove)

    toggle_remove_ops = Enum.filter(after_remove, &(rem(&1.index, 7) == 0))
    toggle_add_ops = alternate_reaction_ops(sent, uids, "🚀", 4)

    {_toggled, toggle_seconds} =
      timed(fn ->
        concurrent_map(toggle_remove_ops ++ toggle_add_ops, concurrency, fn op ->
          assert {:ok, _message} = Store.toggle_reaction(op.uid, op.message_id, op.reaction)
          op
        end)
      end)

    final_ops =
      after_remove
      |> reaction_ops_minus(toggle_remove_ops)
      |> Kernel.++(toggle_add_ops)

    assert_rate(
      "reaction toggles",
      length(toggle_remove_ops) + length(toggle_add_ops),
      toggle_seconds,
      minimum
    )

    assert_group_reaction_state(OpenChat.Store, viewer, guid, sent, final_ops)
  end

  test "Redis write-through load uses scoped refresh and monotonic counters" do
    with_redis(fn context ->
      messages = env_int("OPENCHAT_LOAD_REDIS_MESSAGES", 300)
      minimum = env_int("OPENCHAT_MIN_REDIS_MSG_PER_SEC", 20)

      Redix.command!(context.redis, ["SET", redis_key(context, "counter", "next_id"), "10"])

      {sent, seconds} =
        timed(fn ->
          Enum.map(1..messages, fn i ->
            sender = "redis-load-#{rem(i, 20)}"
            receiver = "redis-load-#{rem(i + 1, 20)}"

            assert {:ok, message} =
                     Store.send_message(sender, %{
                       "receiver" => receiver,
                       "receiverType" => "user",
                       "type" => "text",
                       "data" => %{"text" => "redis #{i}"}
                     })

            message
          end)
        end)

      ids = message_ids(sent)
      assert Enum.uniq(ids) == ids
      assert Enum.min(ids) >= 10
      assert redis_get(context, "counter", "next_id") == to_string(Enum.max(ids) + 1)
      assert_direct_histories_recorded(sent)
      assert_redis_messages_recorded(context, sent)
      assert_rate("Redis messages", messages, seconds, minimum)
    end)
  end

  test "concurrent Redis write-through load preserves counters and per-key indexes" do
    with_redis(fn context ->
      concurrency = env_int("OPENCHAT_LOAD_REDIS_CONCURRENCY", 8)
      per_worker = env_int("OPENCHAT_LOAD_REDIS_WORKER_MESSAGES", 60)
      total = concurrency * per_worker
      minimum = env_int("OPENCHAT_MIN_CONCURRENT_REDIS_MSG_PER_SEC", 20)

      Redix.command!(context.redis, ["SET", redis_key(context, "counter", "next_id"), "100"])

      {sent, seconds} =
        timed(fn ->
          concurrent_map(1..total, concurrency, fn i ->
            lane = rem(i, concurrency)

            assert {:ok, message} =
                     Store.send_message("redis-concurrent-#{lane}-a", %{
                       "receiver" => "redis-concurrent-#{lane}-b",
                       "receiverType" => "user",
                       "type" => "text",
                       "data" => %{"text" => "redis concurrent #{i}"}
                     })

            message
          end)
        end)

      ids = message_ids(sent)
      assert length(ids) == total
      assert ids |> MapSet.new() |> MapSet.size() == total
      assert Enum.min(ids) >= 100
      assert redis_get(context, "counter", "next_id") == to_string(Enum.max(ids) + 1)
      assert length(redis_members(context, "index", "messages")) == total
      assert_direct_histories_recorded(sent)
      assert_redis_messages_recorded(context, sent)
      assert_rate("concurrent Redis messages", total, seconds, minimum)
    end)
  end

  test "concurrent Redis write-through across peer stores scales on independent conversations" do
    with_redis(fn context ->
      peer = start_peer_store!()

      try do
        lanes = env_int("OPENCHAT_LOAD_REDIS_PEER_LANES", 16)
        concurrency = env_int("OPENCHAT_LOAD_REDIS_PEER_CONCURRENCY", 10)
        per_lane = env_int("OPENCHAT_LOAD_REDIS_PEER_MESSAGES_PER_LANE", 20)
        total = lanes * per_lane
        minimum = env_int("OPENCHAT_MIN_REDIS_PEER_MSG_PER_SEC", 20)

        Redix.command!(context.redis, ["SET", redis_key(context, "counter", "next_id"), "500"])

        {sent, seconds} =
          timed(fn ->
            concurrent_map(1..total, concurrency, fn i ->
              lane = rem(i, lanes)
              sender = "redis-peer-#{lane}-a"
              receiver = "redis-peer-#{lane}-b"

              if rem(i, 2) == 0 do
                assert {:ok, message} =
                         Store.send_message(sender, %{
                           "receiver" => receiver,
                           "receiverType" => "user",
                           "type" => "text",
                           "data" => %{"text" => "primary peer #{i}"}
                         })

                message
              else
                assert {:ok, message} =
                         Store.call_on(
                           peer,
                           {:send_message, sender,
                            %{
                              "receiver" => receiver,
                              "receiverType" => "user",
                              "type" => "text",
                              "data" => %{"text" => "peer #{i}"}
                            }, [], []}
                         )

                message
              end
            end)
          end)

        ids = message_ids(sent)
        assert length(ids) == total
        assert ids |> MapSet.new() |> MapSet.size() == total
        assert redis_get(context, "counter", "next_id") == to_string(Enum.max(ids) + 1)
        assert length(redis_members(context, "index", "messages")) == total
        assert_direct_histories_recorded(sent)
        assert_direct_histories_recorded(peer, sent)
        assert_redis_messages_recorded(context, sent)
        assert_rate("Redis peer store messages", total, seconds, minimum)
      after
        stop_peer_store(peer)
      end
    end)
  end

  test "mixed Redis peer writes and cursor reads keep unread indexes hot" do
    with_redis(fn _context ->
      peer = start_peer_store!()

      try do
        lanes = env_int("OPENCHAT_LOAD_REDIS_MIXED_LANES", 8)
        per_lane = env_int("OPENCHAT_LOAD_REDIS_MIXED_MESSAGES_PER_LANE", 20)
        concurrency = env_int("OPENCHAT_LOAD_REDIS_MIXED_CONCURRENCY", 10)
        total = lanes * per_lane
        minimum = env_int("OPENCHAT_MIN_REDIS_MIXED_OP_PER_SEC", 20)

        {sent, write_seconds} =
          timed(fn ->
            concurrent_map(1..total, concurrency, fn i ->
              lane = rem(i, lanes)
              sender = "redis-mixed-#{lane}-a"
              receiver = "redis-mixed-#{lane}-b"
              request = {:send_message, sender, mixed_message(receiver, i), [], []}

              if rem(i, 2) == 0 do
                assert {:ok, message} = Store.send_message(sender, mixed_message(receiver, i))
                message
              else
                assert {:ok, message} = Store.call_on(peer, request)
                message
              end
            end)
          end)

        {read_results, read_seconds} =
          timed(fn ->
            concurrent_map(0..(lanes - 1), concurrency, fn lane ->
              uid = "redis-mixed-#{lane}-b"

              assert {:ok, [%{"count" => ^per_lane}]} =
                       Store.call_on(peer, {:unread_counts, uid, %{}})

              assert {:ok, [conversation]} = Store.conversations(uid, %{"limit" => 1})
              assert conversation["unreadMessageCount"] == per_lane
              conversation["latestMessageId"]
            end)
          end)

        assert length(read_results) == lanes
        assert_direct_histories_recorded(sent)
        assert_direct_histories_recorded(peer, sent)

        assert_rate(
          "Redis mixed peer write/read ops",
          total + lanes * 2,
          write_seconds + read_seconds,
          minimum
        )
      after
        stop_peer_store(peer)
      end
    end)
  end

  test "concurrent Redis secondary-index reads stay consistent under write-through load" do
    with_redis(fn context ->
      concurrency = env_int("OPENCHAT_LOAD_REDIS_INDEX_CONCURRENCY", 8)
      messages = env_int("OPENCHAT_LOAD_REDIS_INDEX_MESSAGES", 240)
      minimum = env_int("OPENCHAT_MIN_REDIS_INDEX_OP_PER_SEC", 20)

      {sent, write_seconds} =
        timed(fn ->
          concurrent_map(1..messages, concurrency, fn i ->
            assert {:ok, message} =
                     Store.send_message("redis-index-a", %{
                       "receiver" => "redis-index-b",
                       "receiverType" => "user",
                       "muid" => "redis-index-muid-#{i}",
                       "type" => "text",
                       "data" => %{"text" => "redis index #{i}"}
                     })

            message
          end)
        end)

      assert length(sent) == messages
      assert_rate("Redis indexed writes", messages, write_seconds, minimum)

      {lookups, read_seconds} =
        timed(fn ->
          concurrent_map(sent, concurrency, fn message ->
            assert {:ok, fetched} = Store.find_message_by_muid(message["muid"])
            assert fetched["id"] == message["id"]

            assert {:ok, [_ | _]} = Store.conversations("redis-index-a", %{"limit" => 20})
            fetched["id"]
          end)
        end)

      assert lookups |> MapSet.new() |> MapSet.size() == messages
      assert "redis-index-a" in redis_members(context, "index", "user_conversations")
      assert "redis-index-b" in redis_members(context, "index", "user_conversations")
      assert_direct_histories_recorded(sent)
      assert_redis_messages_recorded(context, sent)

      Enum.each(sent, fn message ->
        assert redis_json(context, "message_muids", message["muid"]) == to_string(message["id"])
      end)

      assert_rate("Redis indexed reads", messages * 2, read_seconds, minimum)
    end)
  end

  test "Redis peer reaction load preserves final state across stores and Redis" do
    with_redis(fn context ->
      users = env_int("OPENCHAT_LOAD_REDIS_REACTION_USERS", 24)
      messages = env_int("OPENCHAT_LOAD_REDIS_REACTION_MESSAGES", 16)
      concurrency = env_int("OPENCHAT_LOAD_REDIS_REACTION_CONCURRENCY", 16)
      minimum = env_int("OPENCHAT_MIN_REDIS_REACTION_OP_PER_SEC", 20)
      guid = "redis-reaction-room"
      uids = Enum.map(1..users, &"redis-reaction-user-#{&1}")
      viewer = List.first(uids)

      sent = create_reaction_room_messages(guid, uids, messages, "redis reaction")
      peer = start_peer_store!()

      try do
        ops = reaction_ops(sent, uids, @reaction_emojis)

        {_added, add_seconds} =
          timed(fn ->
            concurrent_map(ops, concurrency, fn op ->
              if rem(op.index, 2) == 0 do
                assert {:ok, _message} = Store.add_reaction(op.uid, op.message_id, op.reaction)
              else
                assert {:ok, _message} =
                         Store.call_on(peer, {:add_reaction, op.uid, op.message_id, op.reaction})
              end

              op
            end)
          end)

        assert_rate("Redis peer reaction adds", length(ops), add_seconds, minimum)
        assert_group_reaction_state(OpenChat.Store, viewer, guid, sent, ops)
        assert_group_reaction_state(peer, viewer, guid, sent, ops)
        assert_redis_reactions_recorded(context, viewer, sent, ops)

        remove_ops = Enum.filter(ops, &(rem(&1.index, 6) == 0))

        toggle_remove_ops =
          ops |> reaction_ops_minus(remove_ops) |> Enum.filter(&(rem(&1.index, 11) == 0))

        toggle_add_ops = alternate_reaction_ops(sent, uids, "💿", 3)

        {_changed, change_seconds} =
          timed(fn ->
            concurrent_map(
              remove_ops ++ toggle_remove_ops ++ toggle_add_ops,
              concurrency,
              fn op ->
                cond do
                  op in remove_ops and rem(op.index, 2) == 0 ->
                    assert {:ok, _message} =
                             Store.call_on(
                               peer,
                               {:remove_reaction, op.uid, op.message_id, op.reaction}
                             )

                  op in remove_ops ->
                    assert {:ok, _message} =
                             Store.remove_reaction(op.uid, op.message_id, op.reaction)

                  rem(op.index, 2) == 0 ->
                    assert {:ok, _message} =
                             Store.call_on(
                               peer,
                               {:toggle_reaction, op.uid, op.message_id, op.reaction}
                             )

                  true ->
                    assert {:ok, _message} =
                             Store.toggle_reaction(op.uid, op.message_id, op.reaction)
                end

                op
              end
            )
          end)

        final_ops =
          ops
          |> reaction_ops_minus(remove_ops)
          |> reaction_ops_minus(toggle_remove_ops)
          |> Kernel.++(toggle_add_ops)

        assert_rate(
          "Redis peer reaction removes/toggles",
          length(remove_ops) + length(toggle_remove_ops) + length(toggle_add_ops),
          change_seconds,
          minimum
        )

        assert_group_reaction_state(OpenChat.Store, viewer, guid, sent, final_ops)
        assert_group_reaction_state(peer, viewer, guid, sent, final_ops)
        assert_redis_reactions_recorded(context, viewer, sent, final_ops)
      after
        stop_peer_store(peer)
      end
    end)
  end

  defp assert_direct_histories_recorded(messages),
    do: assert_direct_histories_recorded(OpenChat.Store, messages)

  defp assert_direct_histories_recorded(server, messages) do
    messages
    |> Enum.group_by(fn message -> {to_s(message["sender"]), to_s(message["receiver"])} end)
    |> Enum.each(fn {{sender, receiver}, expected} ->
      fetched = fetch_all_user_messages(server, receiver, sender)
      assert_messages_match(fetched, expected)

      assert {:ok, conversation} =
               store_call(server, {:conversation, receiver, "user", sender})

      latest = Enum.max_by(expected, &to_int(&1["id"]))
      assert conversation["latestMessageId"] == to_s(latest["id"])
      assert conversation["unreadMessageCount"] == length(expected)
    end)
  end

  defp assert_group_history_recorded(viewer_uid, guid, expected),
    do: assert_group_history_recorded(OpenChat.Store, viewer_uid, guid, expected)

  defp assert_group_history_recorded(server, viewer_uid, guid, expected) do
    fetched = fetch_all_group_messages(server, viewer_uid, guid)
    assert_messages_match(fetched, expected)

    assert {:ok, conversation} = store_call(server, {:conversation, viewer_uid, "group", guid})
    latest = Enum.max_by(expected, &to_int(&1["id"]))
    assert conversation["latestMessageId"] == to_s(latest["id"])
  end

  defp assert_http_user_history_recorded(auth_token, peer_uid, expected) do
    fetched = fetch_all_http_user_messages(auth_token, peer_uid)
    assert_messages_match(fetched, expected)
  end

  defp assert_redis_messages_recorded(context, expected) do
    expected_ids = expected |> Enum.map(&to_s(&1["id"])) |> MapSet.new()
    redis_ids = context |> redis_members("index", "messages") |> MapSet.new()
    assert redis_ids == expected_ids

    Enum.each(expected, fn message ->
      assert redis_json(context, "messages", message["id"]) |> message_signature() ==
               message_signature(message)
    end)
  end

  defp create_reaction_room_messages(guid, uids, count, prefix) do
    assert {:ok, _group} = Store.upsert_group(%{"guid" => guid, "type" => "public"})
    assert {:ok, _members} = Store.add_group_members(guid, uids)

    Enum.map(1..count, fn i ->
      sender = Enum.at(uids, rem(i, length(uids)))

      assert {:ok, message} =
               Store.send_message(sender, %{
                 "receiver" => guid,
                 "receiverType" => "group",
                 "type" => "text",
                 "data" => %{"text" => "#{prefix} #{i}"}
               })

      message
    end)
  end

  defp reaction_ops(messages, uids, emojis) do
    for {message, message_index} <- Enum.with_index(messages),
        {uid, uid_index} <- Enum.with_index(uids) do
      %{
        index: message_index * length(uids) + uid_index,
        message_id: to_s(message["id"]),
        uid: uid,
        reaction: Enum.at(emojis, rem(message_index + uid_index, length(emojis)))
      }
    end
  end

  defp alternate_reaction_ops(messages, uids, reaction, users_per_message) do
    users = Enum.take(uids, min(users_per_message, length(uids)))

    for {message, message_index} <- Enum.with_index(messages),
        {uid, uid_index} <- Enum.with_index(users) do
      %{
        index: 1_000_000 + message_index * length(users) + uid_index,
        message_id: to_s(message["id"]),
        uid: uid,
        reaction: reaction
      }
    end
  end

  defp reaction_ops_minus(ops, remove_ops) do
    remove_keys = remove_ops |> Enum.map(&reaction_key/1) |> MapSet.new()
    Enum.reject(ops, &(reaction_key(&1) in remove_keys))
  end

  defp reaction_key(op), do: {to_s(op.message_id), to_s(op.uid), to_s(op.reaction)}

  defp assert_group_reaction_state(server, viewer_uid, guid, messages, expected_ops) do
    history_by_id =
      server
      |> fetch_all_group_messages(viewer_uid, guid)
      |> Map.new(fn message -> {to_s(message["id"]), message} end)

    expected_by_message = Enum.group_by(expected_ops, &to_s(&1.message_id))

    Enum.each(messages, fn message ->
      message_id = to_s(message["id"])
      expected = Map.get(expected_by_message, message_id, [])

      assert {:ok, rows} = store_call(server, {:reactions, viewer_uid, message_id, nil})
      assert_reaction_rows(rows, expected, viewer_uid)

      assert {:ok, fetched} = store_call(server, {:get_message_for, viewer_uid, message_id, []})
      assert_reaction_message_wire(fetched, expected, viewer_uid)
      assert_reaction_message_wire(Map.fetch!(history_by_id, message_id), expected, viewer_uid)
    end)
  end

  defp assert_reaction_rows(rows, expected, viewer_uid) do
    actual =
      rows
      |> Enum.map(fn row -> {to_s(row["uid"]), to_s(row["reaction"])} end)
      |> MapSet.new()

    expected_set =
      expected
      |> Enum.map(fn op -> {to_s(op.uid), to_s(op.reaction)} end)
      |> MapSet.new()

    assert actual == expected_set

    Enum.each(rows, fn row ->
      assert row["reactedByMe"] == (to_s(row["uid"]) == to_s(viewer_uid))
      assert to_s(row["messageId"]) != ""
      assert to_int(row["reactedAt"]) > 0
      assert get_in(row, ["reactedBy", "uid"]) == to_s(row["uid"])
    end)
  end

  defp assert_reaction_message_wire(message, expected, viewer_uid, opts \\ []) do
    check_viewer? = Keyword.get(opts, :check_viewer?, true)

    expected_counts =
      expected
      |> Enum.frequencies_by(&to_s(&1.reaction))

    actual_summaries = get_in(message, ["data", "reactions"]) || []
    actual_counts = Map.new(actual_summaries, &{to_s(&1["reaction"]), &1["count"]})
    assert actual_counts == expected_counts

    if check_viewer? do
      Enum.each(actual_summaries, fn summary ->
        reaction = to_s(summary["reaction"])

        reacted_by_me? =
          Enum.any?(
            expected,
            &(to_s(&1.uid) == to_s(viewer_uid) and to_s(&1.reaction) == reaction)
          )

        assert summary["reactedByMe"] == reacted_by_me?
      end)
    end

    metadata = message["metadata"] || get_in(message, ["data", "metadata"]) || %{}
    extension = get_in(metadata, ["@injected", "extensions", "reactions"])

    if expected == [] do
      refute extension
    else
      assert extension

      assert extension |> Map.keys() |> Enum.sort() ==
               expected_counts |> Map.keys() |> Enum.sort()

      expected
      |> Enum.group_by(&to_s(&1.reaction))
      |> Enum.each(fn {reaction, ops} ->
        users = extension[reaction] || %{}
        assert users |> Map.keys() |> Enum.sort() == ops |> Enum.map(&to_s(&1.uid)) |> Enum.sort()

        Enum.each(ops, fn op ->
          assert get_in(users, [to_s(op.uid), "name"])
        end)
      end)
    end
  end

  defp assert_redis_reactions_recorded(context, viewer_uid, messages, expected_ops) do
    expected_by_message = Enum.group_by(expected_ops, &to_s(&1.message_id))
    expected_reacted_ids = expected_by_message |> Map.keys() |> MapSet.new()
    redis_reacted_ids = context |> redis_members("index", "reactions") |> MapSet.new()
    assert redis_reacted_ids == expected_reacted_ids

    Enum.each(messages, fn message ->
      message_id = to_s(message["id"])
      expected = Map.get(expected_by_message, message_id, [])
      redis_reactions = redis_json(context, "reactions", message_id)
      redis_message = redis_json(context, "messages", message_id)

      if expected == [] do
        assert redis_reactions in [nil, %{}]
      else
        assert redis_reaction_set(redis_reactions) ==
                 expected
                 |> Enum.map(fn op -> {to_s(op.uid), to_s(op.reaction)} end)
                 |> MapSet.new()
      end

      assert_reaction_message_wire(redis_message, expected, viewer_uid, check_viewer?: false)
    end)
  end

  defp redis_reaction_set(redis_reactions) do
    redis_reactions
    |> Kernel.||(%{})
    |> Enum.flat_map(fn {reaction, by_uid} ->
      Enum.map(by_uid || %{}, fn {uid, _row} -> {to_s(uid), to_s(reaction)} end)
    end)
    |> MapSet.new()
  end

  defp fetch_all_user_messages(server, uid, peer_uid) do
    fetch_all_pages(fn params ->
      store_call(server, {:messages_for_user, uid, peer_uid, params})
    end)
  end

  defp fetch_all_group_messages(server, uid, guid) do
    fetch_all_pages(fn params ->
      store_call(server, {:messages_for_group, uid, guid, params})
    end)
  end

  defp fetch_all_http_user_messages(auth_token, peer_uid) do
    fetch_all_pages(fn params ->
      path = "/v3.0/users/#{peer_uid}/messages?#{URI.encode_query(params)}"

      response =
        conn(:get, path)
        |> Plug.Conn.put_req_header("authtoken", auth_token)
        |> Endpoint.call([])

      assert response.status == 200
      %{"data" => messages} = Jason.decode!(response.resp_body)
      {:ok, messages}
    end)
  end

  defp fetch_all_pages(fetch_page, cursor \\ nil, acc \\ [], seen_cursors \\ MapSet.new()) do
    if cursor do
      refute MapSet.member?(seen_cursors, cursor),
             "pagination cursor did not advance past #{inspect(cursor)}"
    end

    params =
      %{"limit" => 100, "cursorField" => "id"}
      |> maybe_put("cursorValue", cursor)
      |> maybe_put("cursorAffix", if(cursor, do: "prepend"))

    assert {:ok, page} = fetch_page.(params)
    acc = acc ++ page

    if length(page) < 100 do
      acc
    else
      next_cursor = page |> List.first() |> Map.fetch!("id") |> to_s()

      refute next_cursor == cursor,
             "pagination returned the cursor message again without advancing"

      fetch_all_pages(fetch_page, next_cursor, acc, MapSet.put(seen_cursors, cursor))
    end
  end

  defp assert_messages_match(fetched, expected) do
    expected_by_id =
      Map.new(expected, fn message -> {to_s(message["id"]), message_signature(message)} end)

    fetched_by_id =
      Map.new(fetched, fn message -> {to_s(message["id"]), message_signature(message)} end)

    assert Map.keys(fetched_by_id) |> MapSet.new() == Map.keys(expected_by_id) |> MapSet.new()

    Enum.each(expected_by_id, fn {id, expected_signature} ->
      assert fetched_by_id[id] == expected_signature
    end)
  end

  defp message_signature(message) do
    %{
      "sender" => to_s(message["sender"]),
      "receiver" => to_s(message["receiver"]),
      "receiverType" => to_s(message["receiverType"]),
      "type" => to_s(message["type"]),
      "category" => to_s(message["category"]),
      "text" => get_in(message, ["data", "text"])
    }
  end

  defp message_ids(messages), do: Enum.map(messages, &to_int(&1["id"]))

  defp store_call(server, request), do: Store.call_on(server, request)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp with_redis(fun) do
    redis_url = System.get_env("REDIS_TEST_URL") || "redis://localhost:6379/15"

    case Redix.start_link(redis_url) do
      {:ok, redis} ->
        prefix = "open_chat:load:#{System.unique_integer([:positive])}"
        old_redis_url = Application.get_env(:open_chat, :redis_url)
        old_key_prefix = Application.get_env(:open_chat, :redis_key_prefix)
        old_snapshot_key = Application.get_env(:open_chat, :redis_snapshot_key)

        Application.put_env(:open_chat, :redis_url, redis_url)
        Application.put_env(:open_chat, :redis_key_prefix, prefix)
        Application.put_env(:open_chat, :redis_snapshot_key, "#{prefix}:legacy_snapshot")
        delete_prefix(redis, prefix)
        restart_store!()

        try do
          fun.(%{redis: redis, prefix: prefix})
        after
          Application.put_env(:open_chat, :redis_url, old_redis_url)
          Application.put_env(:open_chat, :redis_key_prefix, old_key_prefix)
          Application.put_env(:open_chat, :redis_snapshot_key, old_snapshot_key)
          restart_store!()
          delete_prefix(redis, prefix)
        end

      {:error, reason} ->
        IO.puts("Skipping Redis load test; Redis unavailable: #{inspect(reason)}")
        :ok
    end
  end

  defp timed(fun) do
    {microseconds, result} = :timer.tc(fun)
    {result, microseconds / 1_000_000}
  end

  defp timed_conn(fun) do
    {microseconds, result} = :timer.tc(fun)
    {result, microseconds / 1_000}
  end

  defp percentile(values, percentile) do
    sorted = Enum.sort(values)
    index = max(ceil(length(sorted) * percentile) - 1, 0)
    Enum.at(sorted, index, 0.0)
  end

  defp assert_rate(label, count, seconds, minimum) do
    per_second = count / max(seconds, 0.001)
    IO.puts("#{label}: #{Float.round(per_second, 1)}/s over #{count} ops")
    assert per_second >= minimum
  end

  defp concurrent_map(inputs, concurrency, fun) do
    inputs
    |> Task.async_stream(fun,
      max_concurrency: concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, value} ->
        value

      {:exit, reason} ->
        flunk("concurrent load task failed: #{Exception.format_exit(reason)}")
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
      Store.reset!()
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:open_chat, key)
        {key, value} -> Application.put_env(:open_chat, key, value)
      end)

      Store.reset!()
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, _rest} when int > 0 -> int
          _other -> default
        end
    end
  end

  defp load_user(i, users), do: "load-user-#{rem(i, users)}"

  defp mixed_message(receiver, i) do
    %{
      "receiver" => receiver,
      "receiverType" => "user",
      "type" => "text",
      "data" => %{"text" => "mixed peer #{i}"}
    }
  end

  defp start_peer_store! do
    {:ok, pid} = Store.start_link(name: nil)
    pid
  end

  defp stop_peer_store(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp restart_store! do
    if Process.whereis(OpenChat.Store) do
      :ok = Supervisor.terminate_child(OpenChat.Supervisor, OpenChat.Store)
    end

    if pid = Process.whereis(OpenChat.Redis) do
      Process.exit(pid, :kill)
      wait_until_stopped(OpenChat.Redis)
    end

    case Supervisor.restart_child(OpenChat.Supervisor, OpenChat.Store) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> flunk("failed to restart OpenChat.Store: #{inspect(other)}")
    end
  end

  defp wait_until_stopped(name, attempts \\ 20)
  defp wait_until_stopped(_name, 0), do: :ok

  defp wait_until_stopped(name, attempts) do
    if Process.whereis(name) do
      Process.sleep(10)
      wait_until_stopped(name, attempts - 1)
    else
      :ok
    end
  end

  defp redis_get(context, parts) when is_list(parts),
    do: redis_get_raw(context, redis_key(context, parts))

  defp redis_get(context, part_a, part_b), do: redis_get(context, [part_a, part_b])

  defp redis_get_raw(context, key) do
    {:ok, value} = Redix.command(context.redis, ["GET", key])
    value
  end

  defp redis_json(context, part_a, part_b) do
    case redis_get(context, part_a, to_s(part_b)) do
      nil -> nil
      json -> Jason.decode!(json)
    end
  end

  defp redis_members(context, parts) when is_list(parts) do
    {:ok, members} = Redix.command(context.redis, ["SMEMBERS", redis_key(context, parts)])
    members
  end

  defp redis_members(context, part_a, part_b), do: redis_members(context, [part_a, part_b])

  defp redis_key(context, parts) when is_list(parts), do: Enum.join([context.prefix | parts], ":")
  defp redis_key(context, part_a, part_b), do: redis_key(context, [part_a, part_b])

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp delete_prefix(redis, prefix, cursor \\ "0") do
    {:ok, [next_cursor, keys]} =
      Redix.command(redis, ["SCAN", cursor, "MATCH", "#{prefix}:*", "COUNT", "1000"])

    if keys != [] do
      Redix.command!(redis, ["DEL" | keys])
    end

    if next_cursor != "0" do
      delete_prefix(redis, prefix, next_cursor)
    end
  end
end
