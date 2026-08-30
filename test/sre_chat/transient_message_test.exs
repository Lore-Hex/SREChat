defmodule SREChat.TransientMessageTest do
  @moduledoc """
  Heartbeats are liveness bookkeeping, not conversation.

  Storing them turned a four-participant deployment with almost no real chat
  into 48,108 stored messages, 193,152 Redis keys and 750 MB — 98% heartbeats.
  On the 1.9 GB region that OOM-killed the BEAM eight times in a week, and the
  matching oplog made every replication catch-up a 150-second batch it could not
  finish. The bytes were the cause; the crash loop was the symptom.
  """
  use ExUnit.Case, async: false

  alias SREChat.Store

  setup do
    for uid <- ~w(t-alice t-bob) do
      Store.upsert_user(%{"uid" => uid, "name" => uid})
    end

    :ok
  end

  defp send_text(text, extra \\ %{}) do
    Store.send_message(
      "t-alice",
      Map.merge(
        %{
          "receiver" => "t-bob",
          "receiverType" => "user",
          "type" => "text",
          "category" => "message",
          "data" => %{"text" => text}
        },
        extra
      ),
      [],
      admin?: true
    )
  end

  defp stored_count do
    {:ok, msgs} = Store.messages_for_user("t-bob", "t-alice", %{"limit" => "100"})
    length(msgs)
  end

  # Shaped like a message that really came off a peer's oplog. A bare map without
  # sender/receiver crashes PubSubFanout, which would make the heartbeat test
  # pass for the wrong reason — dropped before fanout rather than dropped on
  # purpose.
  defp replicated_message(id, text) do
    %{
      "id" => id,
      "muid" => "srv-" <> id,
      "conversationId" => "user_t-alice_t-bob",
      "category" => "message",
      "type" => "text",
      "sender" => "t-alice",
      "receiver" => "t-bob",
      "receiverType" => "user",
      "sentAt" => 1_787_000_000,
      "updatedAt" => 1_787_000_000,
      "data" => %{"text" => text}
    }
  end

  test "an ordinary message is stored" do
    before = stored_count()
    assert {:ok, _} = send_text("a real message")
    assert stored_count() == before + 1
  end

  test "a heartbeat is delivered but NEVER stored" do
    before = stored_count()
    assert {:ok, msg} = send_text("::heartbeat:: sre-agent-1 1787000000")
    # The caller still gets a message back, so senders need no special handling.
    assert msg["data"]["text"] =~ "::heartbeat::"
    assert stored_count() == before, "a heartbeat was persisted"
  end

  test "many heartbeats leave the store flat" do
    before = stored_count()
    for i <- 1..50, do: send_text("::heartbeat:: sre-agent-#{rem(i, 3)} #{i}")
    assert stored_count() == before, "heartbeats accumulated in the store"
  end

  test "an explicit transient category is not stored either" do
    # The marker keeps existing agents working with no coordinated rollout; the
    # category is the honest way to say it for anything written later.
    before = stored_count()
    assert {:ok, _} = send_text("presence ping", %{"category" => "transient"})
    assert stored_count() == before
  end

  test "a heartbeat arriving by REPLICATION is dropped, not stored" do
    # send_message/4 stops this region writing them; a peer that has not been
    # deployed yet, or an oplog still holding the old ones, would replicate them
    # straight back in. That is what kept region 1's key count climbing at ~22/s
    # while it drained the backlog, with the write-side fix already live.
    before = stored_count()

    hb = replicated_message("replicated-hb-1", "::heartbeat:: sre-agent-2 1787000001")

    assert {:ok, _} =
             Store.ingest_replicated([{:put, "messages", "replicated-hb-1", hb}], 2, 1_787_000_001, "1-0")

    assert stored_count() == before, "a replicated heartbeat was persisted"
  end

  test "the muid POINTER to a dropped heartbeat is dropped with it" do
    # One heartbeat replicates as several ops. Dropping only the message left an
    # orphaned index entry: srechat:messages went flat while message_muids kept
    # climbing ~400/min, which reads exactly like the fix not working.
    hb = replicated_message("replicated-hb-2", "::heartbeat:: sre-agent-0 1787000003")

    assert {:ok, _} =
             Store.ingest_replicated(
               [
                 {:put, "messages", "replicated-hb-2", hb},
                 {:put, "message_muids", "srv-replicated-hb-2", "replicated-hb-2"}
               ],
               2,
               1_787_000_003,
               "3-0"
             )

    result = Store.find_message_by_muid_for("t-bob", "srv-replicated-hb-2")

    refute match?({:ok, _}, result),
           "an orphaned muid pointer survived for a dropped heartbeat: #{inspect(result)}"
  end

  test "an ordinary message arriving by REPLICATION is still stored" do
    before = stored_count()

    msg = replicated_message("replicated-real-1", "a real replicated message")

    assert {:ok, _} =
             Store.ingest_replicated([{:put, "messages", "replicated-real-1", msg}], 2, 1_787_000_002, "2-0")

    assert stored_count() == before + 1, "replication dropped a real message"
  end

  test "a message that merely mentions a heartbeat IS stored" do
    # The marker has to be a prefix, or discussing the mechanism in chat would
    # silently vanish.
    before = stored_count()
    assert {:ok, _} = send_text("the ::heartbeat:: messages are flooding redis")
    assert stored_count() == before + 1
  end
end
