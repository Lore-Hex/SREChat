defmodule OpenChat.IosLoginContractTest do
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

  alias OpenChat.Config

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

  test "login response does not carry wsChannel" do
    # The second of the two iOS login force-unwraps: the SDK traps on our
    # wsChannel value while decoding the login response. Nothing of ours reads
    # the field — the JS SDK ignores it and the socket channel is assigned
    # server-side at WS auth — and clean-device bisection proved absence is the
    # safe shape (present = dead before the login callback, absent = LOGIN OK).
    {:ok, _} = OpenChat.Store.upsert_user(%{"uid" => "contract-ios", "name" => "Contract"})
    {:ok, me} = OpenChat.Store.me("uid:contract-ios")

    refute Map.has_key?(me, "wsChannel"),
           "wsChannel is back in the login response — this crashes iOS login on a clean device"
  end
end
