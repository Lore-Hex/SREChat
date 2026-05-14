defmodule OpenChat.StoreStateTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.State

  test "default state carries every durable bucket and counter" do
    state = State.default()

    assert State.bucket(state, :users) == %{}
    assert State.bucket(state, :groups) == %{}
    assert State.bucket(state, :members) == %{}
    assert State.bucket(state, :messages) == %{}
    assert State.bucket(state, :conversation_messages) == %{}
    assert State.bucket(state, :conversation_latest) == %{}
    assert State.bucket(state, :thread_messages) == %{}
    assert State.bucket(state, :reads) == %{}
    assert State.bucket(state, :delivered) == %{}
    assert State.bucket(state, :hidden_conversations) == %{}
    assert State.bucket(state, :reactions) == %{}
    assert State.bucket(state, :blocks) == %{}
    assert State.bucket(state, :banned) == %{}
    assert State.bucket(state, :message_muids) == %{}
    assert State.bucket(state, :user_conversations) == %{}
    assert State.bucket(state, :conversation_users) == %{}
    assert State.bucket(state, :user_groups) == %{}
    assert State.bucket(state, :unread_counts) == %{}
    assert State.bucket(state, :presence) == %{}
    assert State.counter(state, :next_id) == 1
    assert State.counter(state, :next_reaction_id) == 1
  end

  test "record helpers hide string-keyed compatibility storage" do
    state =
      State.default()
      |> State.put_record(:users, :alice, %{"uid" => "alice"})
      |> State.put_record("groups", 123, %{"guid" => "123"})

    assert {:ok, %{"uid" => "alice"}} = State.fetch_record(state, :users, "alice")
    assert State.get_record(state, :groups, "123") == %{"guid" => "123"}
    assert State.bucket(state, :users) == %{"alice" => %{"uid" => "alice"}}

    state = State.delete_record(state, :users, :alice)
    assert State.fetch_record(state, :users, "alice") == :error
  end

  test "bucket updates and counters normalise unsafe values" do
    state =
      State.default()
      |> State.update_bucket(:blocks, &Map.put(&1, "alice", %{"bob" => true}))
      |> State.put_counter(:next_id, "0")
      |> State.put_counter(:next_reaction_id, "19")

    assert State.bucket(state, :blocks) == %{"alice" => %{"bob" => true}}
    assert State.counter(state, :next_id) == 1
    assert State.counter(state, :next_reaction_id) == 19
  end

  test "seed decoding accepts list and map JSON and falls back safely" do
    assert State.decode_seed(~s([{"uid":"alice"}]), []) == [%{"uid" => "alice"}]

    assert State.decode_seed(~s({"a":{"uid":"alice"},"b":{"uid":"bob"}}), []) == [
             %{"uid" => "alice"},
             %{"uid" => "bob"}
           ]

    assert State.decode_seed("not-json", [%{"uid" => "fallback"}]) == [
             %{"uid" => "fallback"}
           ]

    assert Enum.any?(State.default_users(), &(&1["uid"] == "system"))
    assert [%{"guid" => "lobby", "type" => "public"}] = State.default_groups()
  end
end
