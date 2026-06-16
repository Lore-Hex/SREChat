defmodule OpenChat.Store.GroupPermissions do
  @moduledoc false

  alias OpenChat.Store.Records

  @moderator_scopes MapSet.new(["owner", "admin", "moderator", "coOwner"])

  def can_moderate?(state, guid, uid) do
    uid = to_s(uid)
    guid = to_s(guid)
    group = get_in(state, ["groups", guid]) || %{}

    not blank?(uid) and
      (group_owner?(group, uid) or member_scope(state, guid, uid) in @moderator_scopes)
  end

  def moderation_context(state, guid, uid) do
    uid = to_s(uid)
    guid = to_s(guid)
    group = get_in(state, ["groups", guid]) || %{}
    scope = member_scope(state, guid, uid)
    owner? = not blank?(uid) and group_owner?(group, uid)

    %{
      "owner_match" => to_s(owner?),
      "member_scope" => if(scope == "", do: "none", else: scope),
      "can_moderate" => to_s(not blank?(uid) and (owner? or scope in @moderator_scopes))
    }
  end

  defp group_owner?(group, uid) do
    [
      group["owner"],
      group["ownerUid"],
      group["ownerUuid"]
    ]
    |> Enum.any?(&(to_s(&1) == uid))
  end

  defp member_scope(state, guid, uid) do
    member = get_in(state, ["members", guid, uid]) || %{}
    Records.scope(member["scope"] || member["role"])
  end

  defp blank?(value), do: value in [nil, "", false]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
