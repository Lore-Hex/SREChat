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

  test "iOS settings carry the camelCase keys the SDK's own model decodes" do
    # The third iOS force-unwrap, one field deeper than extensions.enabled: the
    # SDK's settings model is Codable with camelCase keys (chatWssPort, chatHost,
    # the webRTC* group), decoded with convertFromSnakeCase. If the port is
    # absent in that casing the WHOLE settings object decodes to nil, and
    # CometChatSocketController.connect() SIGTRAPs on SDKUserDefaults().
    # CHAT_WSS_PORT — right after a SUCCESSFUL login, so it looks like login
    # worked and then the app vanished. Bisection: the complete camelCase object
    # is the change that turns the crash into a live chat UI.
    settings = Config.ios_settings()

    required = ~w(chatHost clientAPIHost mainDomain chatAPIVersion wsAPIVersion
                  chatWsPort chatWssPort chatUseSSL webrtcHost webrtcWsPort
                  webrtcWssPort webrtcUseSSL)

    for key <- required do
      assert Map.has_key?(settings, key), "missing camelCase #{key} — crashes iOS on connect"
    end

    # Every extension still carries `enabled` in the iOS variant too.
    assert Enum.all?(settings["extensions"], &Map.has_key?(&1, "enabled"))

    # The port must stay a string: decoding it as Int (a plausible "cleanup")
    # made the entire settings payload fail to parse and broke login outright.
    assert is_binary(settings["chatWssPort"])
  end

  test "iOS and default settings must not be merged: no UPPER_SNAKE in the iOS payload" do
    # convertFromSnakeCase makes CHAT_WSS_PORT and chatWssPort collide, so a
    # response carrying BOTH decodes to nil and crashes exactly where camelCase
    # alone succeeds. The iOS payload must therefore be camelCase-ONLY.
    for key <- Map.keys(Config.ios_settings()) do
      refute key =~ ~r/^[A-Z0-9_]+$/,
             "UPPER_SNAKE key #{key} in the iOS settings collides with its camelCase twin and crashes the SDK"
    end
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
