defmodule SREChat.Replication do
  @moduledoc """
  Multi-master replication policy: what leaves a region, and when.

  Each region appends every locally-originated record mutation to its own
  Redis Stream (`<prefix>:oplog:<region_index>`), inside the SAME atomic
  Lua write that commits the records — a mutation and its replication
  record commit together or not at all. Peer regions tail that stream and
  apply the ops with per-bucket merge rules.

  Only source-of-truth buckets travel. Derived structures — conversation
  message lists, latest pointers, thread lists, user/conversation indexes,
  unread counts — are recomputed by the receiving region from the records
  it applies, exactly as the origin computed them from its own. Shipping
  derived state would turn every concurrent write into a lost-update
  hazard; shipping facts and re-deriving keeps convergence a local
  property.

  Counters never travel: multi-master requires `ID_ALLOCATOR=region`, and
  region ids make the global counters meaningless.

  `REPLICATION_MODE=multi_master` turns emission on. It refuses to run
  without region ids — replicating counter-allocated ids would collide.
  """

  alias SREChat.Config

  @replicated_buckets ~w(
    users
    tokens
    groups
    members
    messages
    reads
    delivered
    hidden_conversations
    reactions
    blocks
    banned
    message_muids
    presence
  )

  @applying_key :sre_chat_replication_applying

  def replicated_buckets, do: @replicated_buckets

  def enabled? do
    Config.replication_mode() == :multi_master
  end

  @doc """
  True while this process is applying a PEER's ops. Suppresses re-emission:
  without it, region B would append A's ops to B's own oplog and every
  entry would echo between regions forever.

  The flag is process-local and `RedisPersistence.write/1` runs inside the
  Store GenServer, so it only suppresses when set IN that process — i.e.
  from within the Store's own ingest handler. Wrapping a public Store call
  (which crosses a GenServer boundary) suppresses nothing, by design:
  ingest is the only legitimate applier.
  """
  def applying?, do: Process.get(@applying_key, false) == true

  def while_applying(fun) do
    previous = Process.get(@applying_key, false)
    Process.put(@applying_key, true)

    try do
      fun.()
    after
      Process.put(@applying_key, previous)
    end
  end

  @doc "Stream name (already prefix-namespaced by the persistence layer's key/1)."
  def stream_suffix(region_index), do: ["oplog", Integer.to_string(region_index)]

  @doc """
  Build the oplog entry payload for a batch of structured persistence ops,
  or nil when nothing should be emitted (replication off, currently
  applying peer ops, or no replicated-bucket ops in the batch).
  """
  def entry_for(ops) do
    with true <- enabled?(),
         false <- applying?(),
         [_ | _] = filtered <- filter_ops(ops) do
      Jason.encode!(%{
        "v" => 1,
        "origin" => Config.region_index(),
        "ts" => System.system_time(:millisecond),
        "ops" => Enum.map(filtered, &encode_op/1)
      })
    else
      _ -> nil
    end
  end

  @doc """
  Boot-time validation, called from `SREChat.Application.start/2`.
  Multi-master with counter-allocated ids would collide across masters,
  and a per-write raise would crash-loop the Store instead of failing the
  deploy — so the refusal happens once, at boot, loudly.
  """
  def ensure_valid_config! do
    if enabled?() and Config.id_allocator() != :region do
      raise ArgumentError,
            "REPLICATION_MODE=multi_master requires ID_ALLOCATOR=region: " <>
              "counter-allocated ids collide across masters"
    end

    if enabled?() do
      # Fails fast on an out-of-range REGION_INDEX too.
      self_index = Config.region_index()
      peers = Config.peer_regions()
      indexes = Enum.map(peers, & &1.index)

      if self_index in indexes do
        raise ArgumentError, "PEER_REGIONS must not include this region's own index"
      end

      if length(Enum.uniq(indexes)) != length(indexes) do
        raise ArgumentError, "PEER_REGIONS contains duplicate region indexes"
      end
    end

    :ok
  end

  def decode_entry(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"v" => 1, "origin" => origin, "ts" => ts, "ops" => ops}}
      when is_integer(origin) and is_integer(ts) and is_list(ops) ->
        {:ok, %{origin: origin, ts: ts, ops: Enum.map(ops, &decode_op/1)}}

      _other ->
        {:error, :malformed_oplog_entry}
    end
  end

  defp filter_ops(ops) do
    ops
    |> List.wrap()
    |> Enum.filter(fn
      {:put, bucket, _id, _value} -> bucket in @replicated_buckets
      {:delete, bucket, _id} -> bucket in @replicated_buckets
      _other -> false
    end)
  end

  defp encode_op({:put, bucket, id, value}), do: ["put", bucket, id, value]
  defp encode_op({:delete, bucket, id}), do: ["delete", bucket, id]

  defp decode_op(["put", bucket, id, value]), do: {:put, bucket, id, value}
  defp decode_op(["delete", bucket, id]), do: {:delete, bucket, id}
end
