defmodule OpenChat.ReplicationTest do
  @moduledoc """
  Two-region convergence: region A (Redis db 15) and region B (Redis db
  14) share a key prefix, exactly like production regions sharing
  REDIS_KEY_PREFIX across their own Redis instances. The test drives A,
  captures its oplog, swaps the node's identity to B, and applies.
  """

  use ExUnit.Case, async: false

  alias OpenChat.Replication.{Applier, Tailer}
  alias OpenChat.Store
  alias OpenChat.Store.RedisPersistence

  @region_a_url System.get_env("REDIS_TEST_URL") || "redis://localhost:6379/15"
  @region_b_url System.get_env("REDIS_TEST_B_URL") || "redis://localhost:6379/14"

  setup_all do
    with {:ok, redis_a} <- Redix.start_link(@region_a_url),
         {:ok, redis_b} <- Redix.start_link(@region_b_url) do
      {:ok, redis_a: redis_a, redis_b: redis_b}
    else
      {:error, reason} -> {:ok, redis_unavailable: reason}
    end
  end

  setup context do
    if reason = context[:redis_unavailable] do
      {:ok, skip_redis?: reason}
    else
      prefix = "roach:test:#{System.unique_integer([:positive])}"

      previous =
        Map.new(
          [:redis_url, :redis_key_prefix, :redis_snapshot_key, :id_allocator] ++
            [:region_index, :replication_mode, :peer_regions],
          fn key -> {key, Application.get_env(:open_chat, key)} end
        )

      delete_prefix(context.redis_a, prefix)
      delete_prefix(context.redis_b, prefix)

      on_exit(fn ->
        Enum.each(previous, fn
          {key, nil} -> Application.delete_env(:open_chat, key)
          {key, value} -> Application.put_env(:open_chat, key, value)
        end)

        restart_store!()
        delete_prefix(context.redis_a, prefix)
        delete_prefix(context.redis_b, prefix)
      end)

      Application.put_env(:open_chat, :redis_key_prefix, prefix)
      Application.put_env(:open_chat, :redis_snapshot_key, "#{prefix}:legacy_snapshot")
      Application.put_env(:open_chat, :id_allocator, "region")
      Application.put_env(:open_chat, :replication_mode, "multi_master")

      {:ok, prefix: prefix}
    end
  end

  defp become_region!(index, url) do
    Application.put_env(:open_chat, :redis_url, url)
    Application.put_env(:open_chat, :region_index, index)
    restart_store!()
  end

  defp send_text(sender, receiver, text) do
    {:ok, msg} =
      Store.send_message(sender, %{
        "receiver" => receiver,
        "receiverType" => "user",
        "data" => %{"text" => text}
      })

    msg
  end

  defp region_a_entries(context) do
    stream = RedisPersistence.oplog_stream_key(0)
    {:ok, raw} = Redix.command(context.redis_a, ["XRANGE", stream, "-", "+"])
    Enum.map(raw, fn [id, ["entry", json]] -> {id, json} end)
  end

  defp apply_all(entries) do
    Enum.map(entries, fn {id, json} ->
      {:ok, applied} = Applier.apply_encoded(json, id)
      applied
    end)
  end

  test "everything region A did replays into region B, once, with live fanout", context do
    with_redis(context, fn ->
      become_region!(0, @region_a_url)

      first = send_text("croach-a", "croach-b", "hello from region A")
      second = send_text("croach-a", "croach-b", "second")
      {:ok, _} = Store.mark_read("croach-b", "user", "croach-a", to_string(first["id"]))
      {:ok, _} = Store.upsert_group(%{"guid" => "croach-room", "name" => "War Room"})
      {:ok, _} = Store.add_group_members("croach-room", ["croach-a", "croach-b"], "participant")

      {:ok, action} =
        Store.edit_message("croach-a", to_string(second["id"]), %{"text" => "edited"})

      entries = region_a_entries(context)
      assert length(entries) >= 5

      # Only source-of-truth buckets travel; receivers recompute the rest.
      for {_id, json} <- entries,
          {:ok, %{ops: ops}} = OpenChat.Replication.decode_entry(json),
          op <- ops do
        bucket = elem(op, 1)

        assert bucket in OpenChat.Replication.replicated_buckets(),
               "derived bucket #{bucket} leaked into the oplog"
      end

      become_region!(1, @region_b_url)
      {:ok, _} = OpenChat.PubSub.subscribe({:user, "croach-b"})

      apply_all(entries)

      # Messages, edits, receipts, groups, membership — all converged.
      {:ok, messages} = Store.messages_for_user("croach-b", "croach-a", %{"limit" => 10})
      texts = messages |> Enum.map(& &1["data"]["text"]) |> Enum.sort()
      assert "hello from region A" in texts
      assert "edited" in texts

      edited = Enum.find(messages, &(&1["id"] == second["id"]))
      assert edited["data"]["text"] == "edited"
      assert edited["editedAt"]

      {:ok, convs} = Store.conversations("croach-b", %{})
      conv = Enum.find(convs, &(&1["conversationId"] =~ "croach"))
      assert conv, "conversation missing in region B"
      assert to_string(conv["latestMessageId"]) == to_string(action["id"])

      # Read cursor replicated: only messages after `first` are unread.
      {:ok, counts} = Store.unread_counts("croach-b", %{"receiverType" => "user"})
      assert [%{"count" => count}] = counts
      assert count >= 1

      {:ok, members} = Store.group_members("croach-room", %{})
      assert Enum.map(members, & &1["uid"]) |> Enum.sort() == ["croach-a", "croach-b"]

      {:ok, groups} = Store.groups_for_user("croach-b")
      assert Enum.map(groups, & &1["guid"]) == ["croach-room"]

      # Region B's websockets got live events for the replicated messages.
      assert_received {:comet_event, %{"type" => "message"}}

      # Replay the whole log again: idempotent, nothing duplicates.
      apply_all(entries)
      {:ok, messages_again} = Store.messages_for_user("croach-b", "croach-a", %{"limit" => 50})
      assert length(messages_again) == length(messages)

      # Nothing region B applied re-entered ITS oplog — the echo guard.
      # Without it every entry ping-pongs between regions forever.
      b_stream = RedisPersistence.oplog_stream_key(1)
      assert {:ok, 0} = Redix.command(context.redis_b, ["XLEN", b_stream])

      # And a region never applies its own entries.
      [{first_id, first_entry} | _rest] = entries
      Application.put_env(:open_chat, :region_index, 0)
      assert {:error, :own_origin} = Applier.apply_encoded(first_entry, first_id)
      Application.put_env(:open_chat, :region_index, 1)
    end)
  end

  test "same-origin same-millisecond ops apply in stream order", context do
    with_redis(context, fn ->
      become_region!(1, @region_b_url)

      # Create-group followed by add-members routinely lands in ONE
      # millisecond on the origin. Identical ts, same origin: only the
      # origin's stream id can order them. Deterministic here — no racing
      # the wall clock like the real war-room repro that first caught it.
      ts = System.system_time(:millisecond)

      empty_room =
        encode_entry(0, ts, [
          ["put", "groups", "same-ms-room", %{"guid" => "same-ms-room", "name" => "Same MS"}],
          ["put", "members", "same-ms-room", %{}]
        ])

      filled_room =
        encode_entry(0, ts, [
          [
            "put",
            "members",
            "same-ms-room",
            %{"same-ms-a" => %{"scope" => "participant", "joinedAt" => 1}}
          ]
        ])

      {:ok, 2} = Applier.apply_encoded(empty_room, "#{ts}-1")
      {:ok, 1} = Applier.apply_encoded(filled_room, "#{ts}-2")

      {:ok, members} = Store.group_members("same-ms-room", %{})
      assert Enum.map(members, & &1["uid"]) == ["same-ms-a"]

      # Replaying the OLDER same-ms entry: every op gated, room intact.
      {:ok, 0} = Applier.apply_encoded(empty_room, "#{ts}-1")
      {:ok, members_after_replay} = Store.group_members("same-ms-room", %{})
      assert Enum.map(members_after_replay, & &1["uid"]) == ["same-ms-a"]
    end)
  end

  test "concurrent updates to one record converge to the same winner", context do
    with_redis(context, fn ->
      become_region!(1, @region_b_url)

      base = System.system_time(:millisecond)

      older =
        encode_entry(0, base, [
          ["put", "users", "lww-user", %{"uid" => "lww-user", "name" => "older write"}]
        ])

      newer =
        encode_entry(2, base + 5, [
          ["put", "users", "lww-user", %{"uid" => "lww-user", "name" => "newer write"}]
        ])

      # Arrival order newest-first: the stale op must be gated, not applied.
      {:ok, 1} = Applier.apply_encoded(newer)
      {:ok, 0} = Applier.apply_encoded(older)

      {:ok, user} = Store.get_user("lww-user")
      assert user["name"] == "newer write"
    end)
  end

  test "receipt cursors only move forward regardless of replay order", context do
    with_redis(context, fn ->
      become_region!(0, @region_a_url)
      msg1 = send_text("cur-a", "cur-b", "one")
      msg2 = send_text("cur-a", "cur-b", "two")
      conv_id = msg1["conversationId"]
      message_entries = region_a_entries(context)

      become_region!(1, @region_b_url)
      # The conversation must exist in B before its cursors mean anything.
      apply_all(message_entries)
      now = System.system_time(:millisecond)

      ahead =
        encode_entry(0, now, [
          ["put", "reads", "cur-b", %{conv_id => read_row(msg2, conv_id)}]
        ])

      behind =
        encode_entry(0, now + 10, [
          ["put", "reads", "cur-b", %{conv_id => read_row(msg1, conv_id)}]
        ])

      {:ok, 1} = Applier.apply_encoded(ahead, "500-1")
      # The later entry carries an OLDER cursor; max-merge must ignore it.
      {:ok, 1} = Applier.apply_encoded(behind, "500-2")

      {:ok, conv} = Store.conversation("cur-b", "user", "cur-a")
      assert to_string(conv["lastReadMessageId"]) == to_string(msg2["id"])
    end)
  end

  test "a late old message cannot clobber the latest pointer", context do
    with_redis(context, fn ->
      become_region!(0, @region_a_url)
      older = send_text("late-a", "late-b", "older, replicated late")
      newer = send_text("late-a", "late-b", "newer")
      conv_id = newer["conversationId"]

      [{older_id, older_entry}, {newer_id, newer_entry}] = region_a_entries(context)

      become_region!(1, @region_b_url)

      # Deliver out of order: newer first, older afterwards.
      {:ok, _} = Applier.apply_encoded(newer_entry, newer_id)
      {:ok, _} = Applier.apply_encoded(older_entry, older_id)

      {:ok, conv} = Store.conversation("late-b", "user", "late-a")
      assert to_string(conv["latestMessageId"]) == to_string(newer["id"])
      assert conv["lastMessage"]["id"] == newer["id"]
      _ = older
      _ = conv_id
    end)
  end

  test "a live tailer drains a peer stream end to end", context do
    with_redis(context, fn ->
      become_region!(0, @region_a_url)
      for n <- 1..5, do: send_text("tail-a", "tail-b", "burst #{n}")
      expected = length(region_a_entries(context))

      become_region!(1, @region_b_url)
      peer = %{index: 0, url: @region_a_url}
      {:ok, tailer} = Tailer.start_link(peer)

      try do
        wait_until(fn ->
          %{applied: applied} = :sys.get_state(tailer) |> Map.take([:applied]) |> Map.new()
          applied >= expected
        end)

        {:ok, messages} = Store.messages_for_user("tail-b", "tail-a", %{"limit" => 10})
        assert length(messages) == 5

        # Cursor persisted: a restarted tailer resumes past everything.
        {:ok, cursor} = RedisPersistence.get_replication_cursor(0)
        assert is_binary(cursor)
      after
        GenServer.stop(tailer)
      end
    end)
  end

  test "the tailer refuses to skip a trimmed gap", context do
    with_redis(context, fn ->
      become_region!(1, @region_b_url)

      # Pretend we once applied entry 1-1 from region 0, then the peer
      # trimmed far past it.
      :ok = RedisPersistence.put_replication_cursor(0, "1-1")
      stream = RedisPersistence.oplog_stream_key(0)

      {:ok, _} =
        Redix.command(context.redis_b, [
          "XADD",
          stream,
          "999999999-0",
          "entry",
          encode_entry(0, System.system_time(:millisecond), [
            ["put", "users", "gap-user", %{"uid" => "gap-user"}]
          ])
        ])

      peer = %{index: 0, url: @region_b_url}
      {:ok, tailer} = Tailer.start_link(peer)

      try do
        wait_until(fn -> :sys.get_state(tailer).mode == :degraded end)

        # Degraded means: nothing applied, loudly stuck.
        assert :sys.get_state(tailer).applied == 0
        assert {:ok, nil} = Store.get_user("gap-user") |> then(&{:ok, elem_or_nil(&1)})
      after
        GenServer.stop(tailer)
      end
    end)
  end

  # -- helpers ---------------------------------------------------------

  defp elem_or_nil({:ok, user}), do: user
  defp elem_or_nil(_other), do: nil

  defp read_row(msg, _conv_id) do
    %{"messageId" => to_string(msg["id"]), "readAt" => OpenChat.Time.now()}
  end

  defp encode_entry(origin, ts, ops) do
    Jason.encode!(%{"v" => 1, "origin" => origin, "ts" => ts, "ops" => ops})
  end

  defp wait_until(fun, deadline_ms \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not reached in time")

      true ->
        Process.sleep(50)
        do_wait(fun, deadline)
    end
  end

  defp with_redis(%{skip_redis?: reason}, _fun) do
    IO.puts("Skipping replication test; Redis unavailable: #{inspect(reason)}")
    :ok
  end

  defp with_redis(_context, fun), do: fun.()

  defp restart_store! do
    if Process.whereis(OpenChat.Store) do
      :ok = Supervisor.terminate_child(OpenChat.Supervisor, OpenChat.Store)
    end

    for name <- [
          OpenChat.Redis,
          OpenChat.RedisWriter,
          OpenChat.RedisMutationReader,
          OpenChat.RedisCounter,
          OpenChat.RedisLock0,
          OpenChat.RedisLock1,
          OpenChat.RedisLock2,
          OpenChat.RedisLock3
        ],
        pid = Process.whereis(name),
        is_pid(pid) do
      Process.exit(pid, :kill)
      wait_until(fn -> Process.whereis(name) == nil or Process.whereis(name) != pid end, 2_000)
    end

    case Supervisor.restart_child(OpenChat.Supervisor, OpenChat.Store) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> flunk("failed to restart OpenChat.Store: #{inspect(other)}")
    end
  end

  defp delete_prefix(redis, prefix) do
    {:ok, keys} = Redix.command(redis, ["KEYS", "#{prefix}:*"])
    if keys != [], do: Redix.command(redis, ["DEL" | keys])
    :ok
  end
end
