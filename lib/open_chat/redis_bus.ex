defmodule OpenChat.RedisBus do
  @moduledoc false

  use GenServer
  require Logger

  alias OpenChat.{Config, RedisClient}

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def publish(keys, event) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:publish, List.wrap(keys), event})
    end

    :ok
  end

  def publish_system(keys, event) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:publish_system, List.wrap(keys), event})
    end

    :ok
  end

  @impl true
  def init(_opts) do
    state = %{
      channel: channel(),
      origin: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      pubsub: nil
    }

    case Config.redis_url() do
      url when is_binary(url) and url != "" ->
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
  def handle_cast({:publish, _keys, _event}, %{pubsub: nil} = state), do: {:noreply, state}
  def handle_cast({:publish_system, _keys, _event}, %{pubsub: nil} = state), do: {:noreply, state}

  def handle_cast({:publish, keys, event}, state) do
    publish_event(state, keys, event, false)
    {:noreply, state}
  end

  def handle_cast({:publish_system, keys, event}, state) do
    publish_event(state, keys, event, true)
    {:noreply, state}
  end

  defp publish_event(state, keys, event, system?) do
    payload =
      Jason.encode!(%{
        "origin" => state.origin,
        "keys" => Enum.map(keys, &encode_key/1),
        "event" => event,
        "system" => system?
      })

    publish_to_redis(state.channel, payload)
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

      if decoded["system"] == true do
        OpenChat.PubSub.local_system_broadcast(keys, event)
      else
        OpenChat.PubSub.local_broadcast(keys, event)
      end
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp channel, do: Config.redis_key_prefix() <> ":events"

  defp publish_to_redis(channel, payload) do
    if Process.whereis(OpenChat.Redis) do
      case safe_command(["PUBLISH", channel, payload]) do
        {:ok, _subscribers} -> :ok
        {:error, reason} -> Logger.debug("Redis event publish skipped: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp safe_command(command) do
    RedisClient.command(OpenChat.Redis, command)
  catch
    :exit, reason -> {:error, reason}
  end

  defp encode_key({type, id}), do: [to_string(type), to_string(id)]
  defp encode_key(other), do: ["raw", inspect(other)]

  defp decode_key([type, id]) when type in ["user", "group"], do: {String.to_atom(type), id}
  defp decode_key(_other), do: nil
end
