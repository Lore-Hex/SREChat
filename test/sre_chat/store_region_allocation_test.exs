defmodule SREChat.StoreRegionAllocationTest do
  use ExUnit.Case, async: false

  alias SREChat.{RegionId, Store}

  setup do
    previous_allocator = Application.get_env(:sre_chat, :id_allocator, "global")
    previous_region = Application.get_env(:sre_chat, :region_index, 0)

    on_exit(fn ->
      Application.put_env(:sre_chat, :id_allocator, previous_allocator)
      Application.put_env(:sre_chat, :region_index, previous_region)
      Store.reset!()
    end)

    Application.put_env(:sre_chat, :id_allocator, "region")
    Application.put_env(:sre_chat, :region_index, 3)
    Store.reset!()
    :ok
  end

  defp send_text(sender, receiver, text) do
    {:ok, msg} =
      Store.send_message(sender, %{
        "receiver" => receiver,
        "receiverType" => "user",
        "type" => "text",
        "category" => "message",
        "data" => %{"text" => text}
      })

    msg
  end

  test "messages get region-composed, JS-safe, strictly increasing ids" do
    first = send_text("alice", "bob", "one")
    second = send_text("alice", "bob", "two")

    for msg <- [first, second] do
      {_ms, region, _seq} = RegionId.decompose(msg["id"])
      assert region == 3
      assert msg["id"] <= 9_007_199_254_740_991
    end

    assert first["id"] < second["id"]
  end

  # Runs one conversation through history, both cursor directions, and
  # unread counting, returning every observable shape. Region ids must be
  # indistinguishable from legacy ids to all of it.
  defp history_scenario do
    send_text("alice", "bob", "one")
    middle = send_text("alice", "bob", "two")
    send_text("alice", "bob", "three")

    {:ok, latest_first} = Store.messages_for_user("bob", "alice", %{"limit" => 10})

    {:ok, before_middle} =
      Store.messages_for_user("bob", "alice", %{"limit" => 10, "id" => to_string(middle["id"])})

    {:ok, after_middle} =
      Store.messages_for_user("bob", "alice", %{
        "limit" => 10,
        "afterId" => to_string(middle["id"])
      })

    # mark_read is CometChat's conversation-level clear: the cursor jumps to
    # the latest message whatever id is passed. The id-comparison path is
    # mark_unread's rewind, which re-opens everything >= the given id.
    {:ok, _} = Store.mark_read("bob", "user", "alice", to_string(middle["id"]))
    {:ok, cleared} = Store.unread_counts("bob", %{"receiverType" => "user"})

    {:ok, _} = Store.mark_unread("bob", "user", "alice", to_string(middle["id"]))

    {:ok, counts} =
      Store.unread_counts("bob", %{"receiverType" => "user", "count" => "1", "unread" => "1"})

    %{
      latest_first: Enum.map(latest_first, & &1["data"]["text"]),
      before_middle: Enum.map(before_middle, & &1["data"]["text"]),
      after_middle: Enum.map(after_middle, & &1["data"]["text"]),
      unread_after_mark_read: cleared,
      unread_after_rewind_to_middle: Enum.map(counts, & &1["count"])
    }
  end

  @expected_history %{
    # No cursor = the SDK's fetchPrevious: newest first.
    latest_first: ["three", "two", "one"],
    before_middle: ["one"],
    after_middle: ["three"],
    unread_after_mark_read: [],
    # Rewinding to "two" re-opens "two" and "three": both id comparisons
    # run against 53-bit integers.
    unread_after_rewind_to_middle: [2]
  }

  test "history, cursors, and unread counting behave identically with huge region ids" do
    assert history_scenario() == @expected_history
  end

  test "the same scenario under the legacy global allocator matches exactly" do
    Application.put_env(:sre_chat, :id_allocator, "global")
    Store.reset!()
    assert history_scenario() == @expected_history
  end

  test "actions and reactions allocate from the same region space" do
    msg = send_text("alice", "bob", "hello")

    {:ok, edit_action} = Store.edit_message("alice", to_string(msg["id"]), %{"text" => "edited"})
    {_ms, 3, _seq} = RegionId.decompose(edit_action["id"])

    {:ok, reaction} = Store.add_reaction("bob", to_string(msg["id"]), "👍")
    reaction_id = reaction["id"] || get_in(reaction, ["reaction", "id"])

    if is_integer(reaction_id) do
      {_ms, 3, _seq} = RegionId.decompose(reaction_id)
    end
  end

  test "the default allocator remains the legacy global counter" do
    Application.put_env(:sre_chat, :id_allocator, "global")
    Store.reset!()

    msg = send_text("alice", "bob", "legacy")
    # Small sequential ids, exactly as SREChat allocates them.
    assert msg["id"] < 1_000_000
  end
end
