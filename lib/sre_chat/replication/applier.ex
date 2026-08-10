defmodule SREChat.Replication.Applier do
  @moduledoc """
  Applies decoded oplog entries from peer regions.

  `apply_encoded/1` is the tailer's entry point: decode, refuse own-origin
  entries, hand the ops to `Store.ingest_replicated/3`. The Store call
  flows the normal mutation path — the request plan derives entity locks
  and Redis refresh keys from the ops — so version gating, application,
  and version stamping all happen inside the same locks local writers use.

  ## Version gating

  Every record bucket except the receipt cursors is last-writer-wins on
  `{ts, origin}`: an op only applies if it is newer than the stored
  replication version for that record (stamped by the atomic write script
  for local mutations, and by `stamp_versions/3` for applied peer ops).
  Ties cannot happen across regions (origin breaks them), and both sides
  of a concurrent update resolve to the SAME winner, which is what makes
  post-partition convergence a local decision.

  Receipt cursors (`reads`/`delivered`) skip gating entirely: they merge
  by per-conversation max, which is order-free and idempotent.

  Version stamping is deliberately AFTER the ingest commit and not atomic
  with it: if the applier dies between the two, the entry re-applies on
  restart — record replaces and cursor max-merges are idempotent, so the
  worst case is wasted work, never divergence.
  """

  require Logger

  alias SREChat.{Config, Replication, Store}
  alias SREChat.Replication.Ingest
  alias SREChat.Store.RedisPersistence

  @doc """
  Decode a raw stream entry payload and apply it via the Store.

  `stream_id` is the entry's id in the ORIGIN's stream — the per-origin
  monotone sequence. It breaks version ties between ops the same origin
  emitted within one millisecond (create-group then add-members routinely
  land in the same ms); without it the second op loses the tie and gets
  gated, which is how region B ends up with an empty war room.
  """
  def apply_encoded(json, stream_id \\ "0-0") do
    with {:ok, entry} <- Replication.decode_entry(json) do
      if entry.origin == Config.region_index() do
        # A region never applies its own ops; seeing them means a
        # misconfigured tailer is reading its own stream.
        {:error, :own_origin}
      else
        Store.ingest_replicated(entry.ops, entry.origin, entry.ts, stream_id)
      end
    end
  end

  @doc """
  Drop ops that are older than the locally stored replication version.
  Called from INSIDE the Store's ingest handler, under the entity locks.
  """
  def version_gate(ops, origin, ts, stream_id) do
    gated = Enum.reject(ops, fn op -> Ingest.merge_bucket?(elem(op, 1)) end)
    versions = RedisPersistence.get_repl_versions(Enum.map(gated, &version_key/1))
    candidate = version_tuple(ts, origin, stream_id)

    Enum.filter(ops, fn op ->
      Ingest.merge_bucket?(elem(op, 1)) or
        newer?(candidate, Map.get(versions, version_key(op)))
    end)
  end

  @doc "Stamp applied ops with the entry's version. Failures are non-fatal."
  def stamp_versions(ops, origin, ts, stream_id) do
    stamps =
      ops
      |> Enum.reject(fn op -> Ingest.merge_bucket?(elem(op, 1)) end)
      |> Map.new(fn op ->
        {version_key(op), %{"ts" => ts, "origin" => origin, "sid" => stream_id}}
      end)

    case RedisPersistence.put_repl_versions(stamps) do
      :ok ->
        :ok

      {:error, reason} ->
        # At worst one redundant, idempotent re-apply.
        Logger.warning("replication version stamp failed: #{inspect(reason)}")
        :ok
    end
  end

  defp version_key({_action, bucket, id}), do: "#{bucket}:#{id}"
  defp version_key({_action, bucket, id, _value}), do: "#{bucket}:#{id}"

  # Cross-origin order: (ts, origin) — deterministic on both sides of a
  # partition. Same-origin order: the origin's own stream id, which is
  # monotone by construction. sid never decides between different origins
  # because origin decides first.
  defp version_tuple(ts, origin, sid), do: {ts, origin, parse_sid(sid)}

  defp newer?(_candidate, nil), do: true

  defp newer?(candidate, %{"ts" => ts, "origin" => origin} = stored) do
    candidate > version_tuple(ts, origin, Map.get(stored, "sid", "0-0"))
  end

  defp newer?(_candidate, _malformed), do: true

  defp parse_sid(sid) when is_binary(sid) do
    case String.split(sid, "-") do
      [ms, seq] -> {parse_int(ms), parse_int(seq)}
      _other -> {0, 0}
    end
  end

  defp parse_sid(_sid), do: {0, 0}

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end
end
