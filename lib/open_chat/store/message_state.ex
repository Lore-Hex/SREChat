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
    message = expose_metadata(message)
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
    reaction_map = get_in(state, ["reactions", to_s(message["id"])]) || %{}

    counts =
      reaction_map
      |> Enum.reject(fn {_reaction, by_uid} -> map_size(by_uid) == 0 end)
      |> Enum.map(fn {reaction, by_uid} ->
        %{
          "reaction" => reaction,
          "count" => map_size(by_uid),
          "reactedByMe" => Map.has_key?(by_uid, current_uid)
        }
      end)

    data =
      (message["data"] || %{})
      |> Map.put("reactions", counts)
      |> put_reaction_extension_metadata(reaction_map)

    message
    |> Map.put("data", data)
    |> expose_metadata()
  end

  @spec expose_metadata(map()) :: map()
  def expose_metadata(message) do
    data = message["data"] || %{}
    data_metadata = data["metadata"]
    top_metadata = message["metadata"]

    cond do
      is_map(data_metadata) and map_size(data_metadata) > 0 ->
        Map.put(message, "metadata", data_metadata)

      is_map(top_metadata) and map_size(top_metadata) > 0 ->
        Map.put(message, "data", Map.put(data, "metadata", top_metadata))

      true ->
        message
    end
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
          "for" => %{"entityType" => "group", "entity" => Entities.public_group(group)},
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
    |> Entities.public_group()
  end

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp put_reaction_extension_metadata(data, reaction_map) do
    metadata = data["metadata"] || %{}
    injected = metadata["@injected"] || %{}
    extensions = injected["extensions"] || %{}
    reactions = reaction_extension_payload(reaction_map)

    extensions =
      if map_size(reactions) == 0 do
        Map.delete(extensions, "reactions")
      else
        extensions
        |> Map.put("reactions", reactions)
        |> Map.put_new("profanity-filter", default_profanity_filter(data))
      end

    injected =
      if map_size(extensions) == 0 do
        Map.delete(injected, "extensions")
      else
        Map.put(injected, "extensions", extensions)
      end

    metadata =
      if map_size(injected) == 0 do
        Map.delete(metadata, "@injected")
      else
        Map.put(metadata, "@injected", injected)
      end

    if map_size(metadata) == 0 do
      Map.delete(data, "metadata")
    else
      Map.put(data, "metadata", metadata)
    end
  end

  defp default_profanity_filter(data) do
    %{
      "message_clean" => data["text"] || get_in(data, ["customData", "message"]) || "",
      "profanity" => "no"
    }
  end

  defp reaction_extension_payload(reaction_map) do
    reaction_map
    |> Enum.reduce(%{}, fn {reaction, by_uid}, acc ->
      users =
        by_uid
        |> Enum.reduce(%{}, fn {uid, reaction_obj}, users ->
          reacted_by = reaction_obj["reactedBy"] || %{}
          Map.put(users, uid, %{"name" => reacted_by["name"] || uid})
        end)

      if map_size(users) == 0, do: acc, else: Map.put(acc, reaction, users)
    end)
  end
end
