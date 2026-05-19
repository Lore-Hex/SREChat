defmodule OpenChat.ConfigTest do
  use ExUnit.Case, async: false

  alias OpenChat.Config

  @keys [
    :allow_local_media_storage,
    :cors_allowed_origins,
    :dm_history_connect_grace_ms,
    :group_max_messages,
    :media_storage,
    :public_group_reads_enabled,
    :upload_allowed_mime_types,
    :upload_max_bytes
  ]

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:open_chat, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:open_chat, key)
        {key, value} -> Application.put_env(:open_chat, key, value)
      end)
    end)

    :ok
  end

  test "media storage config is normalised and local media can be disabled" do
    Application.put_env(:open_chat, :media_storage, " S3 ")
    assert Config.media_storage() == "s3"

    Application.put_env(:open_chat, :allow_local_media_storage, "false")
    refute Config.local_media_storage_allowed?()

    Application.put_env(:open_chat, :allow_local_media_storage, "true")
    assert Config.local_media_storage_allowed?()
  end

  test "boolean_env accepts a wide range of truthy and falsy strings" do
    for truthy <- [true, "true", "TRUE", "1", 1, "yes", "YES"] do
      Application.put_env(:open_chat, :allow_local_media_storage, truthy)
      assert Config.local_media_storage_allowed?(), "expected truthy for #{inspect(truthy)}"
    end

    for falsy <- [false, "false", "FALSE", "0", 0, "no", "NO"] do
      Application.put_env(:open_chat, :allow_local_media_storage, falsy)
      refute Config.local_media_storage_allowed?(), "expected falsy for #{inspect(falsy)}"
    end

    Application.put_env(:open_chat, :allow_local_media_storage, "maybe")
    refute Config.local_media_storage_allowed?()
  end

  test "integer_env parses strings, rejects non-positives, and falls back" do
    Application.put_env(:open_chat, :group_max_messages, "250")
    assert Config.group_max_messages() == 250

    Application.put_env(:open_chat, :group_max_messages, 0)
    assert Config.group_max_messages() == 1_000

    Application.put_env(:open_chat, :group_max_messages, "garbage")
    assert Config.group_max_messages() == 1_000

    Application.put_env(:open_chat, :group_max_messages, -50)
    assert Config.group_max_messages() == 1_000
  end

  test "non_negative_integer_env keeps 0 but falls back on negatives and garbage" do
    Application.put_env(:open_chat, :dm_history_connect_grace_ms, 0)
    assert Config.dm_history_connect_grace_ms() == 0

    Application.put_env(:open_chat, :dm_history_connect_grace_ms, "750")
    assert Config.dm_history_connect_grace_ms() == 750

    Application.put_env(:open_chat, :dm_history_connect_grace_ms, "-1")
    assert Config.dm_history_connect_grace_ms() == 0

    Application.put_env(:open_chat, :dm_history_connect_grace_ms, "junk")
    assert Config.dm_history_connect_grace_ms() == 0
  end

  test "cors_allowed_origin honors wildcards, exact matches, and rejections" do
    Application.put_env(:open_chat, :cors_allowed_origins, "*")
    assert Config.cors_allowed_origin("https://example.com") == "*"

    Application.put_env(
      :open_chat,
      :cors_allowed_origins,
      "https://example.com, https://www.example.com"
    )

    assert Config.cors_allowed_origin("https://example.com") == "https://example.com"
    assert Config.cors_allowed_origin("https://www.example.com") == "https://www.example.com"
    assert Config.cors_allowed_origin("https://evil.example") == nil

    Application.put_env(:open_chat, :cors_allowed_origins, "")
    assert Config.cors_allowed_origin("https://example.com") == nil
  end

  test "csv_env parses comma-separated strings and accepts lists or blanks" do
    Application.put_env(:open_chat, :upload_allowed_mime_types, " image/png , text/plain ")
    assert "image/png" in Config.upload_allowed_mime_types()
    assert "text/plain" in Config.upload_allowed_mime_types()

    Application.put_env(:open_chat, :upload_allowed_mime_types, ["image/jpeg", "image/png"])
    assert Config.upload_allowed_mime_types() == ["image/jpeg", "image/png"]

    Application.put_env(:open_chat, :upload_allowed_mime_types, "")
    refute Config.upload_allowed_mime_types() == []
    assert "image/png" in Config.upload_allowed_mime_types()
  end

  test "settings/0 returns the legacy CometChat boot contract" do
    settings = Config.settings()

    assert is_map(settings)
    assert settings["CHAT_API_VERSION"] == "v3.0"
    assert settings["WS_API_VERSION"] == "v3.0"
    assert settings["MODE"] == "DEFAULT"
    assert is_integer(settings["settingsHashReceivedAt"])
    assert is_binary(settings["settingsHash"])
    assert is_list(settings["extensions"])
  end

  test "local_jwt_secret falls back to a per-runtime persistent secret when unset" do
    previous = Application.get_env(:open_chat, :local_jwt_secret)

    try do
      Application.put_env(:open_chat, :local_jwt_secret, nil)
      generated = Config.local_jwt_secret()
      assert is_binary(generated)
      assert byte_size(generated) >= 32

      # Repeated calls return the same secret so token verification stays stable
      assert Config.local_jwt_secret() == generated

      Application.put_env(:open_chat, :local_jwt_secret, "")
      assert Config.local_jwt_secret() == generated
    after
      case previous do
        nil -> Application.delete_env(:open_chat, :local_jwt_secret)
        value -> Application.put_env(:open_chat, :local_jwt_secret, value)
      end
    end
  end

  test "public_group_reads_enabled? defaults to true and honors explicit disabling" do
    Application.delete_env(:open_chat, :public_group_reads_enabled)
    assert Config.public_group_reads_enabled?()

    Application.put_env(:open_chat, :public_group_reads_enabled, "false")
    refute Config.public_group_reads_enabled?()

    Application.put_env(:open_chat, :public_group_reads_enabled, "true")
    assert Config.public_group_reads_enabled?()
  end
end
