defmodule SREChatWeb.HooksTest do
  @moduledoc """
  POST /hooks/<source> — where Sentry, GCP alerting, CI and forwarded help@ mail
  get into the chat.

  The first version delivered to the owner alone. It returned a truthful 200 and
  the feature was still useless twice over: the message landed in a `webhook` DM
  thread nobody watches, and the agent — which polls its OWN conversations —
  could not see it, so "alert me and let the agent investigate" investigated
  nothing. Both recipients are asserted here because either one missing is a
  silent failure that still answers 200.
  """
  use ExUnit.Case, async: false

  alias SREChatWeb.Endpoint

  @secret "test-webhook-secret"

  setup do
    previous = Application.get_env(:sre_chat, :webhook_secret)
    Application.put_env(:sre_chat, :webhook_secret, @secret)
    on_exit(fn -> Application.put_env(:sre_chat, :webhook_secret, previous) end)
    :ok
  end

  defp post(path, payload) do
    Plug.Test.conn(:post, path, Jason.encode!(payload))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Endpoint.call([])
  end

  describe "authentication" do
    test "no token is refused" do
      conn = post("/hooks/sentry", %{"message" => "boom"})
      assert conn.status == 403
    end

    test "a wrong token is refused" do
      conn = post("/hooks/sentry?token=wrong", %{"message" => "boom"})
      assert conn.status == 403
    end

    test "a bearer header authenticates, so the secret stays out of the URL" do
      # Sentry masks saved header values and a header never reaches our access
      # logs, so this is the form production uses.
      conn =
        Plug.Test.conn(:post, "/hooks/sentry", Jason.encode!(%{"message" => "boom"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{@secret}")
        |> Endpoint.call([])

      assert conn.status == 200
    end

    test "a wrong bearer header is refused" do
      conn =
        Plug.Test.conn(:post, "/hooks/sentry", Jason.encode!(%{"message" => "boom"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer nope")
        |> Endpoint.call([])

      assert conn.status == 403
    end

    test "an unrelated authorization header does not shadow a valid ?token=" do
      # The header must fall THROUGH when it is not a bearer token, or adding a
      # proxy that stamps its own Authorization silently breaks every sender
      # using the query form.
      conn =
        Plug.Test.conn(
          :post,
          "/hooks/sentry?token=#{@secret}",
          Jason.encode!(%{"message" => "b"})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> Endpoint.call([])

      assert conn.status == 200
    end

    test "an unconfigured deployment fails CLOSED" do
      # An open endpoint that posts to your pager is worse than a broken one.
      Application.put_env(:sre_chat, :webhook_secret, nil)
      conn = post("/hooks/sentry?token=anything", %{"message" => "boom"})
      assert conn.status == 503
    end

    test "an empty configured secret is not a valid token" do
      # Otherwise `SRE_WEBHOOK_SECRET=` in an env file makes ?token= authenticate.
      Application.put_env(:sre_chat, :webhook_secret, "")
      conn = post("/hooks/sentry?token=", %{"message" => "boom"})
      assert conn.status == 503
    end
  end

  describe "sentry signature auth" do
    @client_secret "sentry-client-secret-abc123"

    setup do
      previous = Application.get_env(:sre_chat, :sentry_client_secret)
      Application.put_env(:sre_chat, :sentry_client_secret, @client_secret)
      on_exit(fn -> Application.put_env(:sre_chat, :sentry_client_secret, previous) end)
      :ok
    end

    defp signed(body, secret \\ @client_secret) do
      digest = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

      Plug.Test.conn(:post, "/hooks/sentry", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("sentry-hook-signature", digest)
      |> Endpoint.call([])
    end

    test "a correctly signed payload is accepted with NO token at all" do
      # The whole point: Sentry holds the key, so nothing has to be pasted into
      # its UI and no shared secret needs to exist on that side.
      conn = signed(Jason.encode!(%{"message" => "signed probe #{unique()}"}))
      assert conn.status == 200
    end

    test "a payload signed with the wrong secret is refused" do
      conn = signed(Jason.encode!(%{"message" => "boom"}), "not-the-secret")
      assert conn.status == 403
    end

    test "a tampered body fails even with a signature that was once valid" do
      # This is what signing buys over a bearer token: the digest covers the
      # BODY, so replaying a captured header against different content fails.
      original = Jason.encode!(%{"message" => "original"})

      digest =
        :crypto.mac(:hmac, :sha256, @client_secret, original) |> Base.encode16(case: :lower)

      conn =
        Plug.Test.conn(:post, "/hooks/sentry", Jason.encode!(%{"message" => "tampered"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("sentry-hook-signature", digest)
        |> Endpoint.call([])

      assert conn.status == 403
    end

    test "a malformed digest is invalid, not a crash" do
      for bogus <- ["", "zz", "not-hex-at-all", String.duplicate("a", 63)] do
        conn =
          Plug.Test.conn(:post, "/hooks/sentry", Jason.encode!(%{"message" => "x"}))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("sentry-hook-signature", bogus)
          |> Endpoint.call([])

        assert conn.status == 403, "digest #{inspect(bogus)} did not 403"
      end
    end

    test "signature auth does not disable the shared-secret path" do
      conn =
        Plug.Test.conn(:post, "/hooks/gcp", Jason.encode!(%{"message" => "boom"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{@secret}")
        |> Endpoint.call([])

      assert conn.status == 200
    end

    test "with NO client secret configured a signature proves nothing" do
      # Otherwise an unconfigured deployment would accept any request that
      # merely carried a signature header.
      Application.put_env(:sre_chat, :sentry_client_secret, nil)
      conn = signed(Jason.encode!(%{"message" => "boom"}))
      assert conn.status == 403
    end

    test "an unsigned request still needs a token even when signing is enabled" do
      conn = post("/hooks/sentry", %{"message" => "boom"})
      assert conn.status == 403
    end
  end

  describe "delivery" do
    test "a valid signal is accepted" do
      conn = post("/hooks/sentry?token=#{@secret}", %{"message" => "ArgumentError: boom"})
      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    test "it reaches BOTH the owner and this region's agent" do
      owner = SREChat.Config.owner_uid()
      agent = SREChat.Config.agent_uid()
      refute owner == agent

      post("/hooks/sentry?token=#{@secret}", %{"message" => "delivery probe #{unique()}"})

      # The owner's copy is so an error is visible when the agent is dead — the
      # moment you most want to see it. The agent's copy is so something triages
      # it in seconds rather than whenever a human next opens the app.
      assert delivered_to?(owner, "delivery probe"),
             "the owner never got the signal"

      assert delivered_to?(agent, "delivery probe"),
             "the agent never got the signal, so nothing will investigate it"
    end

    test "the sender is `webhook`, not the owner or the agent" do
      # The agent branches on this uid to keep signals out of its command path,
      # so the sender is load-bearing, not cosmetic.
      post("/hooks/sentry?token=#{@secret}", %{"message" => "sender probe #{unique()}"})

      message = last_matching(SREChat.Config.agent_uid(), "sender probe")
      assert message["sender"] == "webhook"
    end
  end

  describe "the region decides who its agent is" do
    test "the agent uid follows the region index by default" do
      previous = Application.get_env(:sre_chat, :agent_uid)
      Application.put_env(:sre_chat, :agent_uid, nil)
      on_exit(fn -> Application.put_env(:sre_chat, :agent_uid, previous) end)

      assert SREChat.Config.agent_uid() == "sre-agent-#{SREChat.Config.region_index()}"
    end

    test "a set-but-empty uid falls back rather than addressing nobody" do
      # `SRE_AGENT_UID=` in a .env file stores "", which is truthy in Elixir.
      previous = Application.get_env(:sre_chat, :agent_uid)
      Application.put_env(:sre_chat, :agent_uid, "")
      on_exit(fn -> Application.put_env(:sre_chat, :agent_uid, previous) end)

      assert SREChat.Config.agent_uid() == "sre-agent-#{SREChat.Config.region_index()}"
    end

    test "a set-but-empty owner uid falls back too" do
      previous = Application.get_env(:sre_chat, :owner_uid)
      Application.put_env(:sre_chat, :owner_uid, "")
      on_exit(fn -> Application.put_env(:sre_chat, :owner_uid, previous) end)

      assert SREChat.Config.owner_uid() == "joseph"
    end

    test "an explicit uid overrides it" do
      previous = Application.get_env(:sre_chat, :agent_uid)
      Application.put_env(:sre_chat, :agent_uid, "sre-agent-elsewhere")
      on_exit(fn -> Application.put_env(:sre_chat, :agent_uid, previous) end)

      assert SREChat.Config.agent_uid() == "sre-agent-elsewhere"
    end
  end

  # -- helpers --------------------------------------------------------------

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  defp delivered_to?(uid, needle), do: last_matching(uid, needle) != nil

  # Read the recipient's side of the conversation with `webhook`, which is where
  # a delivery to that uid actually lands.
  defp last_matching(uid, needle) do
    uid
    |> SREChat.Store.messages_for_user("webhook", %{"limit" => "50"})
    |> unwrap()
    |> Enum.filter(fn message ->
      text = get_in(message, ["data", "text"]) || ""
      String.contains?(text, needle)
    end)
    |> List.last()
  end

  defp unwrap({:ok, messages}) when is_list(messages), do: messages
  defp unwrap(messages) when is_list(messages), do: messages
  defp unwrap(other), do: flunk("unexpected store reply: #{inspect(other)}")
end
