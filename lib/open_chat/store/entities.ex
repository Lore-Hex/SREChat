defmodule OpenChat.Store.Entities do
  @moduledoc false

  alias OpenChat.Store.Records

  def user(attrs), do: Records.user(attrs)
  def public_user(nil), do: nil
  def public_user(user), do: Map.drop(user, ["authToken"])

  def group(attrs), do: Records.group(attrs)
  def public_group(nil), do: nil
  def public_group(group), do: Map.drop(group, ["password"])
  def member(guid, uid, scope, now), do: Records.member(guid, uid, scope, now)
  def ban(guid, uid, now), do: Records.ban(guid, uid, now)
  def presence(guid, uid, now, ttl_seconds), do: Records.presence(guid, uid, now, ttl_seconds)
  def message(attrs), do: Records.message(attrs)
  def reaction(attrs), do: Records.reaction(attrs)

  def with_members_count(nil, _state), do: nil

  def with_members_count(group, state) do
    guid = group["guid"]
    count = state["members"] |> Map.get(guid, %{}) |> map_size()
    group |> public_group() |> Map.put("membersCount", count)
  end

  def scope(scope), do: Records.scope(scope)
end
