defmodule OpenChat.Store.MessageState do
  @moduledoc false

  alias OpenChat.Time

  alias OpenChat.Store.{
    Conversations,
    Entities,
    GroupState,
    Indexes,
    Retention,
    Unread,
    UserState
  }

  @spec store_with_retention(map(), map()) :: {map(), list()}
  def store_with_retention(state, message) do
    state
    |> store(message)
    |> Retention.trim_group_history(message)
  end

  @spec store(map(), map()) :: map()
  def store(state, message) do
    id_key = to_s(message["id"])
    conv_id = message["conversationId"]

    state =
      state
      |> put_in(["messages", id_key], message)
      |> update_in(["conversation_messages", conv_id], fn ids -> (ids || []) ++ [id_key] end)
      |> Indexes.link_message(message)
      |> Conversations.put_latest(message)
      |> Unread.message_created(message)

    if parent_id = message["parentId"] || message["parentMessageId"] do
      update_in(state, ["thread_messages", to_s(parent_id)], fn ids ->
        (ids || []) ++ [id_key]
      end)
    else
      state
    end
  end

  @spec refresh_reactions(map(), map(), term()) :: map()
  def refresh_reactions(state, message, current_uid) do
    counts =
      state
      |> get_in(["reactions", to_s(message["id"])])
      |> case do
        nil ->
          []

        reaction_map ->
          reaction_map
          |> Enum.reject(fn {_reaction, by_uid} -> map_size(by_uid) == 0 end)
          |> Enum.map(fn {reaction, by_uid} ->
            %{
              "reaction" => reaction,
              "count" => map_size(by_uid),
              "reactedByMe" => Map.has_key?(by_uid, current_uid)
            }
          end)
      end

    data = (message["data"] || %{}) |> Map.put("reactions", counts)
    Map.put(message, "data", data)
  end

  @spec remove_reaction(map(), term(), term(), term()) :: map()
  def remove_reaction(state, id, reaction, uid) do
    update_in(state, ["reactions", to_s(id)], fn reaction_map ->
      reaction_map = reaction_map || %{}
      by_uid = reaction_map |> Map.get(reaction, %{}) |> Map.delete(to_s(uid))

      if map_size(by_uid) == 0 do
        Map.delete(reaction_map, reaction)
      else
        Map.put(reaction_map, reaction, by_uid)
      end
    end)
  end

  @spec message_action(integer(), map(), term(), map(), map(), String.t()) :: map()
  def message_action(id, state, actor_uid, message, receiver_entity, action) do
    actor = state |> UserState.get_or_default(actor_uid) |> UserState.public()

    Entities.message(%{
      "id" => id,
      "sender" => actor_uid,
      "receiver" => message["receiver"],
      "receiverType" => message["receiverType"],
      "type" => "message",
      "category" => "action",
      "sentAt" => Time.now(),
      "conversationId" => message["conversationId"],
      "data" => %{
        "action" => action,
        "entities" => %{
          "by" => %{"entityType" => "user", "entity" => actor},
          "for" => %{"entityType" => message["receiverType"], "entity" => receiver_entity},
          "on" => %{"entityType" => "message", "entity" => message}
        }
      }
    })
  end

  @spec group_action(integer(), map(), term(), map(), term(), String.t()) :: map()
  def group_action(id, state, actor_uid, group, on_uid, action) do
    actor = state |> UserState.get_or_default(actor_uid) |> UserState.public()
    on_user = state |> UserState.get_or_default(on_uid) |> UserState.public()

    Entities.message(%{
      "id" => id,
      "sender" => actor_uid,
      "receiver" => group["guid"],
      "receiverType" => "group",
      "type" => "groupMember",
      "category" => "action",
      "sentAt" => Time.now(),
      "conversationId" => Conversations.group_conversation_id(group["guid"]),
      "data" => %{
        "action" => action,
        "entities" => %{
          "by" => %{"entityType" => "user", "entity" => actor},
          "for" => %{"entityType" => "group", "entity" => group},
          "on" => %{"entityType" => "user", "entity" => on_user}
        }
      }
    })
  end

  @spec receiver_entity(map(), String.t(), term()) :: map()
  def receiver_entity(state, "user", uid) do
    state |> UserState.get_or_default(uid) |> UserState.public()
  end

  def receiver_entity(state, "group", guid) do
    group =
      get_in(state, ["groups", to_s(guid)]) || Entities.group(%{"guid" => guid, "name" => guid})

    GroupState.with_members_count(group, state)
  end

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
