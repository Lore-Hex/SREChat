defmodule SREChat.IosLoginContractTest do
  @moduledoc """
  The login response shape the CometChat iOS SDK will not tolerate.

  The SDK force unwraps fields while decoding the login response, so a missing
  key is not a degraded feature — it is a SIGTRAP inside
  `CometChat.loginCallToServerWith`, on a URLSession completion queue, before
  the login callback can fire. From the app it looks like login hangs forever.

  Every iOS login died on `settings.extensions` entries that carried only `id`
  and `name`. The JS SDK tolerates the omission, so the web client kept working
  and hid it. Confirmed by bisection: serving the identical response with
  `enabled` added is the single change that turns the crash into LOGIN OK.
  """
  use ExUnit.Case, async: true

  alias SREChat.Config

  test "every advertised extension carries the keys the iOS SDK unwraps" do
    extensions = Config.settings()["extensions"]

    assert is_list(extensions)
    refute extensions == [], "an empty list is safe, but then say so deliberately"

    for extension <- extensions do
      assert Map.has_key?(extension, "enabled"),
             "extension #{inspect(extension["id"])} has no \"enabled\" — this crashes iOS login"

      assert is_boolean(extension["enabled"])
      assert Map.has_key?(extension, "id")
      assert Map.has_key?(extension, "name")
    end
  end

  test "settings still carry the transport keys the SDK needs to dial the socket" do
    settings = Config.settings()

    for key <- ~w(CHAT_HOST CHAT_WSS_PORT CHAT_WS_PORT CHAT_USE_SSL CHAT_API_VERSION) do
      assert Map.has_key?(settings, key), "missing #{key}"
    end
  end

  test "settings stay UPPER_SNAKE for every client" do
    # The SDK's settings model uses camelCase PROPERTY names mapped by
    # CodingKeys onto these UPPER_SNAKE JSON keys — which is why both spellings
    # appear in its binary. Serving camelCase instead made the decode leave
    # chat_wss_port nil, and CometChatSocketController.connect() then returned
    # at its own port guard WITHOUT dialling and without an error: the socket
    # simply never existed. Both clients get the same UPPER_SNAKE payload.
    settings = Config.settings()

    for key <- ~w(CHAT_HOST CHAT_WSS_PORT CHAT_WS_PORT CHAT_USE_SSL) do
      assert Map.has_key?(settings, key), "missing #{key} — the iOS socket will not dial"
    end

    refute Map.has_key?(settings, "chatWssPort"),
           "camelCase settings leave the SDK's port nil and silently kill the socket"

    assert Config.ios_settings() == settings, "no per-client divergence today"

    # The port must stay a string: decoding it as Int broke the whole payload.
    assert is_binary(settings["CHAT_WSS_PORT"])
  end

  test "CHAT_HOST carries no port or path, or the socket URL is malformed" do
    # The SDK builds wss://<CHAT_HOST>:<CHAT_WSS_PORT>. A host carrying a port
    # or an API-version path yields wss://host:4443:4443 or wss://host/v3.0:443,
    # neither of which is a URL — the client force-unwraps nil and dies.
    host = Config.settings()["CHAT_HOST"]

    refute String.contains?(host, ":"), "CHAT_HOST must not carry a port"
    refute String.contains?(host, "/"), "CHAT_HOST must not carry a path"
  end

  test "the login JWT is structurally decodable" do
    # The fourth iOS defect. The header segment used to be the literal string
    # "local" — 5 characters, and a base64 segment can never be 1 more than a
    # multiple of 4, so the token could not be decoded by anything that tried.
    # The JS SDK never looks inside it; the iOS SDK does, gets nil, and by its
    # own log line ("jwtToken found nil calling disconnect") tears the socket
    # down BEFORE dialling — which is why the native client made zero WebSocket
    # attempts while every REST call succeeded.
    alias SREChat.Store.AuthTokens

    jwt = AuthTokens.local_jwt("alice", "uid:alice")
    assert [header, payload, _signature] = String.split(jwt, ".", parts: 3)

    assert {:ok, header_json} = Base.url_decode64(header, padding: false)
    assert %{"alg" => _, "typ" => "JWT"} = Jason.decode!(header_json)

    assert {:ok, payload_json} = Base.url_decode64(payload, padding: false)
    assert %{"uid" => "alice", "token" => "uid:alice"} = Jason.decode!(payload_json)

    # Every segment must be valid base64url, which is what "decodable" means to
    # a strict client.
    for segment <- String.split(jwt, ".") do
      assert rem(String.length(segment), 4) != 1,
             "segment #{segment} has an impossible base64 length"
    end
  end

  test "tokens minted before the JWT header fix still authenticate" do
    # Those are in clients' hands right now; rejecting them signs everyone out.
    alias SREChat.Store.AuthTokens

    jwt = AuthTokens.local_jwt("alice", "uid:alice")
    [_header, payload, signature] = String.split(jwt, ".", parts: 3)

    assert {:ok, "uid:alice"} = AuthTokens.local_jwt_token(jwt)
    assert {:ok, "uid:alice"} = AuthTokens.local_jwt_token("local.#{payload}.#{signature}")
    # But an arbitrary header is still not a free pass.
    assert :error = AuthTokens.local_jwt_token("bogus.#{payload}.#{signature}")
  end

  test "the iOS SDK is recognised by its resource header" do
    assert Config.ios_client?("ios-4_1_7-abc123")
    refute Config.ios_client?("js-4_0_0-abc123")
    refute Config.ios_client?(nil)
    refute Config.ios_client?("")
  end

  test "login response does not carry wsChannel" do
    # The second of the two iOS login force-unwraps: the SDK traps on our
    # wsChannel value while decoding the login response. Nothing of ours reads
    # the field — the JS SDK ignores it and the socket channel is assigned
    # server-side at WS auth — and clean-device bisection proved absence is the
    # safe shape (present = dead before the login callback, absent = LOGIN OK).
    {:ok, _} = SREChat.Store.upsert_user(%{"uid" => "contract-ios", "name" => "Contract"})
    {:ok, me} = SREChat.Store.me("uid:contract-ios")

    refute Map.has_key?(me, "wsChannel"),
           "wsChannel is back in the login response — this crashes iOS login on a clean device"
  end
end
