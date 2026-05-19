defmodule OpenChat.ConfigTest do
  use ExUnit.Case, async: false

  alias OpenChat.Config

  @keys [:allow_local_media_storage, :media_storage]

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
end
