defmodule OpenChat.RedisMockTest do
  use ExUnit.Case, async: false

  alias OpenChat.{MockRedis, RedisBus}
  alias OpenChat.Store.{RedisPersistence, RequestPlan, State}

  setup do
    previous =
      Map.new(
        [
          :redis_url,
          :redis_key_prefix,
          :redis_snapshot_key,
          :redis_boot_mode,
          :redis_client,
          :redis_pubsub_client
        ],
        &{&1, Application.get_env(:open_chat, &1)}
      )

    stop_name(OpenChat.Redis)
    stop_name(OpenChat.RedisPubSub)
    stop_name(OpenChat.RedisBusPublisher)

    Application.put_env(:open_chat, :redis_url, "mock://redis")
    Application.put_env(:open_chat, :redis_key_prefix, "mock:test")
    Application.put_env(:open_chat, :redis_snapshot_key, "mock:test:legacy_snapshot")
    Application.put_env(:open_chat, :redis_boot_mode, "full")
    Application.put_env(:open_chat, :redis_client, MockRedis)
    Application.put_env(:open_chat, :redis_pubsub_client, MockRedis.PubSub)

    on_exit(fn ->
      terminate_redis_bus()

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:open_chat, key)
        {key, value} -> Application.put_env(:open_chat, key, value)
      end)

      stop_name(OpenChat.Redis)
      stop_name(OpenChat.RedisPubSub)
      stop_name(OpenChat.RedisBusPublisher)
      restart_redis_bus()
    end)

    :ok
  end

  test "mock Redis exercises load replace write refresh locks and counters" do
    default = State.default()
    seed = put_in(default, ["users", "seed"], %{"uid" => "seed"})

    assert RedisPersistence.load_or_seed(default, fn -> seed end) == seed
    assert RedisPersistence.enabled?()
    assert MockRedis.strings()["mock:test:meta:version"] == "7"
    assert MockRedis.strings()["mock:test:meta:revision"] == "1"
    assert MapSet.member?(MockRedis.sets()["mock:test:index:users"], "seed")
    assert "users" in RedisPersistence.buckets()
    assert "next_id" in RedisPersistence.counters()

    assert RedisPersistence.put_or_delete("users", "nobody", nil) ==
             RedisPersistence.delete("users", "nobody")

    assert RedisPersistence.put_or_delete("users", "alice", %{"uid" => "alice"}) ==
             RedisPersistence.put("users", "alice", %{"uid" => "alice"})

    assert :ok =
             RedisPersistence.write([
               RedisPersistence.put("users", "alice", %{"uid" => "alice"}),
               RedisPersistence.put("tokens", "tok", "alice"),
               RedisPersistence.delete("users", "seed"),
               RedisPersistence.counter("next_id", 30)
             ])

    assert Jason.decode!(MockRedis.strings()["mock:test:users:alice"]) == %{"uid" => "alice"}
    refute Map.has_key?(MockRedis.strings(), "mock:test:users:seed")
    assert MockRedis.strings()["mock:test:counter:next_id"] == "30"

    MockRedis.put_string("mock:test:meta:revision", "99")
    refreshed = RedisPersistence.refresh(default, default)

    assert get_in(refreshed, ["users", "alice"]) == %{"uid" => "alice"}
    assert get_in(refreshed, ["tokens", "tok"]) == "alice"
    assert refreshed["next_id"] == 30
    assert RedisPersistence.refresh(default, seed) == seed

    assert RedisPersistence.take_counter("next_id", 1) == 30
    assert MockRedis.strings()["mock:test:counter:next_id"] == "31"

    assert RedisPersistence.with_lock(fn -> :global_locked end) == :global_locked

    assert RedisPersistence.with_locks([{:conversation, "a", "b"}], fn -> :locked end) ==
             :locked

    assert RedisPersistence.with_locks([["custom", nil], :plain], fn -> :scoped end) == :scoped
    assert RedisPersistence.write([:ignored]) == :ok

    refute MockRedis.strings() |> Map.keys() |> Enum.any?(&String.contains?(&1, ":lock:"))
  end

  test "targeted refresh follows related Redis records through indexes" do
    start_mock_redis()

    conversation_id = "user_alice_bob"

    assert :ok =
             RedisPersistence.write([
               RedisPersistence.put("users", "alice", %{"uid" => "alice"}),
               RedisPersistence.put("users", "bob", %{"uid" => "bob"}),
               RedisPersistence.put("tokens", "tok", "alice"),
               RedisPersistence.put("groups", "room", %{"guid" => "room", "type" => "public"}),
               RedisPersistence.put("members", "room", %{
                 "alice" => %{"uid" => "alice", "scope" => "admin"}
               }),
               RedisPersistence.put("banned", "room", %{"bob" => %{"uid" => "bob"}}),
               RedisPersistence.put("blocks", "alice", %{"bob" => true}),
               RedisPersistence.put("user_groups", "alice", ["room"]),
               RedisPersistence.put("conversation_users", conversation_id, ["alice", "bob"]),
               RedisPersistence.put("user_conversations", "alice", [conversation_id]),
               RedisPersistence.put("conversation_latest", conversation_id, "1"),
               RedisPersistence.put("conversation_messages", conversation_id, ["1"]),
               RedisPersistence.put("message_muids", "muid-1", "1"),
               RedisPersistence.put("messages", "1", %{
                 "id" => 1,
                 "muid" => "muid-1",
                 "sender" => "alice",
                 "receiver" => "bob",
                 "receiverType" => "user",
                 "conversationId" => conversation_id,
                 "data" => %{"text" => "hi"}
               }),
               RedisPersistence.put("messages", "2", %{
                 "id" => 2,
                 "sender" => "alice",
                 "receiver" => "room",
                 "receiverType" => "group",
                 "conversationId" => "group_room",
                 "data" => %{"text" => "group hi"}
               }),
               RedisPersistence.put("messages", "3", %{
                 "id" => 3,
                 "conversationId" => conversation_id,
                 "data" => %{"text" => "partial"}
               }),
               RedisPersistence.put("unread_counts", "bob", %{conversation_id => 1}),
               RedisPersistence.counter("next_id", 50)
             ])

    state =
      RedisPersistence.refresh_keys(State.default(), State.default(), [
        {:record, "tokens", "tok"},
        {:record, "members", "room"},
        {:record, "banned", "room"},
        {:record, "blocks", "alice"},
        {:record, "user_groups", "alice"},
        {:record, "user_conversations", "alice"},
        {:record, "conversation_users", conversation_id},
        {:record, "conversation_latest", conversation_id},
        {:record, "conversation_messages", conversation_id},
        {:record, "message_muids", "muid-1"},
        {:record, "messages", "2"},
        {:record, "messages", "3"},
        {:counter, "next_id"},
        {:bucket, "groups"},
        {:record, "unknown", "ignored"},
        {:bucket, "unknown"},
        :ignored
      ])

    assert get_in(state, ["tokens", "tok"]) == "alice"
    assert get_in(state, ["users", "alice", "uid"]) == "alice"
    assert get_in(state, ["users", "bob", "uid"]) == "bob"
    assert get_in(state, ["groups", "room", "guid"]) == "room"
    assert get_in(state, ["members", "room", "alice", "scope"]) == "admin"
    assert get_in(state, ["banned", "room", "bob", "uid"]) == "bob"
    assert get_in(state, ["blocks", "alice", "bob"]) == true
    assert get_in(state, ["user_groups", "alice"]) == ["room"]
    assert get_in(state, ["conversation_users", conversation_id]) == ["alice", "bob"]
    assert get_in(state, ["conversation_latest", conversation_id]) == "1"
    assert get_in(state, ["conversation_messages", conversation_id]) == ["1"]
    assert get_in(state, ["messages", "1", "data", "text"]) == "hi"
    assert get_in(state, ["messages", "2", "data", "text"]) == "group hi"
    assert get_in(state, ["messages", "3", "data", "text"]) == "partial"
    assert get_in(state, ["message_muids", "muid-1"]) == "1"
    assert get_in(state, ["unread_counts", "bob", conversation_id]) == 1
    assert state["next_id"] == 50
  end

  test "Redis fallback and error branches return safe values" do
    default = State.default()
    seed = fn -> put_in(default, ["users", "fallback"], %{"uid" => "fallback"}) end

    Application.put_env(:open_chat, :redis_url, nil)
    stop_name(OpenChat.Redis)

    assert RedisPersistence.load_or_seed(default, seed) == seed.()
    assert RedisPersistence.refresh(default, seed.()) == seed.()

    assert RedisPersistence.refresh_keys(default, seed.(), [{:record, "users", "alice"}]) ==
             seed.()

    assert RedisPersistence.with_locks([:global], fn -> :no_redis end) == :no_redis
    assert RedisPersistence.take_counter("next_id", 7) == 7
    assert RedisPersistence.take_counter("next_id", :bad) == 0
    assert RedisPersistence.write([RedisPersistence.put("users", "noop", %{})]) == :ok
    assert RedisPersistence.replace_all(seed.()) == :ok

    Application.put_env(:open_chat, :redis_url, "")
    assert RedisPersistence.load_or_seed(default, seed) == seed.()

    Application.put_env(:open_chat, :redis_url, "mock://redis")
    Application.put_env(:open_chat, :redis_client, MockRedis.FailingClient)
    stop_name(OpenChat.Redis)

    assert RedisPersistence.load_or_seed(default, seed) == seed.()
    assert MockRedis.FailingClient.command(nil, []) == {:error, :mock_connection_down}
    assert MockRedis.FailingClient.pipeline(nil, []) == {:error, :mock_connection_down}

    Application.put_env(:open_chat, :redis_client, MockRedis.AlreadyStartedClient)
    stop_name(OpenChat.Redis)
    assert RedisPersistence.load_or_seed(default, seed) == seed.()

    Application.put_env(:open_chat, :redis_client, MockRedis)
    stop_name(OpenChat.Redis)
    start_mock_redis()

    assert RedisPersistence.refresh(default, seed.()) == seed.()
    MockRedis.put_string("mock:test:meta:revision", "0")
    assert RedisPersistence.refresh(default, seed.()) == seed.()

    stop_name(OpenChat.Redis)
    start_mock_redis()
    MockRedis.force_command({:error, :meta_down})
    assert RedisPersistence.load_or_seed(default, seed) == seed.()

    stop_name(OpenChat.Redis)
    start_mock_redis()
    MockRedis.force_command({:ok, nil})
    MockRedis.force_command({:error, :snapshot_down})
    assert RedisPersistence.load_or_seed(default, seed) == seed.()

    stop_name(OpenChat.Redis)
    start_mock_redis()
    MockRedis.put_string("mock:test:legacy_snapshot", "not-json")
    assert RedisPersistence.load_or_seed(default, seed) == seed.()

    MockRedis.force_command({:error, :refresh_down})
    assert RedisPersistence.refresh(default, seed.()) == seed.()

    MockRedis.force_pipeline({:error, :record_pipeline_down})

    assert RedisPersistence.refresh_keys(default, seed.(), [{:record, "users", "alice"}]) ==
             seed.()

    MockRedis.force_pipeline({:error, :counter_pipeline_down})
    state = RedisPersistence.refresh_keys(default, seed.(), [{:counter, "next_id"}])
    assert state["next_id"] == seed.()["next_id"]

    MockRedis.force_command({:error, :counter_down})

    assert_raise RuntimeError, ~r/Redis counter allocation failed/, fn ->
      RedisPersistence.take_counter("next_id", 1)
    end

    MockRedis.force_command({:error, :lock_down})

    assert_raise RuntimeError, ~r/Redis lock failed/, fn ->
      RedisPersistence.with_locks([:global], fn -> :never end)
    end

    MockRedis.force_command({:error, :atomic_down})

    assert RedisPersistence.write([RedisPersistence.put("users", "safe", %{"uid" => "safe"})]) ==
             {:error, :atomic_down}

    MockRedis.force_command({:raise, "atomic exploded"})

    assert RedisPersistence.write([RedisPersistence.put("users", "safe", %{"uid" => "safe"})]) ==
             {:error, "atomic exploded"}

    MockRedis.force_command({:error, :scan_down})
    MockRedis.force_pipeline({:error, :pipeline_down})
    assert RedisPersistence.replace_all(seed.()) == {:error, :pipeline_down}

    MockRedis.force_command({:raise, "scan exploded"})
    assert RedisPersistence.replace_all(seed.()) == {:error, "scan exploded"}

    MockRedis.force_pipeline({:raise, "pipeline exploded"})
    assert RedisPersistence.replace_all(seed.()) == {:error, "pipeline exploded"}
  end

  test "message action plans lock the message and its Redis conversation" do
    start_mock_redis()

    assert :ok =
             RedisPersistence.write([
               RedisPersistence.put("messages", "message-action-1", %{
                 "id" => "message-action-1",
                 "conversationId" => "group_plan-room",
                 "receiverType" => "group",
                 "receiver" => "plan-room",
                 "sender" => "alice"
               })
             ])

    delete_plan = RequestPlan.build({:delete_message, "alice", "message-action-1", []})
    edit_plan = RequestPlan.build({:edit_message, "alice", "message-action-1", %{}, []})

    assert delete_plan.locks == [
             {:message, "message-action-1"},
             {:conversation, "group_plan-room"}
           ]

    assert edit_plan.locks == [
             {:message, "message-action-1"},
             {:conversation, "group_plan-room"}
           ]
  end

  test "mock Redis covers bucket decode and refresh edge cases" do
    default = State.default()
    start_mock_redis()

    MockRedis.put_string("mock:test:meta:version", "7")

    assert {:ok, _} =
             MockRedis.command(OpenChat.Redis, [
               "SADD",
               "mock:test:index:users",
               "alice",
               "bad",
               "missing"
             ])

    MockRedis.put_string("mock:test:users:alice", Jason.encode!(%{"uid" => "alice"}))
    MockRedis.put_string("mock:test:users:bad", "not-json")

    state =
      RedisPersistence.load_or_seed(default, fn -> flunk("versioned Redis should not seed") end)

    assert state["users"] == %{"alice" => %{"uid" => "alice"}}
    assert state["next_id"] == default["next_id"]

    stale_state = put_in(default, ["users", "ghost"], %{"uid" => "ghost"})
    refreshed = RedisPersistence.refresh_keys(default, stale_state, [{:record, "users", "ghost"}])
    refute Map.has_key?(refreshed["users"], "ghost")

    stale_state = put_in(default, ["users", "err"], %{"uid" => "err"})
    MockRedis.force_command({:ok, ["err"]})
    MockRedis.force_command({:error, :record_down})

    assert RedisPersistence.refresh_keys(default, stale_state, [{:bucket, "users"}])["users"] ==
             %{}

    MockRedis.force_command({:error, :index_down})

    assert RedisPersistence.refresh_keys(default, stale_state, [{:bucket, "users"}])["users"] ==
             %{}

    stop_name(OpenChat.Redis)
    start_mock_redis()
    MockRedis.put_string("mock:test:lock:held", "lock-value")
    assert RedisPersistence.replace_all(default) == :ok

    assert {:ok, "OK"} =
             MockRedis.command(OpenChat.Redis, ["SET", "mock:test:nx", "one", "NX", "PX", "10"])

    assert {:ok, nil} =
             MockRedis.command(OpenChat.Redis, ["SET", "mock:test:nx", "two", "NX", "PX", "10"])

    assert {:ok, 1} = MockRedis.command(OpenChat.Redis, ["SADD", "mock:test:set", "a"])
    assert {:ok, 1} = MockRedis.command(OpenChat.Redis, ["SREM", "mock:test:set", "a"])
    assert {:ok, 1} = MockRedis.command(OpenChat.Redis, ["DEL", "mock:test:nx"])

    MockRedis.put_string("mock:test:int", 4)
    assert {:ok, 5} = MockRedis.command(OpenChat.Redis, ["INCR", "mock:test:int"])

    MockRedis.force_pipeline({:ok, [:forced]})
    assert MockRedis.pipeline(OpenChat.Redis, [["GET", "mock:test:int"]]) == {:ok, [:forced]}

    assert MockRedis.command(OpenChat.Redis, ["EVAL", "return 1", "1", "mock:test:int", "1"]) ==
             {:error, {:unsupported, ["EVAL", "return 1", "1", "mock:test:int", "1"]}}

    assert MockRedis.command(OpenChat.Redis, ["NOOP"]) == {:error, {:unsupported, ["NOOP"]}}
  end

  test "lazy Redis boot skips full startup load and uses targeted refreshes" do
    default = State.default()
    start_mock_redis()

    Application.put_env(:open_chat, :redis_boot_mode, "lazy")
    MockRedis.put_string("mock:test:meta:version", "7")

    assert {:ok, _} =
             MockRedis.command(OpenChat.Redis, [
               "SADD",
               "mock:test:index:users",
               "alice"
             ])

    MockRedis.put_string("mock:test:users:alice", Jason.encode!(%{"uid" => "alice"}))

    assert RedisPersistence.load_or_seed(default, fn ->
             flunk("lazy versioned Redis should not seed")
           end) == default

    refreshed = RedisPersistence.refresh_keys(default, default, [{:bucket, "users"}])
    assert refreshed["users"] == %{"alice" => %{"uid" => "alice"}}
  end

  test "RedisBus publishes to mock Redis and consumes remote pubsub events" do
    start_mock_redis()
    terminate_redis_bus()
    restart_redis_bus()

    RedisBus.publish([{:user, "alice"}, {:raw, "ignored"}], %{"text" => "hi"})
    RedisBus.publish_system({:group, "room"}, %{"type" => "membership_changed"})

    [first_publish, second_publish] = wait_for_published(2, OpenChat.RedisBusPublisher)
    assert {channel, payload} = first_publish
    assert channel == "mock:test:events"

    decoded = Jason.decode!(payload)
    assert decoded["keys"] == [["user", "alice"], ["raw", "ignored"]]
    assert decoded["event"] == %{"text" => "hi"}
    assert decoded["system"] == false

    assert {_channel, system_payload} = second_publish
    assert Jason.decode!(system_payload)["system"] == true

    {:ok, _} = OpenChat.PubSub.subscribe({:user, "alice"})
    {:ok, _} = OpenChat.PubSub.subscribe({:group, "room"})

    remote_payload =
      Jason.encode!(%{
        "origin" => "remote",
        "keys" => [["user", "alice"], ["group", "room"], ["raw", "ignored"], ["bad"]],
        "event" => %{"text" => "remote"},
        "system" => false
      })

    send(Process.whereis(RedisBus), {
      :redix_pubsub,
      self(),
      make_ref(),
      :message,
      %{channel: "mock:test:events", payload: remote_payload}
    })

    assert_receive {:comet_event, %{"text" => "remote"}}
    assert_receive {:comet_event, %{"text" => "remote"}}

    system_payload =
      Jason.encode!(%{
        "origin" => "remote",
        "keys" => [["user", "alice"]],
        "event" => %{"type" => "system"},
        "system" => true
      })

    send(Process.whereis(RedisBus), {
      :redix_pubsub,
      self(),
      make_ref(),
      :message,
      %{channel: "mock:test:events", payload: system_payload}
    })

    assert_receive {:open_chat_system_event, %{"type" => "system"}}

    send(
      Process.whereis(RedisBus),
      {:redix_pubsub, self(), make_ref(), :message, %{channel: "other", payload: "{}"}}
    )

    send(Process.whereis(RedisBus), :unexpected)

    send(Process.whereis(RedisBus), {
      :redix_pubsub,
      self(),
      make_ref(),
      :message,
      %{channel: "mock:test:events", payload: "not-json"}
    })

    refute_receive {:comet_event, _event}, 20

    bus_state = :sys.get_state(RedisBus)

    self_origin_payload =
      Jason.encode!(%{
        "origin" => bus_state.origin,
        "keys" => [["user", "alice"]],
        "event" => %{"text" => "self-origin"},
        "system" => false
      })

    send(Process.whereis(RedisBus), {
      :redix_pubsub,
      self(),
      make_ref(),
      :message,
      %{channel: "mock:test:events", payload: self_origin_payload}
    })

    refute_receive {:comet_event, %{"text" => "self-origin"}}, 20
  end

  test "RedisBus delivers remote events before slow store refresh completes" do
    start_mock_redis()
    terminate_redis_bus()
    restart_redis_bus()

    {:ok, _} = OpenChat.PubSub.subscribe({:user, "slow-refresh"})
    MockRedis.force_pipeline({:sleep, 150, {:ok, []}})

    remote_payload =
      Jason.encode!(%{
        "origin" => "remote",
        "keys" => [["user", "slow-refresh"]],
        "event" => %{"text" => "do not block websocket delivery"},
        "system" => false
      })

    started = System.monotonic_time()

    send(Process.whereis(RedisBus), {
      :redix_pubsub,
      self(),
      make_ref(),
      :message,
      %{channel: "mock:test:events", payload: remote_payload}
    })

    assert_receive {:comet_event, %{"text" => "do not block websocket delivery"}}, 75

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    assert elapsed_ms < 100
    Process.sleep(180)
  end

  test "PubSub locally delivers even when Redis publish fails" do
    start_mock_redis()
    terminate_redis_bus()
    restart_redis_bus()

    {:ok, _} = OpenChat.PubSub.subscribe({:user, "ordered"})

    assert :ok = OpenChat.PubSub.broadcast({:user, "ordered"}, %{"text" => "first"})
    assert_receive {:comet_event, %{"text" => "first"}}
    assert [{_channel, payload}] = wait_for_published(1, OpenChat.RedisBusPublisher)
    assert Jason.decode!(payload)["event"] == %{"text" => "first"}

    MockRedis.force_command({:sleep, 150, {:error, :publish_down}}, OpenChat.RedisBusPublisher)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = OpenChat.PubSub.broadcast({:user, "ordered"}, %{"text" => "local-only"})
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 50

    assert_receive {:comet_event, %{"text" => "local-only"}}
    :sys.get_state(RedisBus)
  end

  test "RedisBus init handles already-started and failed pubsub clients" do
    start_mock_redis()
    {:ok, pubsub} = MockRedis.PubSub.start_link("mock://redis", name: OpenChat.RedisPubSub)

    assert {:ok, %{pubsub: ^pubsub}} = RedisBus.init([])

    assert {:error, {:already_started, _pid}} =
             MockRedis.AlreadyStartedClient.start_link("mock://redis", name: OpenChat.Redis)

    stop_name(OpenChat.RedisPubSub)
    Application.put_env(:open_chat, :redis_pubsub_client, MockRedis.FailingPubSub)

    assert {:ok, %{pubsub: nil}} = RedisBus.init([])
    assert {:ok, _ref} = MockRedis.FailingPubSub.subscribe(self(), "channel", self())
  end

  defp start_mock_redis do
    case Process.whereis(OpenChat.Redis) do
      nil -> {:ok, _pid} = MockRedis.start_link("mock://redis", name: OpenChat.Redis)
      _pid -> :ok
    end
  end

  defp wait_for_published(count, conn), do: wait_for_published(count, conn, 50)
  defp wait_for_published(_count, _conn, 0), do: flunk("timed out waiting for mock Redis publish")

  defp wait_for_published(count, conn, attempts) do
    published = MockRedis.published(conn)

    if length(published) >= count do
      Enum.take(published, count)
    else
      Process.sleep(10)
      wait_for_published(count, conn, attempts - 1)
    end
  end

  defp terminate_redis_bus do
    case Process.whereis(RedisBus) do
      nil -> :ok
      _pid -> Supervisor.terminate_child(OpenChat.Supervisor, RedisBus)
    end
  end

  defp restart_redis_bus do
    case Supervisor.restart_child(OpenChat.Supervisor, RedisBus) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :running} -> :ok
      {:error, :restarting} -> :ok
    end
  end

  defp stop_name(name) do
    if pid = Process.whereis(name) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, {:noproc, _} -> :ok
        :exit, :noproc -> :ok
      end

      wait_until_stopped(name)
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
end
