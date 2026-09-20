defmodule SREChat.Presence do
  @moduledoc """
  Who has checked in with this region, and when.

  In memory, per region, never stored and never replicated — on purpose.

  Agent liveness used to ride chat: each agent sent a `::heartbeat::` message to
  its peers every cycle. That was stored and replicated like conversation, and on
  a deployment with four participants it became 48,108 stored messages and
  750 MB of Redis, which OOM-killed a region eight times in a week.

  Making those messages transient fixed the storage and silently broke the
  feature: the agents read heartbeats by REST polling, which only ever sees
  stored messages, so every agent stopped hearing every other agent — and a
  "no baseline yet" guard meant nothing reported it. Agent-down detection was off
  for eighteen days and the first symptom was false alarms during a drill.

  Liveness is a gossip problem, not a chat problem. Each agent beats against
  EVERY region's API directly, so a region knows who can reach it without any
  replication at all, and a reader can ask any region that is up.
  """
  use Agent

  # Anyone authenticated can beat, so the table is bounded both ways.
  @max_entries 256
  @max_age_seconds 86_400

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Record that `uid` checked in now."
  def beat(uid, now \\ System.system_time(:second)) when is_binary(uid) do
    Agent.update(__MODULE__, fn state ->
      state
      |> Map.put(uid, now)
      |> prune(now)
    end)
  end

  @doc "`%{uid => epoch_seconds}` for everyone seen in the last day."
  def snapshot(now \\ System.system_time(:second)) do
    __MODULE__
    |> Agent.get(& &1)
    |> Map.filter(fn {_uid, at} -> now - at <= @max_age_seconds end)
  end

  defp prune(state, now) do
    fresh = Map.filter(state, fn {_uid, at} -> now - at <= @max_age_seconds end)

    if map_size(fresh) <= @max_entries do
      fresh
    else
      # Keep the most recent. Dropping the oldest is the right loss: a stale
      # entry is about to age out anyway.
      fresh
      |> Enum.sort_by(fn {_uid, at} -> at end, :desc)
      |> Enum.take(@max_entries)
      |> Map.new()
    end
  end
end
