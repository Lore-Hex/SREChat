defmodule OpenChat.MockRedis do
  @moduledoc false

  use Agent

  def start_link(_url, opts) do
    Agent.start_link(
      fn ->
        %{
          strings: %{},
          sets: %{},
          command_responses: :queue.new(),
          pipeline_responses: :queue.new(),
          published: []
        }
      end,
      opts
    )
  end

  def command(conn, command) do
    conn
    |> Agent.get_and_update(fn state ->
      {reply, state} = maybe_forced(:command_responses, command, state, &apply_command/2)
      {reply, state}
    end)
    |> maybe_raise()
  end

  def pipeline(conn, commands) do
    conn
    |> Agent.get_and_update(fn state ->
      case pop_forced(:pipeline_responses, state) do
        {{:value, response}, state} ->
          {response, state}

        {:empty, state} ->
          {results, state} =
            Enum.map_reduce(commands, state, fn command, acc ->
              {{:ok, value}, acc} = apply_command(command, acc)
              {value, acc}
            end)

          {{:ok, results}, state}
      end
    end)
    |> maybe_raise()
  end

  def force_command(response), do: push_response(:command_responses, response)
  def force_pipeline(response), do: push_response(:pipeline_responses, response)

  def published do
    Agent.get(OpenChat.Redis, &Enum.reverse(&1.published))
  end

  def put_string(key, value) do
    Agent.update(OpenChat.Redis, &put_in(&1, [:strings, key], value))
  end

  def strings do
    Agent.get(OpenChat.Redis, & &1.strings)
  end

  def sets do
    Agent.get(OpenChat.Redis, & &1.sets)
  end

  defp push_response(queue_key, response) do
    Agent.update(OpenChat.Redis, fn state ->
      update_in(state, [queue_key], &:queue.in(response, &1))
    end)
  end

  defp maybe_forced(queue_key, command, state, fallback) do
    case pop_forced(queue_key, state) do
      {{:value, response}, state} -> {response, state}
      {:empty, state} -> fallback.(command, state)
    end
  end

  defp pop_forced(queue_key, state) do
    case :queue.out(state[queue_key]) do
      {{:value, response}, queue} -> {{:value, response}, Map.put(state, queue_key, queue)}
      {:empty, queue} -> {:empty, Map.put(state, queue_key, queue)}
    end
  end

  defp maybe_raise({:raise, message}) when is_binary(message), do: raise(message)
  defp maybe_raise(response), do: response

  defp apply_command(["GET", key], state) do
    {{:ok, Map.get(state.strings, key)}, state}
  end

  defp apply_command(["SET", key, value, "NX", "PX", _ttl_ms], state) do
    if Map.has_key?(state.strings, key) do
      {{:ok, nil}, state}
    else
      {{:ok, "OK"}, put_in(state, [:strings, key], value)}
    end
  end

  defp apply_command(["SET", key, value], state) do
    {{:ok, "OK"}, put_in(state, [:strings, key], value)}
  end

  defp apply_command(["INCR", key], state) do
    value = state.strings |> Map.get(key, "0") |> to_int() |> Kernel.+(1)
    {{:ok, value}, put_in(state, [:strings, key], to_string(value))}
  end

  defp apply_command(["DEL" | keys], state) do
    keys = List.wrap(keys)
    deleted = Enum.count(keys, &(Map.has_key?(state.strings, &1) or Map.has_key?(state.sets, &1)))

    state =
      keys
      |> Enum.reduce(state, fn key, acc ->
        acc
        |> update_in([:strings], &Map.delete(&1, key))
        |> update_in([:sets], &Map.delete(&1, key))
      end)

    {{:ok, deleted}, state}
  end

  defp apply_command(["SADD", key | values], state) do
    set = Map.get(state.sets, key, MapSet.new())
    updated = Enum.reduce(values, set, &MapSet.put(&2, &1))
    {{:ok, MapSet.size(updated) - MapSet.size(set)}, put_in(state, [:sets, key], updated)}
  end

  defp apply_command(["SREM", key | values], state) do
    set = Map.get(state.sets, key, MapSet.new())
    updated = Enum.reduce(values, set, &MapSet.delete(&2, &1))
    {{:ok, MapSet.size(set) - MapSet.size(updated)}, put_in(state, [:sets, key], updated)}
  end

  defp apply_command(["SMEMBERS", key], state) do
    members =
      state.sets
      |> Map.get(key, MapSet.new())
      |> MapSet.to_list()
      |> Enum.sort()

    {{:ok, members}, state}
  end

  defp apply_command(["SCAN", _cursor, "MATCH", pattern, "COUNT", _count], state) do
    prefix = String.trim_trailing(pattern, "*")

    keys =
      (Map.keys(state.strings) ++ Map.keys(state.sets))
      |> Enum.uniq()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    {{:ok, ["0", keys]}, state}
  end

  defp apply_command(["PUBLISH", channel, payload], state) do
    {{:ok, 0}, update_in(state, [:published], &[{channel, payload} | &1])}
  end

  defp apply_command(["EVAL", _script, "0", prefix, version, encoded_ops], state) do
    {:ok, ops} = Jason.decode(encoded_ops)

    state =
      Enum.reduce(ops, state, fn
        %{"op" => "put", "bucket" => bucket, "id" => id, "value" => value}, acc ->
          acc
          |> put_in([:strings, key(prefix, [bucket, id])], value)
          |> update_in([:sets, key(prefix, ["index", bucket])], fn set ->
            MapSet.put(set || MapSet.new(), id)
          end)

        %{"op" => "delete", "bucket" => bucket, "id" => id}, acc ->
          acc
          |> update_in([:strings], &Map.delete(&1, key(prefix, [bucket, id])))
          |> update_in([:sets, key(prefix, ["index", bucket])], fn set ->
            MapSet.delete(set || MapSet.new(), id)
          end)

        %{"op" => "counter", "counter" => counter, "value" => value}, acc ->
          counter_key = key(prefix, ["counter", counter])
          current = acc.strings |> Map.get(counter_key) |> to_int()
          candidate = to_int(value)

          if current < candidate do
            put_in(acc, [:strings, counter_key], to_string(candidate))
          else
            acc
          end
      end)
      |> put_in([:strings, key(prefix, ["meta", "version"])], version)

    {revision, state} = incr(state, key(prefix, ["meta", "revision"]))
    {{:ok, revision}, state}
  end

  defp apply_command(
         ["EVAL", script, "3", counter_key, meta_key, revision_key, fallback, version],
         state
       )
       when is_binary(script) do
    current = state.strings |> Map.get(counter_key, fallback) |> to_int()

    state =
      state
      |> put_in([:strings, counter_key], to_string(current + 1))
      |> put_in([:strings, meta_key], version)

    {_revision, state} = incr(state, revision_key)
    {{:ok, current}, state}
  end

  defp apply_command(["EVAL", script, "1", key, value], state) when is_binary(script) do
    if String.contains?(script, "redis.call(\"GET\", KEYS[1]) == ARGV[1]") do
      if Map.get(state.strings, key) == value do
        {{:ok, 1}, update_in(state, [:strings], &Map.delete(&1, key))}
      else
        {{:ok, 0}, state}
      end
    else
      {{:error, {:unsupported, ["EVAL", script, "1", key, value]}}, state}
    end
  end

  defp apply_command(command, state), do: {{:error, {:unsupported, command}}, state}

  defp incr(state, key) do
    value = state.strings |> Map.get(key, "0") |> to_int() |> Kernel.+(1)
    {value, put_in(state, [:strings, key], to_string(value))}
  end

  defp key(prefix, parts), do: Enum.join([prefix | parts], ":")

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end
end

defmodule OpenChat.MockRedis.AlreadyStartedClient do
  @moduledoc false

  def start_link(url, opts) do
    case OpenChat.MockRedis.start_link(url, opts) do
      {:ok, pid} -> {:error, {:already_started, pid}}
      {:error, {:already_started, pid}} -> {:error, {:already_started, pid}}
    end
  end

  def command(conn, command), do: OpenChat.MockRedis.command(conn, command)
  def pipeline(conn, commands), do: OpenChat.MockRedis.pipeline(conn, commands)
end

defmodule OpenChat.MockRedis.FailingClient do
  @moduledoc false

  def start_link(_url, _opts), do: {:error, :mock_connection_down}
  def command(_conn, _command), do: {:error, :mock_connection_down}
  def pipeline(_conn, _commands), do: {:error, :mock_connection_down}
end

defmodule OpenChat.MockRedis.PubSub do
  @moduledoc false

  use Agent

  def start_link(_url, opts) do
    Agent.start_link(fn -> %{subscriptions: []} end, opts)
  end

  def subscribe(pubsub, channel, receiver) do
    Agent.update(pubsub, fn state ->
      update_in(state, [:subscriptions], &[{channel, receiver} | &1])
    end)

    {:ok, make_ref()}
  end
end

defmodule OpenChat.MockRedis.FailingPubSub do
  @moduledoc false

  def start_link(_url, _opts), do: {:error, :mock_pubsub_down}
  def subscribe(_pubsub, _channel, _receiver), do: {:ok, make_ref()}
end
