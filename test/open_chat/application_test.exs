defmodule OpenChat.ApplicationTest do
  use ExUnit.Case, async: false

  alias OpenChat.Application, as: OpenChatApplication

  @keys [
    :allow_local_media_storage,
    :api_key,
    :media_storage,
    :reject_weak_admin_api_key,
    :s3_bucket,
    :upload_dir
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

  test "local media storage creates the upload directory only when explicitly allowed" do
    upload_dir =
      Path.join(System.tmp_dir!(), "open-chat-local-media-#{System.unique_integer([:positive])}")

    Application.put_env(:open_chat, :media_storage, "local")
    Application.put_env(:open_chat, :allow_local_media_storage, true)
    Application.put_env(:open_chat, :upload_dir, upload_dir)

    on_exit(fn -> File.rm_rf(upload_dir) end)

    refute File.exists?(upload_dir)
    assert :ok = OpenChatApplication.ensure_media_storage!()
    assert File.dir?(upload_dir)
  end

  test "local media storage is rejected when disabled for production-like environments" do
    upload_dir =
      Path.join(
        System.tmp_dir!(),
        "open-chat-disabled-media-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:open_chat, :media_storage, "local")
    Application.put_env(:open_chat, :allow_local_media_storage, false)
    Application.put_env(:open_chat, :upload_dir, upload_dir)

    on_exit(fn -> File.rm_rf(upload_dir) end)

    assert_raise ArgumentError, ~r/MEDIA_STORAGE=local is not allowed/, fn ->
      OpenChatApplication.ensure_media_storage!()
    end

    refute File.exists?(upload_dir)
  end

  test "s3 media storage requires a bucket and skips durable local upload setup" do
    upload_dir =
      Path.join(System.tmp_dir!(), "open-chat-s3-media-#{System.unique_integer([:positive])}")

    Application.put_env(:open_chat, :media_storage, "s3")
    Application.put_env(:open_chat, :s3_bucket, "openchat-test-media")
    Application.put_env(:open_chat, :upload_dir, upload_dir)

    assert :ok = OpenChatApplication.ensure_media_storage!()
    refute File.exists?(upload_dir)

    Application.delete_env(:open_chat, :s3_bucket)

    assert_raise ArgumentError, ~r/S3_BUCKET is required/, fn ->
      OpenChatApplication.ensure_media_storage!()
    end
  end

  test "production-like security config rejects weak non-empty admin API keys" do
    Application.put_env(:open_chat, :reject_weak_admin_api_key, true)

    Application.put_env(:open_chat, :api_key, "")
    assert :ok = OpenChatApplication.ensure_security_config!()

    for weak <- ["None", "null", "short"] do
      Application.put_env(:open_chat, :api_key, weak)

      assert_raise ArgumentError, ~r/COMETCHAT_API_KEY must be blank/, fn ->
        OpenChatApplication.ensure_security_config!()
      end
    end

    Application.put_env(:open_chat, :api_key, String.duplicate("a", 32))
    assert :ok = OpenChatApplication.ensure_security_config!()
  end
end
