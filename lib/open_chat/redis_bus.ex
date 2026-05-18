defmodule OpenChat.RedisBus do
  @moduledoc false

  use GenServer
  require Logger

  alias OpenChat.{Config, RedisClient}

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def publish(keys, event) do
    call_publish({:publish, List.wrap(keys), event})
  end

  def publish_system(keys, event) do
    call_publish({:publish_system, List.wrap(keys), event})
  end

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
  def handle_call({:publish, keys, event}, _from, state) do
    {:reply, publish_event(state, keys, event, false), state}
  end

  def handle_call({:publish_system, keys, event}, _from, state) do
    {:reply, publish_event(state, keys, event, true), state}
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
      refresh_store(keys, event)

      if decoded["system"] == true do
        OpenChat.PubSub.local_system_broadcast(keys, event)
      else
        OpenChat.PubSub.local_broadcast(keys, event)
      end
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp refresh_store(keys, event) do
    OpenChat.Store.refresh_from_pubsub(keys, event)
  catch
    :exit, reason -> Logger.warning("Redis event store refresh failed: #{inspect(reason)}")
  end

  defp channel, do: Config.redis_key_prefix() <> ":events"

  defp publish_to_redis(channel, payload) do
    if Process.whereis(OpenChat.Redis) do
      case safe_command(["PUBLISH", channel, payload]) do
        {:ok, _subscribers} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
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
