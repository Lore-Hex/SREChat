defmodule OpenChat.Replication.Tailer do
  @moduledoc """
  Tails one peer region's oplog stream and feeds entries to the Applier.

  Transport only — all merge logic lives in Applier/Ingest. One tailer
  process per peer; a Redis lease in the LOCAL region elects a single
  tailing node per peer, so multi-node regions never double-apply.

  ## Partition behavior

  The peer's Redis being unreachable IS the partition. The tailer retries
  forever with backoff and the region keeps serving reads and writes from
  local state — that is the entire point of the design. On heal, XREAD
  resumes from the stored cursor and the backlog drains in order.

  ## Gap detection

  The origin's stream is MAXLEN-trimmed. If this region falls behind for
  longer than the buffer covers, the cursor's entry no longer exists —
  silently continuing from the earliest surviving entry would drop the
  trimmed middle and diverge FOREVER without anyone noticing. The tailer
  detects the gap (cursor older than the first surviving entry), marks
  itself degraded, logs an error on every retry, and refuses to apply
  anything further from that peer until an operator resyncs. Loud and
  stuck beats quiet and wrong.
  """

  use GenServer
  require Logger

  alias OpenChat.Observability
  alias OpenChat.Replication.Applier
  alias OpenChat.Store.RedisPersistence

  @poll_ms 250
  # Renewed every tick (250ms), so a leader must miss 60 consecutive
  # renewals before the lease lapses to another node.
  @lease_ms 15_000
  @batch_count 200
  @error_backoff_ms 2_000

  def start_link(peer) do
    GenServer.start_link(__MODULE__, peer, name: name(peer.index))
  end

  def name(peer_index), do: :"OpenChat.Replication.Tailer.#{peer_index}"

  @doc "Current status, for tests and operators."
  def status(peer_index) do
    GenServer.call(name(peer_index), :status)
  catch
    :exit, _reason -> %{state: :down}
  end

  @impl true
  def init(peer) do
    state = %{
      peer: peer,
      conn: nil,
      cursor: nil,
      lease_token: nil,
      mode: :follower,
      applied: 0,
      last_error: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    send(self(), :tick)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:mode, :cursor, :applied, :last_error]), state}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      case ensure_leadership(state) do
        {:leader, state} -> tail_once(state)
        {:follower, state} -> state
      end

    interval = if state.mode == :degraded, do: @error_backoff_ms, else: @poll_ms
    Process.send_after(self(), :tick, interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- leadership ------------------------------------------------------

  defp ensure_leadership(%{mode: :degraded} = state), do: {:follower, state}

  defp ensure_leadership(state) do
    token = state.lease_token || Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    case RedisPersistence.acquire_or_renew_lease(
           lease_key(state.peer.index),
           token,
           @lease_ms
         ) do
      :acquired ->
        {:leader, %{state | lease_token: token, mode: :leader}}

      :held_elsewhere ->
        {:follower, %{state | mode: :follower}}

      {:error, reason} ->
        {:follower, %{state | mode: :follower, last_error: reason}}
    end
  end

  defp lease_key(peer_index), do: "repl:tailer_lease:#{peer_index}"

  # -- tailing ---------------------------------------------------------

  defp tail_once(state) do
    with {:ok, state} <- ensure_conn(state),
         {:ok, state} <- ensure_cursor(state),
         {:ok, state} <- check_gap(state) do
      read_and_apply(state)
    else
      {:degraded, state} ->
        state

      {:error, reason, state} ->
        Observability.record_replication(state.peer.index, "peer_unreachable")
        %{state | last_error: reason}
    end
  end

  defp ensure_conn(%{conn: conn} = state) when is_pid(conn), do: {:ok, state}

  defp ensure_conn(state) do
    case Redix.start_link(state.peer.url) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_cursor(%{cursor: cursor} = state) when is_binary(cursor), do: {:ok, state}

  defp ensure_cursor(state) do
    case RedisPersistence.get_replication_cursor(state.peer.index) do
      {:ok, cursor} -> {:ok, %{state | cursor: cursor || "0-0"}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The cursor's entry must still exist (or the cursor is the epoch): if
  # the peer trimmed past us, applying the remainder would silently drop
  # the middle of history.
  defp check_gap(%{cursor: "0-0"} = state), do: {:ok, state}

  defp check_gap(state) do
    stream = RedisPersistence.oplog_stream_key(state.peer.index)

    case Redix.command(state.conn, ["XRANGE", stream, "-", "+", "COUNT", "1"]) do
      {:ok, []} ->
        {:ok, state}

      {:ok, [[first_id, _fields]]} ->
        if stream_id_after?(first_id, state.cursor) do
          Logger.error(
            "replication gap from region #{state.peer.index}: cursor #{state.cursor} " <>
              "trimmed (earliest surviving entry #{first_id}); refusing to continue — " <>
              "resync this region from a peer snapshot"
          )

          Observability.record_replication(state.peer.index, "gap_detected")
          {:degraded, %{state | mode: :degraded, last_error: :replication_gap}}
        else
          {:ok, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp read_and_apply(state) do
    stream = RedisPersistence.oplog_stream_key(state.peer.index)

    case Redix.command(state.conn, [
           "XREAD",
           "COUNT",
           Integer.to_string(@batch_count),
           "STREAMS",
           stream,
           state.cursor
         ]) do
      {:ok, nil} ->
        state

      {:ok, [[_stream, entries]]} ->
        apply_entries(state, entries)

      {:error, reason} ->
        Observability.record_replication(state.peer.index, "read_failed")
        %{state | last_error: reason}
    end
  end

  defp apply_entries(state, entries) do
    Enum.reduce_while(entries, state, fn [id, fields], state ->
      json = entry_payload(fields)

      case json && Applier.apply_encoded(json, id) do
        {:ok, _applied} ->
          advance(state, id, :applied)

        nil ->
          # Malformed fields: skip, count, continue — refusing forever on
          # one bad entry would wedge the stream.
          Observability.record_replication(state.peer.index, "malformed_entry")
          advance(state, id, :skipped)

        {:error, :own_origin} ->
          Observability.record_replication(state.peer.index, "own_origin_entry")
          advance(state, id, :skipped)

        {:error, :malformed_oplog_entry} ->
          Observability.record_replication(state.peer.index, "malformed_entry")
          advance(state, id, :skipped)

        {:error, reason} ->
          # Apply failure (Store busy, local Redis hiccup): DO NOT advance
          # the cursor; retry the same entry next tick.
          Observability.record_replication(state.peer.index, "apply_failed")
          {:halt, %{state | last_error: reason}}
      end
    end)
  end

  defp advance(state, id, kind) do
    case RedisPersistence.put_replication_cursor(state.peer.index, id) do
      :ok ->
        applied = if kind == :applied, do: state.applied + 1, else: state.applied
        Observability.record_replication(state.peer.index, to_string(kind))
        {:cont, %{state | cursor: id, applied: applied, last_error: nil}}

      {:error, reason} ->
        {:halt, %{state | last_error: reason}}
    end
  end

  defp entry_payload(fields) do
    fields
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn
      ["entry", json] -> json
      _other -> nil
    end)
  end

  # Redis stream ids are "<ms>-<seq>".
  defp stream_id_after?(a, b) do
    parse = fn id ->
      case String.split(id, "-") do
        [ms, seq] -> {String.to_integer(ms), String.to_integer(seq)}
        _other -> {0, 0}
      end
    end

    parse.(a) > parse.(b)
  end
end
