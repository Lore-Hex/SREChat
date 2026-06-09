defmodule OpenChat.Store.RedisPersistence do
  @moduledoc false

  require Logger

  alias OpenChat.{Config, RedisClient}

  @buckets [
    "users",
    "tokens",
    "groups",
    "members",
    "messages",
    "conversation_messages",
    "conversation_latest",
    "thread_messages",
    "reads",
    "delivered",
    "hidden_conversations",
    "reactions",
    "blocks",
    "banned",
    "message_muids",
    "user_conversations",
    "conversation_users",
    "user_groups",
    "unread_counts"
  ]

  @counters ["next_id", "next_reaction_id"]
  @version "7"
  @lock_ttl_ms 10_000
  @lock_attempts 100
  @atomic_write_script """
  local prefix = ARGV[1]
  local version = ARGV[2]
  local ops = cjson.decode(ARGV[3])

  local function key(...)
    local parts = {prefix, ...}
    return table.concat(parts, ":")
  end

  for i = 1, #ops do
    local op = ops[i]

    if op["op"] == "put" then
      redis.call("SET", key(op["bucket"], op["id"]), op["value"])
      redis.call("SADD", key("index", op["bucket"]), op["id"])
    elseif op["op"] == "delete" then
      redis.call("DEL", key(op["bucket"], op["id"]))
      redis.call("SREM", key("index", op["bucket"]), op["id"])
    elseif op["op"] == "counter" then
      local current = redis.call("GET", key("counter", op["counter"]))
      local current_number = tonumber(current)
      local candidate = tonumber(op["value"]) or 1

      if not current_number or current_number < candidate then
        redis.call("SET", key("counter", op["counter"]), tostring(candidate))
      end
    else
      error("unknown Redis write op: " .. tostring(op["op"]))
    end
  end

  redis.call("SET", key("meta", "version"), version)
  return redis.call("INCR", key("meta", "revision"))
  """

  def load_or_seed(default_state, seed_fun) do
    case Config.redis_url() do
      nil ->
        seed_fun.()

      "" ->
        seed_fun.()

      url ->
        case start_redis(url) do
          {:ok, _pid} -> load(default_state, seed_fun)
          {:error, reason} -> redis_failed("connection", reason, seed_fun)
        end
    end
  end

  def enabled?, do: Process.whereis(OpenChat.Redis) != nil

  def configured? do
    case Config.redis_url() do
      url when is_binary(url) -> url != ""
      _other -> false
    end
  end

  def refresh(default_state, fallback_state) do
    if enabled?() do
      case command(["GET", revision_key()]) do
        {:ok, nil} -> fallback_state
        {:ok, revision} -> maybe_refresh_state(default_state, fallback_state, to_int(revision))
        {:error, reason} -> redis_failed("state refresh", reason, fn -> fallback_state end)
      end
    else
      fallback_state
    end
  end

  def refresh_keys(default_state, fallback_state, keys) do
    if enabled?() do
      keys = normalize_refresh_keys(keys)

      cond do
        keys == [] -> fallback_state
        true -> refresh_records(default_state, fallback_state, keys)
      end
    else
      fallback_state
    end
  end

  def with_lock(fun) when is_function(fun, 0) do
    with_locks([:global], fun)
  end

  def with_locks(scopes, fun) when is_function(fun, 0) do
    cond do
      enabled?() ->
        scopes = normalize_lock_scopes(scopes)
        lock_value = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

        case acquire_locks(scopes, lock_value, []) do
          {:ok, acquired} ->
            try do
              fun.()
            after
              release_locks(acquired, lock_value)
            end

          {:error, reason} ->
            raise "Redis lock failed for #{inspect(scopes)}: #{inspect(reason)}"
        end

      configured?() ->
        raise "Redis lock failed for #{inspect(scopes)}: Redis is configured but unavailable"

      true ->
        fun.()
    end
  end

  def take_counter(name, fallback_next) do
    cond do
      enabled?() ->
        script = """
        local current = redis.call("GET", KEYS[1])
        if not current then
          current = ARGV[1]
        end
        current = tonumber(current) or tonumber(ARGV[1]) or 1
        redis.call("SET", KEYS[1], current + 1)
        redis.call("SET", KEYS[2], ARGV[2])
        redis.call("INCR", KEYS[3])
        return current
        """

        case command([
               "EVAL",
               script,
               "3",
               counter_key(name),
               meta_key(),
               revision_key(),
               to_s(fallback_next),
               @version
             ]) do
          {:ok, value} ->
            to_int(value)

          {:error, reason} ->
            raise "Redis counter allocation failed for #{inspect(name)}: #{inspect(reason)}"
        end

      configured?() ->
        raise "Redis counter allocation failed for #{inspect(name)}: Redis is configured but unavailable"

      true ->
        to_int(fallback_next)
    end
  end

  def write([]), do: :ok

  def write(ops) do
    cond do
      enabled?() ->
        ops
        |> List.wrap()
        |> Enum.flat_map(&atomic_op/1)
        |> atomic_write()

      configured?() ->
        {:error, :redis_unavailable}

      true ->
        :ok
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, reason}
  end

  def replace_all(state) do
    cond do
      enabled?() ->
        delete_prefix_commands()
        |> Kernel.++(state_commands(state))
        |> Kernel.++([["SET", meta_key(), @version]])
        |> Kernel.++([["INCR", revision_key()]])
        |> run_pipeline()
        |> remember_pipeline_full_revision()

      configured?() ->
        {:error, :redis_unavailable}

      true ->
        :ok
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, reason}
  end

  def message_conversation_locks(id) do
    id = to_s(id)

    cond do
      id == "" ->
        []

      not enabled?() and not configured?() ->
        []

      not enabled?() ->
        raise "Redis message #{inspect(id)} lock lookup failed: Redis is configured but unavailable"

      true ->
        case command(["GET", record_key("messages", id)]) do
          {:ok, nil} ->
            []

          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"conversationId" => conv_id}} when is_binary(conv_id) and conv_id != "" ->
                [{:conversation, conv_id}]

              {:ok, _message} ->
                raise "Redis message #{inspect(id)} is missing conversationId"

              {:error, reason} ->
                raise "Redis message #{inspect(id)} could not be decoded: #{inspect(reason)}"
            end

          {:error, reason} ->
            raise "Redis message #{inspect(id)} lock lookup failed: #{inspect(reason)}"
        end
    end
  end

  def put(bucket, id, value), do: {:put, to_s(bucket), to_s(id), value}
  def delete(bucket, id), do: {:delete, to_s(bucket), to_s(id)}
  def counter(name, value), do: {:counter, to_s(name), value}

  def put_or_delete(bucket, id, value) when value in [nil, %{}, []],
    do: delete(bucket, id)

  def put_or_delete(bucket, id, value), do: put(bucket, id, value)

  def buckets, do: @buckets
  def counters, do: @counters

  defp start_redis(url) do
    case Process.whereis(OpenChat.Redis) do
      nil ->
        case RedisClient.start_link(url, name: OpenChat.Redis) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  defp load(default_state, seed_fun) do
    case command(["GET", meta_key()]) do
      {:ok, nil} -> load_legacy_snapshot_or_seed(default_state, seed_fun)
      {:ok, _version} -> read_state(default_state)
      {:error, reason} -> redis_failed("key load", reason, seed_fun)
    end
  end

  defp load_legacy_snapshot_or_seed(default_state, seed_fun) do
    case command(["GET", Config.redis_snapshot_key()]) do
      {:ok, nil} ->
        state = seed_fun.()
        :ok = replace_all(state)
        state

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, state} ->
            state = Map.merge(default_state, state)
            :ok = replace_all(state)
            state

          {:error, reason} ->
            redis_failed("legacy snapshot decode", reason, seed_fun)
        end

      {:error, reason} ->
        redis_failed("legacy snapshot load", reason, seed_fun)
    end
  end

  defp read_state(default_state) do
    state =
      Enum.reduce(@buckets, default_state, fn bucket, acc ->
        Map.put(acc, bucket, read_bucket(bucket))
      end)

    state =
      Enum.reduce(@counters, state, fn counter, acc ->
        case command(["GET", counter_key(counter)]) do
          {:ok, nil} -> acc
          {:ok, value} -> Map.put(acc, counter, max(to_int(value), default_state[counter]))
          {:error, _reason} -> acc
        end
      end)

    remember_remote_full_revision()
    state
  end

  defp maybe_refresh_state(_default_state, fallback_state, revision) when revision == 0 do
    fallback_state
  end

  defp maybe_refresh_state(default_state, fallback_state, revision) do
    if revision == local_full_revision() do
      fallback_state
    else
      read_state(default_state)
    end
  end

  defp remember_remote_full_revision do
    case command(["GET", revision_key()]) do
      {:ok, revision} -> remember_full_revision(revision)
      _ -> :ok
    end
  end

  defp remember_pipeline_full_revision({:ok, results}) do
    results
    |> List.last()
    |> remember_full_revision()

    :ok
  end

  defp remember_pipeline_full_revision({:error, reason}), do: {:error, reason}

  defp remember_full_revision(revision) do
    Process.put(:open_chat_redis_full_revision, to_int(revision))
    :ok
  end

  defp local_full_revision do
    Process.get(:open_chat_redis_full_revision, 0)
  end

  defp refresh_records(default_state, state, keys) do
    {record_keys, counter_keys, bucket_keys} =
      Enum.reduce(keys, {[], [], []}, fn
        {:record, bucket, id}, {records, counters, buckets} ->
          {[{bucket, id} | records], counters, buckets}

        {:counter, counter}, {records, counters, buckets} ->
          {records, [counter | counters], buckets}

        {:bucket, bucket}, {records, counters, buckets} ->
          {records, counters, [bucket | buckets]}

        _other, acc ->
          acc
      end)

    record_keys = Enum.uniq(record_keys)
    bucket_keys = Enum.uniq(bucket_keys)

    state =
      state
      |> read_records(record_keys)
      |> read_buckets(bucket_keys)

    related_keys = Enum.uniq(record_keys ++ bucket_record_keys(state, bucket_keys))

    state
    |> read_related_token_users(related_keys)
    |> read_related_member_users(related_keys)
    |> read_related_membership_indexes(related_keys)
    |> read_related_user_groups(related_keys)
    |> read_related_conversation_indexes(related_keys)
    |> read_related_messages(related_keys)
    |> read_related_message_participants(related_keys)
    |> read_counters(default_state, Enum.uniq(counter_keys))
  end

  defp read_records(state, []), do: state

  defp read_records(state, record_keys) do
    commands = Enum.map(record_keys, fn {bucket, id} -> ["GET", record_key(bucket, id)] end)

    case RedisClient.pipeline(OpenChat.Redis, commands) do
      {:ok, results} ->
        record_keys
        |> Enum.zip(results)
        |> Enum.reduce(state, fn {{bucket, id}, result}, acc ->
          apply_record_result(acc, bucket, id, result)
        end)

      {:error, reason} ->
        Logger.warning("Redis targeted refresh failed: #{inspect(reason)}")
        state
    end
  end

  defp read_buckets(state, []), do: state

  defp read_buckets(state, buckets) do
    Enum.reduce(buckets, state, fn bucket, acc ->
      Map.put(acc, bucket, read_bucket(bucket))
    end)
  end

  defp bucket_record_keys(state, buckets) do
    buckets
    |> Enum.flat_map(fn bucket ->
      state
      |> Map.get(bucket, %{})
      |> Map.keys()
      |> Enum.map(&{bucket, &1})
    end)
  end

  defp read_related_messages(state, record_keys) do
    message_keys =
      record_keys
      |> Enum.filter(fn {bucket, _id} ->
        bucket in [
          "conversation_messages",
          "conversation_latest",
          "thread_messages",
          "message_muids"
        ]
      end)
      |> Enum.flat_map(fn {bucket, id} -> state |> get_in([bucket, id]) |> List.wrap() end)
      |> Enum.map(&{"messages", to_s(&1)})
      |> Enum.reject(fn {_bucket, id} -> id == "" end)
      |> Enum.reject(&(&1 in record_keys))
      |> Enum.uniq()

    state
    |> read_records(message_keys)
    |> read_related_reactions(message_keys)
    |> read_related_message_participants(message_keys)
  end

  defp read_related_reactions(state, message_keys) do
    reaction_keys =
      message_keys
      |> Enum.map(fn {_bucket, id} -> {"reactions", to_s(id)} end)
      |> Enum.reject(fn {_bucket, id} -> id == "" end)
      |> Enum.uniq()

    read_records(state, reaction_keys)
  end

  defp read_related_token_users(state, record_keys) do
    user_keys =
      record_keys
      |> Enum.filter(fn {bucket, _id} -> bucket == "tokens" end)
      |> Enum.map(fn {_bucket, token} -> get_in(state, ["tokens", token]) end)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(&{"users", to_s(&1)})
      |> Enum.reject(&(&1 in record_keys))
      |> Enum.uniq()

    read_records(state, user_keys)
  end

  defp read_related_member_users(state, record_keys) do
    user_keys =
      record_keys
      |> Enum.filter(fn {bucket, _id} -> bucket in ["members", "banned", "blocks"] end)
      |> Enum.flat_map(fn {bucket, id} ->
        state
        |> get_in([bucket, id])
        |> case do
          map when is_map(map) -> Map.keys(map)
          _other -> []
        end
      end)
      |> Enum.map(&{"users", to_s(&1)})
      |> Enum.reject(&(&1 in record_keys))
      |> Enum.uniq()

    read_records(state, user_keys)
  end

  defp read_related_membership_indexes(state, record_keys) do
    user_group_keys =
      record_keys
      |> Enum.filter(fn {bucket, _id} -> bucket == "members" end)
      |> Enum.flat_map(fn {_bucket, guid} ->
        state
        |> get_in(["members", guid])
        |> case do
          map when is_map(map) -> Map.keys(map)
          _other -> []
        end
      end)
      |> Enum.map(&{"user_groups", to_s(&1)})
      |> Enum.reject(fn {_bucket, uid} -> uid == "" end)
      |> Enum.reject(&(&1 in record_keys))
      |> Enum.uniq()

    read_records(state, user_group_keys)
  end

  defp read_related_user_groups(state, record_keys) do
    group_keys =
      record_keys
      |> Enum.filter(fn {bucket, _id} -> bucket == "user_groups" end)
      |> Enum.flat_map(fn {_bucket, uid} ->
        state |> get_in(["user_groups", uid]) |> List.wrap()
      end)
      |> Enum.flat_map(fn guid ->
        guid = to_s(guid)

        [
          {"groups", guid},
          {"members", guid},
          {"banned", guid},
          {"conversation_latest", "group_#{guid}"},
          {"conversation_users", "group_#{guid}"}
        ]
      end)
      |> Enum.reject(fn {_bucket, id} -> id == "" end)
      |> Enum.reject(&(&1 in record_keys))
      |> Enum.uniq()

    state =
      state
      |> read_records(group_keys)
      |> read_related_membership_indexes(group_keys)

    state
    |> read_related_messages(group_keys)
    |> read_related_conversation_indexes(group_keys)
  end

  defp read_related_conversation_indexes(state, record_keys) do
    conversation_ids =
      record_keys
      |> Enum.flat_map(fn
        {"user_conversations", uid} ->
          state |> get_in(["user_conversations", uid]) |> List.wrap()

        {"conversation_users", conv_id} ->
          [conv_id]

        _other ->
          []
      end)
      |> Enum.map(&to_s/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    conversation_keys =
      conversation_ids
      |> Enum.flat_map(fn conv_id ->
        [
          {"conversation_latest", conv_id},
          {"conversation_users", conv_id}
        ]
      end)
      |> Enum.reject(&(&1 in record_keys))
      |> Enum.uniq()

    state =
      state
      |> read_records(conversation_keys)
      |> read_related_messages(conversation_keys)

    user_keys =
      conversation_ids
      |> Enum.flat_map(fn conv_id ->
        state |> get_in(["conversation_users", conv_id]) |> List.wrap()
      end)
      |> Enum.map(&to_s/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.flat_map(fn uid ->
        [
          {"users", uid},
          {"reads", uid},
          {"delivered", uid},
          {"hidden_conversations", uid},
          {"user_conversations", uid},
          {"unread_counts", uid}
        ]
      end)
      |> Enum.reject(&(&1 in record_keys))
      |> Enum.uniq()

    read_records(state, user_keys)
  end

  defp read_related_message_participants(state, record_keys) do
    participant_keys =
      record_keys
      |> Enum.filter(fn {bucket, _id} -> bucket == "messages" end)
      |> Enum.flat_map(fn {_bucket, id} ->
        case get_in(state, ["messages", id]) do
          %{"receiverType" => "group", "receiver" => guid, "sender" => sender} ->
            [{"users", sender}, {"groups", guid}, {"members", guid}, {"unread_counts", sender}]

          %{"receiver" => receiver, "sender" => sender} ->
            [
              {"users", sender},
              {"users", receiver},
              {"unread_counts", sender},
              {"unread_counts", receiver}
            ]

          _other ->
            []
        end
      end)
      |> Enum.reject(&(&1 in record_keys))
      |> Enum.uniq()

    read_records(state, participant_keys)
  end

  defp read_counters(state, _default_state, []), do: state

  defp read_counters(state, default_state, counters) do
    commands = Enum.map(counters, fn counter -> ["GET", counter_key(counter)] end)

    case RedisClient.pipeline(OpenChat.Redis, commands) do
      {:ok, results} ->
        counters
        |> Enum.zip(results)
        |> Enum.reduce(state, fn {counter, value}, acc ->
          Map.put(acc, counter, max(to_int(value), default_state[counter] || 1))
        end)

      {:error, reason} ->
        Logger.warning("Redis counter refresh failed: #{inspect(reason)}")
        state
    end
  end

  defp apply_record_result(state, bucket, id, nil) do
    update_in(state, [bucket], &Map.delete(&1 || %{}, id))
  end

  defp apply_record_result(state, bucket, id, json) do
    case Jason.decode(json) do
      {:ok, value} -> put_in(state, [bucket, id], value)
      {:error, _reason} -> state
    end
  end

  defp read_bucket(bucket) do
    with {:ok, ids} <- command(["SMEMBERS", index_key(bucket)]) do
      Enum.reduce(ids, %{}, fn id, acc ->
        case command(["GET", record_key(bucket, id)]) do
          {:ok, nil} ->
            acc

          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, value} -> Map.put(acc, id, value)
              {:error, _reason} -> acc
            end

          {:error, _reason} ->
            acc
        end
      end)
    else
      _ -> %{}
    end
  end

  defp record_put_commands(bucket, id, value) do
    [
      ["SET", record_key(bucket, id), Jason.encode!(value)],
      ["SADD", index_key(bucket), id]
    ]
  end

  defp atomic_op({:put, bucket, id, value}) do
    [
      %{
        "op" => "put",
        "bucket" => to_s(bucket),
        "id" => to_s(id),
        "value" => Jason.encode!(value)
      }
    ]
  end

  defp atomic_op({:delete, bucket, id}) do
    [%{"op" => "delete", "bucket" => to_s(bucket), "id" => to_s(id)}]
  end

  defp atomic_op({:counter, counter, value}) do
    [%{"op" => "counter", "counter" => to_s(counter), "value" => to_s(value)}]
  end

  defp atomic_op(_op), do: []

  defp atomic_write([]), do: :ok

  defp atomic_write(ops) do
    case command([
           "EVAL",
           @atomic_write_script,
           "0",
           Config.redis_key_prefix(),
           @version,
           Jason.encode!(ops)
         ]) do
      {:ok, revision} ->
        remember_full_revision(revision)
        :ok

      {:error, reason} ->
        Logger.warning("Redis atomic persist failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp state_commands(state) do
    bucket_commands =
      @buckets
      |> Enum.flat_map(fn bucket ->
        state
        |> Map.get(bucket, %{})
        |> Enum.flat_map(fn {id, value} -> record_put_commands(bucket, id, value) end)
      end)

    counter_commands =
      Enum.map(@counters, fn counter ->
        ["SET", counter_key(counter), to_s(Map.get(state, counter, 1))]
      end)

    bucket_commands ++ counter_commands
  end

  defp delete_prefix_commands(cursor \\ "0", commands \\ []) do
    case command(["SCAN", cursor, "MATCH", "#{Config.redis_key_prefix()}:*", "COUNT", "1000"]) do
      {:ok, [next_cursor, []]} when next_cursor != "0" ->
        delete_prefix_commands(next_cursor, commands)

      {:ok, [_next_cursor, []]} ->
        commands

      {:ok, [next_cursor, keys]} when next_cursor != "0" ->
        keys = Enum.reject(keys, &lock_key?/1)
        delete_prefix_commands(next_cursor, delete_command(keys, commands))

      {:ok, [_next_cursor, keys]} ->
        keys = Enum.reject(keys, &lock_key?/1)
        delete_command(keys, commands)

      {:error, reason} ->
        Logger.warning("Redis prefix scan failed: #{inspect(reason)}")
        commands
    end
  end

  defp run_pipeline([]), do: {:ok, []}

  defp run_pipeline(commands) do
    case RedisClient.pipeline(OpenChat.Redis, commands) do
      {:ok, results} ->
        {:ok, results}

      {:error, reason} ->
        Logger.warning("Redis pipeline failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp delete_command([], commands), do: commands
  defp delete_command(keys, commands), do: [["DEL" | keys] | commands]

  defp acquire_locks([], _lock_value, acquired), do: {:ok, acquired}

  defp acquire_locks([scope | rest], lock_value, acquired) do
    case acquire_lock(scope, lock_value, @lock_attempts) do
      :ok ->
        acquire_locks(rest, lock_value, [scope | acquired])

      {:error, reason} ->
        release_locks(acquired, lock_value)
        {:error, {scope, reason}}
    end
  end

  defp acquire_lock(_scope, _lock_value, 0), do: {:error, :timeout}

  defp acquire_lock(scope, lock_value, attempts) do
    case command(["SET", lock_key(scope), lock_value, "NX", "PX", to_s(@lock_ttl_ms)]) do
      {:ok, "OK"} ->
        :ok

      {:ok, nil} ->
        Process.sleep(50)
        acquire_lock(scope, lock_value, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_locks(scopes, lock_value) do
    Enum.each(scopes, &release_lock(&1, lock_value))
    :ok
  end

  defp release_lock(scope, lock_value) do
    script = """
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("DEL", KEYS[1])
    else
      return 0
    end
    """

    command(["EVAL", script, "1", lock_key(scope), lock_value])
    :ok
  end

  defp redis_failed(context, reason, seed_fun) do
    Logger.warning("Redis #{context} failed: #{inspect(reason)}; using seeds")
    seed_fun.()
  end

  defp normalize_refresh_keys(keys) do
    keys
    |> List.wrap()
    |> Enum.flat_map(fn
      {:counter, counter} ->
        [{:counter, to_s(counter)}]

      {:bucket, bucket} ->
        normalize_bucket_key(bucket)

      {:record, bucket, id} ->
        normalize_record_key(bucket, id)

      {bucket, id} ->
        normalize_record_key(bucket, id)

      _other ->
        []
    end)
    |> Enum.uniq()
  end

  defp normalize_record_key(bucket, id) do
    bucket = to_s(bucket)
    id = to_s(id)

    if bucket in @buckets and id != "" do
      [{:record, bucket, id}]
    else
      []
    end
  end

  defp normalize_bucket_key(bucket) do
    bucket = to_s(bucket)

    if bucket in @buckets do
      [{:bucket, bucket}]
    else
      []
    end
  end

  defp normalize_lock_scopes(scopes) do
    scopes
    |> List.wrap()
    |> Enum.map(&lock_scope_parts/1)
    |> Enum.reject(&(&1 == []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp lock_scope_parts(:global), do: ["global"]
  defp lock_scope_parts({type, id}), do: [type, id] |> Enum.map(&to_s/1)
  defp lock_scope_parts({type, a, b}), do: [type, a, b] |> Enum.map(&to_s/1)
  defp lock_scope_parts(scope) when is_list(scope), do: Enum.map(scope, &to_s/1)
  defp lock_scope_parts(scope), do: [to_s(scope)]

  defp command(args), do: RedisClient.command(OpenChat.Redis, args)

  defp key(parts),
    do: [Config.redis_key_prefix() | parts] |> Enum.map(&to_s/1) |> Enum.join(":")

  defp meta_key, do: key(["meta", "version"])
  defp revision_key, do: key(["meta", "revision"])
  defp lock_key(scope), do: key(["lock" | scope])
  defp lock_key?(redis_key), do: String.starts_with?(redis_key, key(["lock"]) <> ":")
  defp index_key(bucket), do: key(["index", bucket])
  defp record_key(bucket, id), do: key([bucket, id])
  defp counter_key(counter), do: key(["counter", counter])

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_int(value), do: value |> to_s() |> to_int()
end
