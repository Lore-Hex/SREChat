defmodule OpenChat.RedisBus.PublisherLane do
  @moduledoc false

  use GenServer
  require Logger

  alias OpenChat.{Observability, RedisClient}

  @publish_timeout_ms 1_000
  @slow_publish_ms 250

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def publish(pid, channel, payload, enqueued_at) do
    GenServer.cast(pid, {:publish, channel, payload, enqueued_at})
  end

  def publish_sync(pid, channel, payload, enqueued_at) do
    GenServer.call(pid, {:publish, channel, payload, enqueued_at}, 5_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    connection_name = Keyword.fetch!(opts, :connection_name)
    lane = Keyword.fetch!(opts, :lane)

    case RedisClient.start_link(url, name: connection_name) do
      {:ok, connection} ->
        {:ok, %{connection: connection, lane: lane}}

      {:error, {:already_started, connection}} ->
        {:ok, %{connection: connection, lane: lane}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:publish, channel, payload, enqueued_at}, state) do
    publish_result(state, channel, payload, enqueued_at)
    {:noreply, state}
  end

  @impl true
  def handle_call({:publish, channel, payload, enqueued_at}, _from, state) do
    {:reply, publish_result(state, channel, payload, enqueued_at), state}
  end

  defp publish_result(state, channel, payload, enqueued_at) do
    queue_ms = Observability.duration_ms(enqueued_at)
    started_at = System.monotonic_time()

    result = safe_command(state.connection, ["PUBLISH", channel, payload])
    duration_ms = Observability.duration_ms(started_at)
    outcome = if result == :ok, do: "ok", else: "error"
    tags = %{"lane" => state.lane, "outcome" => outcome}

    Observability.increment("redis.publish.attempts", tags)
    Observability.observe("redis.publish.queue_ms", queue_ms, tags)
    Observability.observe("redis.publish.duration_ms", duration_ms, tags)
    Observability.gauge("redis.publish.queue_length", queue_length(), %{"lane" => state.lane})

    if duration_ms >= @slow_publish_ms do
      Logger.warning(
        "Redis publish lane=#{state.lane} outcome=#{outcome} queue_ms=#{queue_ms} duration_ms=#{duration_ms}"
      )
    end

    warn_publish_failure(result)
    result
  end

  defp safe_command(connection, command) do
    case RedisClient.command(connection, command, timeout: @publish_timeout_ms) do
      {:ok, _subscribers} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp warn_publish_failure(:ok), do: :ok

  defp warn_publish_failure({:error, reason}) do
    Logger.warning("Redis event publish failed: #{inspect(reason)}")
  end

  defp queue_length do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, count} -> count
      _other -> 0
    end
  end
end
