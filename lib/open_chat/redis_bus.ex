defmodule OpenChat.RedisBus do
  @moduledoc false

  use GenServer
  require Logger

  alias OpenChat.{Config, Observability, RedisClient}
  alias OpenChat.RedisBus.PublisherLane

  @publisher_names [
    OpenChat.RedisBusPublisher,
    OpenChat.RedisBusPublisher1,
    OpenChat.RedisBusPublisher2,
    OpenChat.RedisBusPublisher3,
    OpenChat.RedisBusPublisher4,
    OpenChat.RedisBusPublisher5,
    OpenChat.RedisBusPublisher6,
    OpenChat.RedisBusPublisher7,
    OpenChat.RedisBusPublisher8,
    OpenChat.RedisBusPublisher9,
    OpenChat.RedisBusPublisher10,
    OpenChat.RedisBusPublisher11,
    OpenChat.RedisBusPublisher12,
    OpenChat.RedisBusPublisher13,
    OpenChat.RedisBusPublisher14,
    OpenChat.RedisBusPublisher15
  ]

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def publish(keys, event) do
    call_publish({:publish, List.wrap(keys), event})
  end

  def publish_system(keys, event) do
    call_publish({:publish_system, List.wrap(keys), event})
  end

  def publish_async(keys, event) do
    cast_publish({
      :publish_async,
      List.wrap(keys),
      event,
      System.monotonic_time(),
      System.system_time(:millisecond)
    })
  end

  def publish_system_async(keys, event) do
    cast_publish({
      :publish_system_async,
      List.wrap(keys),
      event,
      System.monotonic_time(),
      System.system_time(:millisecond)
    })
  end

  @doc false
  def publisher_connections do
    case Process.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :publisher_connections)
    end
  catch
    :exit, _reason -> []
  end

  @doc false
  def configured_publisher_names, do: @publisher_names

  @doc false
  def publisher_lane_index(keys, event, lane_count) when lane_count > 0 do
    route = publisher_route(List.wrap(keys), event)
    :erlang.phash2(route, lane_count)
  end

  def publisher_lane_index(_keys, _event, _lane_count), do: 0

  defp call_publish(message) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        GenServer.call(pid, message, 5_000)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp cast_publish(message) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        GenServer.cast(pid, message)
        :ok
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(_opts) do
    state = %{
      channel: channel(),
      origin: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      publishers: [],
      pubsub: nil
    }

    case Config.redis_url() do
      url when is_binary(url) and url != "" ->
        state = %{state | publishers: start_publishers(url)}

        case RedisClient.pubsub_start_link(url, name: OpenChat.RedisPubSub) do
          {:ok, pubsub} ->
            {:ok, _ref} = RedisClient.pubsub_subscribe(pubsub, state.channel, self())
            {:ok, %{state | pubsub: pubsub}}

          {:error, {:already_started, pubsub}} ->
            {:ok, _ref} = RedisClient.pubsub_subscribe(pubsub, state.channel, self())
            {:ok, %{state | pubsub: pubsub}}

          {:error, reason} ->
            Logger.warning("Redis event bus disabled: #{inspect(reason)}")
            {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:publish, keys, event}, _from, state) do
    {:reply, publish_event_sync(state, keys, event, false), state}
  end

  def handle_call({:publish_system, keys, event}, _from, state) do
    {:reply, publish_event_sync(state, keys, event, true), state}
  end

  def handle_call(:publisher_connections, _from, state) do
    {:reply, Enum.map(state.publishers, & &1.connection), state}
  end

  @impl true
  def handle_cast({:publish_async, keys, event, enqueued_at, enqueued_wall_ms}, state) do
    publish_event_async(state, keys, event, false, enqueued_at, enqueued_wall_ms)
    {:noreply, state}
  end

  def handle_cast({:publish_system_async, keys, event, enqueued_at, enqueued_wall_ms}, state) do
    publish_event_async(state, keys, event, true, enqueued_at, enqueued_wall_ms)
    {:noreply, state}
  end

  defp publish_event_sync(state, keys, event, system?) do
    enqueued_at = System.monotonic_time()
    payload = encode_payload(state, keys, event, system?, System.system_time(:millisecond))

    case publisher_for(state.publishers, keys, event) do
      %{pid: pid} -> PublisherLane.publish_sync(pid, state.channel, payload, enqueued_at)
      nil -> :ok
    end
  end

  defp publish_event_async(state, keys, event, system?, enqueued_at, enqueued_wall_ms) do
    payload = encode_payload(state, keys, event, system?, enqueued_wall_ms)

    case publisher_for(state.publishers, keys, event) do
      %{pid: pid} -> PublisherLane.publish(pid, state.channel, payload, enqueued_at)
      nil -> Observability.increment("redis.publish.attempts", %{"outcome" => "disabled"})
    end

    :ok
  end

  defp encode_payload(state, keys, event, system?, published_at_ms) do
    Jason.encode!(%{
      "origin" => state.origin,
      "keys" => Enum.map(keys, &encode_key/1),
      "event" => event,
      "system" => system?,
      "publishedAtMs" => published_at_ms
    })
  end

  @impl true
  def handle_info(
        {:redix_pubsub, _pubsub, _ref, :message, %{channel: channel, payload: payload}},
        %{channel: channel} = state
      ) do
    with {:ok, %{"origin" => origin, "keys" => keys, "event" => event} = decoded} <-
           Jason.decode(payload),
         false <- origin == state.origin do
      keys = keys |> Enum.map(&decode_key/1) |> Enum.reject(&is_nil/1)
      record_delivery(decoded, event)

      if decoded["system"] == true do
        OpenChat.PubSub.local_system_broadcast(keys, event)
      else
        OpenChat.PubSub.local_broadcast(keys, event)
      end

      keys
      |> OpenChat.PubSub.local_subscribed_keys()
      |> refresh_store_async(event)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp refresh_store(keys, event) do
    OpenChat.Store.refresh_from_pubsub(keys, event)
  catch
    :exit, reason -> Logger.warning("Redis event store refresh failed: #{inspect(reason)}")
  end

  defp refresh_store_async([], _event), do: :ok

  defp refresh_store_async(keys, event) do
    Task.start(fn -> refresh_store(keys, event) end)
    :ok
  end

  defp channel, do: Config.redis_key_prefix() <> ":events"

  defp start_publishers(url) do
    @publisher_names
    |> Enum.take(Config.redis_publisher_lanes())
    |> Enum.with_index()
    |> Enum.reduce([], fn {connection_name, lane}, publishers ->
      case PublisherLane.start_link(url: url, connection_name: connection_name, lane: lane) do
        {:ok, pid} ->
          [%{pid: pid, connection: connection_name, lane: lane} | publishers]

        {:error, reason} ->
          Logger.warning("Redis event publisher lane=#{lane} disabled: #{inspect(reason)}")
          publishers
      end
    end)
    |> Enum.reverse()
  end

  defp publisher_for([], _keys, _event), do: nil

  defp publisher_for(publishers, keys, event) do
    Enum.at(publishers, publisher_lane_index(keys, event, length(publishers)))
  end

  defp publisher_route(keys, event) do
    receiver_type = to_s(event["receiverType"] || get_in(event, ["body", "receiverType"]))
    receiver = to_s(event["receiver"] || get_in(event, ["body", "receiver"]))
    sender = to_s(event["sender"] || get_in(event, ["body", "sender"]))

    cond do
      receiver_type == "group" and receiver != "" ->
        ["group", receiver]

      receiver_type == "user" and receiver != "" and sender != "" ->
        ["user" | Enum.sort([sender, receiver])]

      true ->
        keys
        |> Enum.map(&encode_key/1)
        |> Enum.sort()
    end
  end

  defp record_delivery(decoded, event) do
    case to_int(decoded["publishedAtMs"]) do
      published_at when published_at > 0 ->
        delivery_ms = max(0, System.system_time(:millisecond) - published_at)
        tags = %{"type" => to_s(event["type"] || "unknown")}
        Observability.increment("redis.pubsub.received", tags)
        Observability.observe("redis.pubsub.delivery_ms", delivery_ms, tags)

      _other ->
        Observability.increment("redis.pubsub.received", %{"type" => "legacy"})
    end
  end

  defp encode_key({type, id}), do: [to_string(type), to_string(id)]
  defp encode_key(other), do: ["raw", inspect(other)]

  defp decode_key([type, id]) when type in ["user", "group"], do: {String.to_atom(type), id}
  defp decode_key(_other), do: nil

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp to_int(_value), do: 0
end
