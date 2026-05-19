defmodule OpenChat.PubSub do
  @moduledoc false

  require Logger

  def subscribe(key), do: Registry.register(__MODULE__, key, %{})
  def unsubscribe(key), do: Registry.unregister(__MODULE__, key)

  def broadcast(keys, event) when is_list(keys) do
    keys = Enum.uniq(keys)
    local_broadcast(keys, event)
    publish_result = OpenChat.RedisBus.publish(keys, event)
    warn_publish_failure(publish_result)
    publish_result
  end

  def broadcast(key, event), do: broadcast([key], event)

  def broadcast_system(keys, event) when is_list(keys) do
    keys = Enum.uniq(keys)
    local_system_broadcast(keys, event)
    publish_result = OpenChat.RedisBus.publish_system(keys, event)
    warn_publish_failure(publish_result)
    publish_result
  end

  def broadcast_system(key, event), do: broadcast_system([key], event)

  def local_broadcast(keys, event) when is_list(keys) do
    Enum.each(Enum.uniq(keys), &local_broadcast(&1, event))
  end

  def local_broadcast(key, event) do
    Registry.dispatch(__MODULE__, key, fn entries ->
      for {pid, _meta} <- entries, do: send(pid, {:comet_event, event})
    end)

    :ok
  end

  def local_system_broadcast(keys, event) when is_list(keys) do
    Enum.each(Enum.uniq(keys), &local_system_broadcast(&1, event))
  end

  def local_system_broadcast(key, event) do
    Registry.dispatch(__MODULE__, key, fn entries ->
      for {pid, _meta} <- entries, do: send(pid, {:open_chat_system_event, event})
    end)

    :ok
  end

  defp warn_publish_failure(:ok), do: :ok

  defp warn_publish_failure({:error, reason}) do
    Logger.warning("Redis event publish failed after local broadcast: #{inspect(reason)}")
  end
end
