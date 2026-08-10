defmodule SREChat.RegionIdTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias SREChat.RegionId

  # A realistic "now": 2026-08-08, well past the allocator epoch.
  @now_ms 1_786_500_000_000

  describe "compose/decompose" do
    test "round-trips every field" do
      id = RegionId.compose(123_456_789, 5, 311)
      assert RegionId.decompose(id) == {123_456_789, 5, 311}
    end

    test "never exceeds JavaScript's safe integer range at field maxima" do
      # Message ids reach the JS SDK as JSON numbers; one bit more and the
      # browser silently rounds ids. This is the whole reason the layout is
      # 41+3+9 and not a fatter snowflake.
      max_id = RegionId.compose((1 <<< 41) - 1, 7, 511)
      assert max_id == 9_007_199_254_740_991
      assert max_id <= 9_007_199_254_740_991
    end

    test "millisecond overflow raises instead of corrupting web clients" do
      assert_raise FunctionClauseError, fn ->
        RegionId.compose(1 <<< 41, 0, 0)
      end
    end
  end

  describe "next_local/3" do
    test "ids are strictly increasing within a region" do
      {id1, alloc} = RegionId.next_local(%{}, 2, @now_ms)
      {id2, alloc} = RegionId.next_local(alloc, 2, @now_ms)
      {id3, _alloc} = RegionId.next_local(alloc, 2, @now_ms + 5)
      assert id1 < id2
      assert id2 < id3
    end

    test "same millisecond advances the sequence, not the clock" do
      {id1, alloc} = RegionId.next_local(%{}, 0, @now_ms)
      {id2, _} = RegionId.next_local(alloc, 0, @now_ms)
      {ms1, 0, seq1} = RegionId.decompose(id1)
      {ms2, 0, seq2} = RegionId.decompose(id2)
      assert ms1 == ms2
      assert seq2 == seq1 + 1
    end

    test "a stepped-back clock cannot allocate below already-issued ids" do
      {id1, alloc} = RegionId.next_local(%{}, 1, @now_ms)
      # NTP steps the clock back 30 seconds.
      {id2, _} = RegionId.next_local(alloc, 1, @now_ms - 30_000)
      assert id2 > id1
    end

    test "sequence exhaustion borrows the next millisecond" do
      alloc =
        Enum.reduce(1..(RegionId.max_seq() + 1), %{}, fn _, alloc ->
          {_id, alloc} = RegionId.next_local(alloc, 1, @now_ms)
          alloc
        end)

      {id, _} = RegionId.next_local(alloc, 1, @now_ms)
      {ms, 1, seq} = RegionId.decompose(id)
      assert ms == @now_ms - RegionId.epoch_ms() + 1
      assert seq == 0
    end

    test "two regions can never collide, even at the same ms and seq" do
      {id_a, _} = RegionId.next_local(%{}, 0, @now_ms)
      {id_b, _} = RegionId.next_local(%{}, 1, @now_ms)
      assert id_a != id_b
      assert RegionId.decompose(id_a) |> elem(1) == 0
      assert RegionId.decompose(id_b) |> elem(1) == 1
    end

    test "region ids sort after any plausible legacy counter id" do
      {id, _} = RegionId.next_local(%{}, 0, @now_ms)
      # The global counter would need ~2.4e15 messages to reach this.
      assert id > 1_000_000_000_000
    end
  end

  describe "next_shared/4" do
    test "takes the sequence from the shared source" do
      {id, _alloc} = RegionId.next_shared(%{}, 3, @now_ms, fn _ms -> 7 end)
      {_ms, 3, 7} = RegionId.decompose(id)
    end

    test "spills into the next millisecond when the shared slot is exhausted" do
      parent = self()

      seq_fun = fn ms ->
        send(parent, {:asked, ms})
        # First millisecond full, next one free.
        if ms == @now_ms - RegionId.epoch_ms(), do: RegionId.max_seq() + 40, else: 0
      end

      {id, _} = RegionId.next_shared(%{}, 3, @now_ms, seq_fun)
      {ms, 3, 0} = RegionId.decompose(id)
      assert ms == @now_ms - RegionId.epoch_ms() + 1
      assert_received {:asked, _}
      assert_received {:asked, _}
    end
  end
end
