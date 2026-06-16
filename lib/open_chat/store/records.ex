defmodule OpenChat.Store.Records.User do
  @moduledoc false

  @enforce_keys [:uid, :name, :metadata, :role, :status, :last_active_at, :tags]
  defstruct [
    :uid,
    :name,
    :avatar,
    :link,
    :metadata,
    :role,
    :status,
    :status_message,
    :last_active_at,
    :tags,
    :deactivated_at,
    :auth_token
  ]

  @type t :: %__MODULE__{
          uid: String.t(),
          name: String.t(),
          avatar: term(),
          link: term(),
          metadata: map(),
          role: String.t(),
          status: String.t(),
          status_message: term(),
          last_active_at: integer(),
          tags: list(),
          deactivated_at: integer() | nil,
          auth_token: String.t() | nil
        }
end

defmodule OpenChat.Store.Records.Group do
  @moduledoc false

  @enforce_keys [:guid, :name, :type, :owner, :metadata, :tags, :created_at]
  defstruct [
    :guid,
    :name,
    :type,
    :password,
    :icon,
    :description,
    :owner,
    :metadata,
    :tags,
    :created_at,
    :has_joined,
    :members_count
  ]

  @type t :: %__MODULE__{
          guid: String.t(),
          name: String.t(),
          type: String.t(),
          password: String.t() | nil,
          icon: term(),
          description: String.t() | nil,
          owner: String.t(),
          metadata: map(),
          tags: list(),
          created_at: integer(),
          has_joined: boolean(),
          members_count: non_neg_integer()
        }
end

defmodule OpenChat.Store.Records.Member do
  @moduledoc false

  @enforce_keys [:uid, :guid, :scope, :joined_at]
  defstruct [:uid, :guid, :scope, :joined_at]

  @type t :: %__MODULE__{
          uid: String.t(),
          guid: String.t(),
          scope: String.t(),
          joined_at: integer()
        }
end

defmodule OpenChat.Store.Records.Ban do
  @moduledoc false

  @enforce_keys [:uid, :guid, :banned_at]
  defstruct [:uid, :guid, :banned_at]

  @type t :: %__MODULE__{
          uid: String.t(),
          guid: String.t(),
          banned_at: integer()
        }
end

defmodule OpenChat.Store.Records.Presence do
  @moduledoc false

  @enforce_keys [:uid, :guid, :last_seen_at, :expires_at]
  defstruct [:uid, :guid, :last_seen_at, :expires_at]

  @type t :: %__MODULE__{
          uid: String.t(),
          guid: String.t(),
          last_seen_at: integer(),
          expires_at: integer()
        }
end

defmodule OpenChat.Store.Records.Message do
  @moduledoc false

  @enforce_keys [
    :id,
    :sender,
    :receiver,
    :receiver_type,
    :type,
    :category,
    :data,
    :sent_at,
    :conversation_id
  ]
  defstruct [
    :id,
    :muid,
    :sender,
    :receiver,
    :receiver_type,
    :type,
    :category,
    :data,
    :sent_at,
    :updated_at,
    :conversation_id,
    :resource,
    :parent_id,
    :tags,
    :edited_at,
    :edited_by,
    :deleted_at,
    :deleted_by
  ]

  @type t :: %__MODULE__{
          id: integer() | String.t(),
          muid: String.t() | nil,
          sender: String.t(),
          receiver: String.t(),
          receiver_type: String.t(),
          type: String.t(),
          category: String.t(),
          data: map(),
          sent_at: integer(),
          updated_at: integer() | nil,
          conversation_id: String.t(),
          resource: term(),
          parent_id: integer() | String.t() | nil,
          tags: list() | nil,
          edited_at: integer() | nil,
          edited_by: String.t() | nil,
          deleted_at: integer() | nil,
          deleted_by: String.t() | nil
        }
end

defmodule OpenChat.Store.Records.Reaction do
  @moduledoc false

  @enforce_keys [:message_id, :reaction, :uid, :reacted_at, :reacted_by]
  defstruct [:id, :message_id, :reaction, :uid, :reacted_at, :reacted_by]

  @type t :: %__MODULE__{
          id: integer() | String.t() | nil,
          message_id: integer() | String.t(),
          reaction: String.t(),
          uid: String.t(),
          reacted_at: integer(),
          reacted_by: map()
        }
end

defmodule OpenChat.Store.Records do
  @moduledoc false

  alias OpenChat.Time
  alias __MODULE__.{Ban, Group, Member, Message, Presence, Reaction, User}

  @type record ::
          User.t()
          | Group.t()
          | Member.t()
          | Ban.t()
          | Presence.t()
          | Message.t()
          | Reaction.t()

  @spec new_user(map()) :: User.t()
  def new_user(attrs) do
    attrs = stringify_keys(attrs)
    uid = to_s(attrs["uid"] || attrs["id"])

    %User{
      uid: uid,
      name: to_s(attrs["name"] || uid),
      avatar: attrs["avatar"],
      link: attrs["link"],
      metadata: normalise_data(attrs["metadata"] || %{}),
      role: attrs["role"] || "default",
      status: attrs["status"] || "available",
      status_message: attrs["statusMessage"],
      last_active_at: attrs["lastActiveAt"] || Time.now(),
      tags: attrs["tags"] || [],
      deactivated_at: attrs["deactivatedAt"],
      auth_token: attrs["authToken"]
    }
  end

  @spec user(map()) :: map()
  def user(attrs), do: attrs |> new_user() |> to_map()

  @spec new_group(map()) :: Group.t()
  def new_group(attrs) do
    attrs = stringify_keys(attrs)
    guid = to_s(attrs["guid"] || attrs["id"])

    %Group{
      guid: guid,
      name: to_s(attrs["name"] || guid),
      type: attrs["type"] || "public",
      password: attrs["password"],
      icon: attrs["icon"],
      description: attrs["description"],
      owner: attrs["owner"] || attrs["ownerUid"] || attrs["ownerUuid"] || "system",
      metadata: normalise_data(attrs["metadata"] || %{}),
      tags: attrs["tags"] || [],
      created_at: attrs["createdAt"] || Time.now(),
      has_joined: attrs["hasJoined"] || false,
      members_count: attrs["membersCount"] || 0
    }
  end

  @spec group(map()) :: map()
  def group(attrs), do: attrs |> new_group() |> to_map()

  @spec new_member(term(), term(), term(), integer()) :: Member.t()
  def new_member(guid, uid, scope, now \\ Time.now()) do
    %Member{uid: to_s(uid), guid: to_s(guid), scope: scope(scope), joined_at: now}
  end

  @spec member(term(), term(), term(), integer()) :: map()
  def member(guid, uid, scope, now \\ Time.now()),
    do: guid |> new_member(uid, scope, now) |> to_map()

  @spec new_ban(term(), term(), integer()) :: Ban.t()
  def new_ban(guid, uid, now \\ Time.now()) do
    %Ban{uid: to_s(uid), guid: to_s(guid), banned_at: now}
  end

  @spec ban(term(), term(), integer()) :: map()
  def ban(guid, uid, now \\ Time.now()), do: guid |> new_ban(uid, now) |> to_map()

  @spec new_presence(term(), term(), integer(), integer()) :: Presence.t()
  def new_presence(guid, uid, now, ttl_seconds) do
    %Presence{
      uid: to_s(uid),
      guid: to_s(guid),
      last_seen_at: now,
      expires_at: now + ttl_seconds
    }
  end

  @spec presence(term(), term(), integer(), integer()) :: map()
  def presence(guid, uid, now, ttl_seconds),
    do: guid |> new_presence(uid, now, ttl_seconds) |> to_map()

  @spec new_message(map()) :: Message.t()
  def new_message(attrs) do
    attrs = stringify_keys(attrs)
    sent_at = attrs["sentAt"] || Time.now()

    %Message{
      id: attrs["id"],
      muid: attrs["muid"],
      sender: to_s(attrs["sender"]),
      receiver: to_s(attrs["receiver"]),
      receiver_type: attrs["receiverType"] |> to_s() |> String.downcase(),
      type: attrs["type"] || "text",
      category: attrs["category"] || "message",
      data: normalise_data(attrs["data"] || %{}),
      sent_at: sent_at,
      updated_at: attrs["updatedAt"] || sent_at,
      conversation_id: to_s(attrs["conversationId"]),
      resource: attrs["resource"],
      parent_id: attrs["parentId"] || attrs["parentMessageId"],
      tags: attrs["tags"],
      edited_at: attrs["editedAt"],
      edited_by: attrs["editedBy"],
      deleted_at: attrs["deletedAt"],
      deleted_by: attrs["deletedBy"]
    }
  end

  @spec message(map()) :: map()
  def message(attrs), do: attrs |> new_message() |> to_map()

  @spec new_reaction(map()) :: Reaction.t()
  def new_reaction(attrs) do
    attrs = stringify_keys(attrs)

    %Reaction{
      id: attrs["id"],
      message_id: attrs["messageId"],
      reaction: to_s(attrs["reaction"]),
      uid: to_s(attrs["uid"]),
      reacted_at: attrs["reactedAt"] || Time.now(),
      reacted_by: attrs["reactedBy"] || %{}
    }
  end

  @spec reaction(map()) :: map()
  def reaction(attrs), do: attrs |> new_reaction() |> to_map()

  @spec to_map(record()) :: map()
  def to_map(%User{} = user) do
    %{
      "uid" => user.uid,
      "name" => user.name,
      "avatar" => user.avatar,
      "link" => user.link,
      "metadata" => user.metadata,
      "role" => user.role,
      "status" => user.status,
      "statusMessage" => user.status_message,
      "lastActiveAt" => user.last_active_at,
      "tags" => user.tags,
      "deactivatedAt" => user.deactivated_at,
      "authToken" => user.auth_token
    }
    |> compact()
  end

  def to_map(%Group{} = group) do
    %{
      "guid" => group.guid,
      "name" => group.name,
      "type" => group.type,
      "password" => group.password,
      "icon" => group.icon,
      "description" => group.description,
      "owner" => group.owner,
      "metadata" => group.metadata,
      "tags" => group.tags,
      "createdAt" => group.created_at,
      "hasJoined" => group.has_joined,
      "membersCount" => group.members_count
    }
    |> compact()
  end

  def to_map(%Member{} = member) do
    %{
      "uid" => member.uid,
      "guid" => member.guid,
      "scope" => member.scope,
      "role" => member.scope,
      "joinedAt" => member.joined_at
    }
  end

  def to_map(%Ban{} = ban) do
    %{"uid" => ban.uid, "guid" => ban.guid, "bannedAt" => ban.banned_at}
  end

  def to_map(%Presence{} = presence) do
    %{
      "uid" => presence.uid,
      "guid" => presence.guid,
      "lastSeenAt" => presence.last_seen_at,
      "expiresAt" => presence.expires_at
    }
  end

  def to_map(%Message{} = message) do
    %{
      "id" => message.id,
      "muid" => message.muid,
      "sender" => message.sender,
      "receiver" => message.receiver,
      "receiverType" => message.receiver_type,
      "type" => message.type,
      "category" => message.category,
      "data" => message.data,
      "sentAt" => message.sent_at,
      "updatedAt" => message.updated_at,
      "conversationId" => message.conversation_id,
      "resource" => message.resource,
      "parentId" => message.parent_id,
      "tags" => message.tags,
      "editedAt" => message.edited_at,
      "editedBy" => message.edited_by,
      "deletedAt" => message.deleted_at,
      "deletedBy" => message.deleted_by
    }
    |> compact()
  end

  def to_map(%Reaction{} = reaction) do
    %{
      "id" => reaction.id,
      "messageId" => reaction.message_id,
      "reaction" => reaction.reaction,
      "uid" => reaction.uid,
      "reactedAt" => reaction.reacted_at,
      "reactedBy" => reaction.reacted_by
    }
    |> compact()
  end

  @spec scope(term()) :: String.t()
  def scope("participants"), do: "participant"
  def scope("members"), do: "participant"
  def scope("admins"), do: "admin"
  def scope("moderators"), do: "moderator"
  def scope("mod"), do: "moderator"
  def scope("mods"), do: "moderator"
  def scope("administrator"), do: "admin"
  def scope("administrators"), do: "admin"

  def scope(scope) when scope in ["owner", "admin", "moderator", "participant"],
    do: scope

  def scope("coOwner"), do: "coOwner"
  def scope("coowner"), do: "coOwner"
  def scope("co_owner"), do: "coOwner"
  def scope("co-owner"), do: "coOwner"
  def scope(_scope), do: "participant"

  defp normalise_data(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> stringify_keys(decoded)
      {:ok, decoded} -> decoded
      _other -> value
    end
  end

  defp normalise_data(value) when is_map(value), do: stringify_keys(value)
  defp normalise_data(nil), do: %{}
  defp normalise_data(other), do: other

  defp stringify_keys(%{__struct__: _} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_s(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
