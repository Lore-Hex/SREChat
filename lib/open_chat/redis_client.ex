defmodule OpenChat.RedisClient do
  @moduledoc false

  def start_link(url, opts), do: redis_adapter().start_link(url, opts)
  def command(conn, command), do: redis_adapter().command(conn, command)
  def command(conn, command, opts), do: redis_adapter().command(conn, command, opts)
  def pipeline(conn, commands), do: redis_adapter().pipeline(conn, commands)

  def pubsub_start_link(url, opts), do: pubsub_adapter().start_link(url, opts)

  def pubsub_subscribe(pubsub, channel, receiver),
    do: pubsub_adapter().subscribe(pubsub, channel, receiver)

  defp redis_adapter, do: Application.get_env(:open_chat, :redis_client, Redix)
  defp pubsub_adapter, do: Application.get_env(:open_chat, :redis_pubsub_client, Redix.PubSub)
end
