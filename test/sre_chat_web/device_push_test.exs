defmodule SREChatWeb.DevicePushTest do
  use SREChat.HttpCase, async: false

  alias SREChat.Store

  setup do
    Store.reset!()
    :ok
  end

  # A uid that was never touched has no user record at all, which is a stronger
  # result than "exists with an empty token map" — so treat both as no devices.
  defp tokens_for(uid) do
    case Store.get_user(uid) do
      {:ok, user} -> get_in(user, ["metadata", "apnsTokens"]) || %{}
      :error -> %{}
    end
  end

  # The in-memory test state hands every handler a fully populated
  # `state["users"]`, but a deployment hydrates only the keys the request plan
  # asks for. A Store call with no plan clause falls through to
  # `build(_request) -> read([])`, which is silent: registering then builds a
  # blank user over the real record and forgetting reports "user not found".
  # Both were live in production and invisible to every test below, so assert
  # the plan directly.
  describe "request plan" do
    alias SREChat.Store.RequestPlan

    test "register_device hydrates the user record and takes its lock" do
      plan = RequestPlan.build({:register_device, "alice", %{"token" => "t"}})
      assert plan.mutating?
      assert {"users", "alice"} in plan.refresh
      assert {:user, "alice"} in plan.locks
    end

    test "forget_device hydrates the user record and takes its lock" do
      plan = RequestPlan.build({:forget_device, "alice", "t"})
      assert plan.mutating?
      assert {"users", "alice"} in plan.refresh
      assert {:user, "alice"} in plan.locks
    end

    test "an unplanned call is the silent fallback these clauses exist to avoid" do
      # Documents the trap rather than asserting good behaviour: this is what
      # both device calls used to get.
      plan = RequestPlan.build({:no_such_store_call, "alice"})
      refute plan.mutating?
      assert plan.refresh == []
    end
  end

  test "registering a device stores it under the caller's own uid" do
    conn =
      auth_conn(
        :post,
        "/v3.0/me/devices",
        %{"token" => "abc123", "env" => "development"},
        "uid:alice"
      )

    assert conn.status == 200
    assert json(conn)["data"]["success"] == true

    assert %{"abc123" => entry} = tokens_for("alice")
    assert entry["env"] == "development"
    assert is_integer(entry["updatedAt"])
  end

  test "a device cannot be registered against someone else" do
    # The uid comes from the auth token, never the body. If this ever regressed,
    # anyone signed in could redirect the owner's pages to their own phone.
    conn =
      auth_conn(
        :post,
        "/v3.0/me/devices",
        %{"token" => "mallory-phone", "uid" => "joseph"},
        "uid:mallory"
      )

    assert conn.status == 200
    assert Map.has_key?(tokens_for("mallory"), "mallory-phone")
    assert tokens_for("joseph") == %{}
  end

  test "a second device is added rather than replacing the first" do
    auth_conn(:post, "/v3.0/me/devices", %{"token" => "phone"}, "uid:alice")
    auth_conn(:post, "/v3.0/me/devices", %{"token" => "ipad"}, "uid:alice")

    assert tokens_for("alice") |> Map.keys() |> Enum.sort() == ["ipad", "phone"]
  end

  test "registering does not clobber unrelated metadata" do
    # upsert_user merges only at the top level, so writing metadata naively
    # would silently drop every other key in it.
    Store.upsert_user(%{"uid" => "alice", "metadata" => %{"theme" => "dark"}})
    auth_conn(:post, "/v3.0/me/devices", %{"token" => "phone"}, "uid:alice")

    {:ok, user} = Store.get_user("alice")
    assert user["metadata"]["theme"] == "dark"
    assert Map.has_key?(user["metadata"]["apnsTokens"], "phone")
  end

  test "re-registering the same token refreshes it instead of duplicating" do
    auth_conn(
      :post,
      "/v3.0/me/devices",
      %{"token" => "phone", "env" => "development"},
      "uid:alice"
    )

    auth_conn(
      :post,
      "/v3.0/me/devices",
      %{"token" => "phone", "env" => "production"},
      "uid:alice"
    )

    assert %{"phone" => entry} = tokens_for("alice")
    assert map_size(tokens_for("alice")) == 1
    assert entry["env"] == "production"
  end

  test "a device can be forgotten, which is how a 410 from Apple is handled" do
    auth_conn(:post, "/v3.0/me/devices", %{"token" => "phone"}, "uid:alice")
    auth_conn(:post, "/v3.0/me/devices", %{"token" => "ipad"}, "uid:alice")

    conn = auth_conn(:delete, "/v3.0/me/devices/phone", %{}, "uid:alice")
    assert conn.status == 200
    assert Map.keys(tokens_for("alice")) == ["ipad"]
  end

  test "a token is required" do
    conn = auth_conn(:post, "/v3.0/me/devices", %{"env" => "development"}, "uid:alice")
    assert conn.status == 400
  end

  test "registering requires authentication" do
    conn = conn(:post, "/v3.0/me/devices", %{"token" => "phone"}) |> SREChatWeb.Endpoint.call([])
    assert conn.status == 401
  end

  test "the sender can read back a peer's devices, which is how the agent pages you" do
    auth_conn(:post, "/v3.0/me/devices", %{"token" => "joseph-phone"}, "uid:joseph")

    conn = auth_conn(:get, "/v3.0/users/joseph", %{}, "uid:sre-agent-0")
    assert conn.status == 200
    assert Map.has_key?(json(conn)["data"]["metadata"]["apnsTokens"], "joseph-phone")
  end
end
