defmodule SREChatWeb.PresenceTest do
  @moduledoc """
  Agent liveness, off the chat path.

  Heartbeats as stored chat messages cost 750 MB and an OOM loop. Heartbeats as
  transient chat messages cost nothing and delivered nothing: the agents poll
  over REST, which never sees a transient message, so agent-down detection was
  silently off for eighteen days. This is the replacement, and these tests are
  about the two ways it could lie — letting someone vouch for another agent, and
  remembering forever.
  """
  use ExUnit.Case, async: false

  alias SREChat.{Presence, Store}
  alias SREChatWeb.Endpoint

  setup do
    Agent.update(Presence, fn _ -> %{} end)
    for uid <- ~w(p-agent-0 p-agent-1), do: Store.upsert_user(%{"uid" => uid, "name" => uid})
    :ok
  end

  defp call(method, path, uid) do
    Plug.Test.conn(method, "/v3.0" <> path, "")
    |> Plug.Conn.put_req_header("authorization", "Bearer uid:#{uid}")
    |> Endpoint.call([])
  end

  test "a beat is recorded for the caller" do
    assert call(:post, "/presence/beat", "p-agent-0").status == 200
    assert %{"p-agent-0" => at} = Presence.snapshot()
    assert abs(at - System.system_time(:second)) <= 2
  end

  test "any authenticated agent can read who is alive" do
    call(:post, "/presence/beat", "p-agent-0")
    conn = call(:get, "/presence", "p-agent-1")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_integer(get_in(body, ["data", "now"]))
    assert Map.has_key?(get_in(body, ["data", "seen"]), "p-agent-0")
  end

  test "nobody can vouch for someone else" do
    # The uid comes from the TOKEN. If it came from the body, any user could
    # keep a dead agent looking alive — the one lie this table must not tell.
    conn =
      Plug.Test.conn(:post, "/v3.0/presence/beat", Jason.encode!(%{"uid" => "p-agent-1"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer uid:p-agent-0")
      |> Endpoint.call([])

    assert conn.status == 200
    seen = Presence.snapshot()
    assert Map.has_key?(seen, "p-agent-0")
    refute Map.has_key?(seen, "p-agent-1")
  end

  test "an unauthenticated beat is refused" do
    conn = Plug.Test.conn(:post, "/v3.0/presence/beat", "") |> Endpoint.call([])
    assert conn.status == 401
    assert Presence.snapshot() == %{}
  end

  test "old entries age out instead of vouching forever" do
    now = System.system_time(:second)
    Presence.beat("long-gone", now - 90_000)
    Presence.beat("recent", now)
    seen = Presence.snapshot(now)
    assert Map.has_key?(seen, "recent")
    refute Map.has_key?(seen, "long-gone")
  end

  test "the table is bounded" do
    now = System.system_time(:second)
    for i <- 1..400, do: Presence.beat("flood-#{i}", now - i)
    assert map_size(Presence.snapshot(now)) <= 256
    # The most recent survive; the oldest are what get dropped.
    assert Map.has_key?(Presence.snapshot(now), "flood-1")
  end

  test "a beat stores nothing in chat" do
    {:ok, before} = Store.messages_for_user("p-agent-0", "p-agent-1", %{"limit" => "50"})
    for _ <- 1..20, do: call(:post, "/presence/beat", "p-agent-0")
    {:ok, later} = Store.messages_for_user("p-agent-0", "p-agent-1", %{"limit" => "50"})
    assert length(later) == length(before)
  end
end
