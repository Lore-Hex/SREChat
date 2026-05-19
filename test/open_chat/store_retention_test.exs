defmodule OpenChat.Store.RetentionTest do
  use ExUnit.Case, async: false

  alias OpenChat.Time
  alias OpenChat.Store.{Conversations, Retention, State}

  test "trim_group_history prunes messages, secondary indexes, threads, reactions, and unread counts" do
    with_env(
      %{
        group_max_messages: 3,
        group_message_retention_days: 365,
        group_unread_fanout_limit: 10
      },
      fn ->
        conv_id = Conversations.group_conversation_id("room")
        recent = Time.now()

        messages = %{
          "1" => group_message(1, conv_id, sent_at: recent - 10, muid: "m-1"),
          "2" => group_message(2, conv_id, sent_at: recent - 9, muid: "m-2"),
          "3" => group_message(3, conv_id, sent_at: nil),
          "4" => group_message(4, conv_id, sent_at: Integer.to_string(recent - 1)),
          "5" => group_message(5, conv_id, sent_at: recent)
        }

        state =
          State.default()
          |> put_in(["messages"], messages)
          |> put_in(["members", "room"], %{"alice" => %{}, "bob" => %{}, "carol" => %{}})
          |> put_in(["conversation_messages", conv_id], ["1", "2", "3", "4", "5"])
          |> put_in(["conversation_latest", conv_id], "5")
          |> put_in(["message_muids"], %{"m-1" => "1", "m-2" => "2"})
          |> put_in(["reactions"], %{"1" => %{"+" => %{}}, "2" => %{"+" => %{}}})
          |> put_in(["thread_messages"], %{
            "1" => ["3"],
            "4" => ["2"],
            "5" => ["3"],
            "9" => ["2", "5"]
          })
          |> put_in(["reads"], %{"bob" => %{conv_id => %{"messageId" => "4"}}})
          |> put_in(["unread_counts"], %{"bob" => %{conv_id => 99}})

        {trimmed, ops} = Retention.trim_group_history(state, messages["5"])

        assert get_in(trimmed, ["conversation_messages", conv_id]) == ["3", "4", "5"]
        assert get_in(trimmed, ["conversation_latest", conv_id]) == "5"
        assert Map.keys(trimmed["messages"]) |> Enum.sort() == ["3", "4", "5"]
        assert trimmed["message_muids"] == %{}
        assert trimmed["reactions"] == %{}
        assert trimmed["thread_messages"] == %{"5" => ["3"], "9" => ["5"]}
        assert get_in(trimmed, ["unread_counts", "bob", conv_id]) == 1

        assert {:delete, "messages", "1"} in ops
        assert {:delete, "messages", "2"} in ops
        assert {:delete, "reactions", "1"} in ops
        assert {:delete, "reactions", "2"} in ops
        assert {:delete, "message_muids", "m-1"} in ops
        assert {:delete, "message_muids", "m-2"} in ops
        assert {:delete, "thread_messages", "1"} in ops
        assert {:delete, "thread_messages", "4"} in ops
        assert {:put, "thread_messages", "9", ["5"]} in ops
      end
    )
  end

  test "trim_group_history applies age retention and leaves non-group messages untouched" do
    with_env(%{group_max_messages: 10, group_message_retention_days: 1}, fn ->
      conv_id = Conversations.group_conversation_id("room")
      old = Time.now() - 2 * 86_400
      fresh = Time.now()

      old_message = group_message(1, conv_id, sent_at: old)
      fresh_message = group_message(2, conv_id, sent_at: fresh)

      state =
        State.default()
        |> put_in(["messages"], %{"1" => old_message, "2" => fresh_message})
        |> put_in(["conversation_messages", conv_id], ["1", "2"])
        |> put_in(["conversation_latest", conv_id], "2")

      {trimmed, ops} = Retention.trim_group_history(state, fresh_message)

      assert get_in(trimmed, ["conversation_messages", conv_id]) == ["2"]
      assert Map.keys(trimmed["messages"]) == ["2"]
      assert {:delete, "messages", "1"} in ops

      assert {^trimmed, []} =
               Retention.trim_group_history(trimmed, %{
                 "receiverType" => "user",
                 "conversationId" => "user_alice_bob"
               })
    end)
  end

  defp group_message(id, conv_id, opts) do
    %{
      "id" => to_string(id),
      "sender" => "alice",
      "receiver" => "room",
      "receiverType" => "group",
      "conversationId" => conv_id,
      "data" => %{}
    }
    |> maybe_put("muid", Keyword.get(opts, :muid))
    |> maybe_put("sentAt", Keyword.get(opts, :sent_at))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp with_env(values, fun) do
    previous =
      Map.new(values, fn {key, _value} -> {key, Application.get_env(:open_chat, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:open_chat, key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:open_chat, key)
        {key, value} -> Application.put_env(:open_chat, key, value)
      end)
    end
  end
end
