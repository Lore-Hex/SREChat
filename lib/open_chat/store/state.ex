defmodule OpenChat.Store.State do
  @moduledoc false

  @type bucket ::
          :users
          | :tokens
          | :groups
          | :members
          | :messages
          | :conversation_messages
          | :conversation_latest
          | :thread_messages
          | :reads
          | :delivered
          | :hidden_conversations
          | :reactions
          | :blocks
          | :banned
          | :message_muids
          | :user_conversations
          | :conversation_users
          | :user_groups
          | :unread_counts
          | :presence

  @type counter :: :next_id | :next_reaction_id
  @type t :: %{String.t() => map() | integer()}

  @default %{
    "users" => %{},
    "tokens" => %{},
    "groups" => %{},
    "members" => %{},
    "messages" => %{},
    "conversation_messages" => %{},
    "conversation_latest" => %{},
    "thread_messages" => %{},
    "reads" => %{},
    "delivered" => %{},
    "hidden_conversations" => %{},
    "reactions" => %{},
    "blocks" => %{},
    "banned" => %{},
    "message_muids" => %{},
    "user_conversations" => %{},
    "conversation_users" => %{},
    "user_groups" => %{},
    "unread_counts" => %{},
    "presence" => %{},
    "next_id" => 1,
    "next_reaction_id" => 1
  }

  @spec default() :: t()
  def default, do: @default

  @spec bucket(t(), bucket() | String.t()) :: map()
  def bucket(state, bucket), do: Map.get(state, key(bucket), %{}) || %{}

  @spec fetch_record(t(), bucket() | String.t(), term()) :: {:ok, term()} | :error
  def fetch_record(state, bucket, id), do: Map.fetch(bucket(state, bucket), to_s(id))

  @spec get_record(t(), bucket() | String.t(), term(), term()) :: term()
  def get_record(state, bucket, id, default \\ nil),
    do: Map.get(bucket(state, bucket), to_s(id), default)

  @spec put_record(t(), bucket() | String.t(), term(), term()) :: t()
  def put_record(state, bucket, id, value), do: put_in(state, [key(bucket), to_s(id)], value)

  @spec delete_record(t(), bucket() | String.t(), term()) :: t()
  def delete_record(state, bucket, id) do
    update_in(state, [key(bucket)], &Map.delete(&1 || %{}, to_s(id)))
  end

  @spec update_bucket(t(), bucket() | String.t(), (map() -> map())) :: t()
  def update_bucket(state, bucket, fun) when is_function(fun, 1) do
    update_in(state, [key(bucket)], &(fun.(&1 || %{}) || %{}))
  end

  @spec counter(t(), counter() | String.t()) :: integer()
  def counter(state, counter), do: state |> Map.get(key(counter), 1) |> to_int()

  @spec put_counter(t(), counter() | String.t(), integer()) :: t()
  def put_counter(state, counter, value), do: Map.put(state, key(counter), max(to_int(value), 1))

  @spec decode_seed(String.t() | nil, list()) :: list()
  def decode_seed(json, default) do
    case Jason.decode(json || "") do
      {:ok, list} when is_list(list) -> list
      {:ok, map} when is_map(map) -> Map.values(map)
      _other -> default
    end
  end

  @spec default_users() :: [map()]
  def default_users do
    [
      %{"uid" => "alice", "name" => "Alice Example"},
      %{"uid" => "bob", "name" => "Bob Example"},
      %{"uid" => "carol", "name" => "Carol Example"},
      %{"uid" => "system", "name" => "System"}
    ]
  end

  @spec default_groups() :: [map()]
  def default_groups do
    [
      %{"guid" => "lobby", "name" => "Lobby", "type" => "public", "owner" => "system"}
    ]
  end

  defp key(value) when is_atom(value), do: value |> Atom.to_string()
  defp key(value), do: to_s(value)

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, _rest} -> i
      :error -> 0
    end
  end

  defp to_int(value), do: value |> to_s() |> to_int()
end
