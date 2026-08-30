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

  test "a message that merely mentions a heartbeat IS stored" do
    # The marker has to be a prefix, or discussing the mechanism in chat would
    # silently vanish.
    before = stored_count()
    assert {:ok, _} = send_text("the ::heartbeat:: messages are flooding redis")
    assert stored_count() == before + 1
  end
end
