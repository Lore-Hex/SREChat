defmodule SREChat.RegionId do
  @moduledoc """
  Coordination-free id allocation for multi-master regions.

  The global Redis `INCR next_id` counter is the single point that forbids
  multi-master operation: a region that cannot reach the counter cannot send
  a message. This module composes ids locally instead:

      | 41 bits ms since 2026-01-01 | 3 bits region | 9 bits sequence |

  53 bits total — exactly `Number.MAX_SAFE_INTEGER` sized, because message
  ids travel to the JavaScript SDK as JSON numbers and anything above 2^53-1
  silently loses precision in the browser.

  Properties the rest of the store relies on:

    * integers, so every existing `to_int/1` comparison and `{sentAt, id}`
      pagination cursor works unchanged;
    * strictly increasing per region — clock regressions are absorbed by
      never allocating below the last-used millisecond;
    * unique across regions with NO cross-region coordination — the region
      bits partition the space;
    * larger than any id the legacy global counter plausibly produced, so a
      store migrated from `global` to `region` allocation stays ordered.
      The reverse migration is NOT safe without first raising `next_id`
      above the largest allocated region id.

  Within one region, two BEAM nodes sharing the region's Redis take the
  sequence from a per-millisecond Redis key, which is exactly as available
  as writes are (writes already require that Redis). Without Redis
  (dev/test), the sequence comes from the allocator state, which lives in
  the single Store process.
  """

  import Bitwise

  # 2026-01-01T00:00:00Z
  @epoch_ms 1_767_225_600_000
  @ms_bits 41
  @region_bits 3
  @seq_bits 9
  @max_ms (1 <<< @ms_bits) - 1
  @max_region (1 <<< @region_bits) - 1
  @max_seq (1 <<< @seq_bits) - 1
  @js_max_safe_integer 9_007_199_254_740_991

  # Compile-time proof of the JS-safety property: the compose/3 guards cap
  # every field, and the capped maxima pack to exactly MAX_SAFE_INTEGER.
  # Widening any field breaks the build here, not message ids in browsers.
  @max_composed @max_ms <<< (@region_bits + @seq_bits) ||| @max_region <<< @seq_bits ||| @max_seq
  if @max_composed != @js_max_safe_integer do
    raise CompileError,
      description:
        "region id layout must pack to exactly 2^53-1 (JS MAX_SAFE_INTEGER); " <>
          "got #{@max_composed}"
  end

  @typedoc "Allocator state threaded through the Store's state map."
  @type alloc :: %{optional(String.t()) => integer()}

  def max_seq, do: @max_seq
  def max_region, do: @max_region
  def epoch_ms, do: @epoch_ms

  @doc """
  Allocate the next id from the allocator's own state (no Redis). Safe only
  while a single process allocates — which holds: mutations run inside the
  one Store GenServer, and multi-node deployments require Redis.
  """
  @spec next_local(alloc(), 0..7, integer()) :: {integer(), alloc()}
  def next_local(alloc, region, now_ms) when region in 0..@max_region do
    floor_ms = floor_ms(alloc, now_ms)
    last_ms = Map.get(alloc, "last_ms", -1)
    last_seq = Map.get(alloc, "last_seq", -1)

    {ms, seq} =
      if floor_ms == last_ms and last_seq >= @max_seq,
        do: {floor_ms + 1, 0},
        else: {floor_ms, if(floor_ms == last_ms, do: last_seq + 1, else: 0)}

    id = compose(ms, region, seq)
    {id, alloc |> Map.put("last_ms", ms) |> Map.put("last_seq", seq)}
  end

  @doc """
  Allocate the next id with the sequence claimed from a shared source.
  `seq_fun` receives an epoch-relative millisecond and returns a 0-based
  sequence slot; slots past #{@max_seq} spill into the next millisecond
  (borrowing keeps allocation wait-free instead of sleeping the Store).
  """
  @spec next_shared(alloc(), 0..7, integer(), (integer() -> non_neg_integer())) ::
          {integer(), alloc()}
  def next_shared(alloc, region, now_ms, seq_fun) when region in 0..@max_region do
    {ms, seq} = claim(floor_ms(alloc, now_ms), seq_fun)
    id = compose(ms, region, seq)
    {id, Map.put(alloc, "last_ms", ms)}
  end

  def compose(ms, region, seq)
      when ms in 0..@max_ms and region in 0..@max_region and seq in 0..@max_seq do
    # The guards make overflow impossible: capped maxima pack to exactly
    # 2^53-1, proven at compile time above.
    ms <<< (@region_bits + @seq_bits) ||| region <<< @seq_bits ||| seq
  end

  def decompose(id) when is_integer(id) do
    seq = id &&& @max_seq
    region = id >>> @seq_bits &&& @max_region
    ms = id >>> (@region_bits + @seq_bits)
    {ms, region, seq}
  end

  # Never allocate below the last-used millisecond: a stepped-back clock
  # must not produce ids that sort before ids already handed out.
  defp floor_ms(alloc, now_ms), do: max(now_ms - @epoch_ms, Map.get(alloc, "last_ms", 0))

  defp claim(ms, seq_fun) do
    case seq_fun.(ms) do
      seq when is_integer(seq) and seq <= @max_seq -> {ms, seq}
      _exhausted_or_invalid -> claim(ms + 1, seq_fun)
    end
  end
end
