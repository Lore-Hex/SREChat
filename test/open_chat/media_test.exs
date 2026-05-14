defmodule OpenChat.MediaTest do
  use ExUnit.Case, async: false

  alias OpenChat.Media
  alias OpenChat.Config

  setup do
    upload_dir = "priv/static/test_uploads"
    File.mkdir_p!(upload_dir)
    old_upload_dir = Application.get_env(:open_chat, :upload_dir)
    Application.put_env(:open_chat, :upload_dir, upload_dir)

    on_exit(fn ->
      File.rm_rf!(upload_dir)
      Application.put_env(:open_chat, :upload_dir, old_upload_dir)
    end)

    :ok
  end

  test "persist_upload with valid file" do
    path = "test_file.txt"
    File.write!(path, "hello world")

    upload = %Plug.Upload{
      path: path,
      filename: "hello world!.txt",
      content_type: "text/plain"
    }

    # Ensure max bytes is enough
    old_max = Application.get_env(:open_chat, :upload_max_bytes)
    Application.put_env(:open_chat, :upload_max_bytes, 10_000_000)

    {:ok, result} = Media.persist_upload(upload)

    assert result["name"] == "hello_world_.txt"
    assert result["mimeType"] == "text/plain"
    assert result["size"] == 11
    assert result["extension"] == "txt"
    assert String.starts_with?(result["url"], "/media/")

    stored_name = result["url"] |> String.replace("/media/", "") |> URI.decode()
    assert File.exists?(Path.join(Config.upload_dir(), stored_name))

    File.rm!(path)
    Application.put_env(:open_chat, :upload_max_bytes, old_max)
  end

  test "persist_upload rejects large files" do
    old_max = Application.get_env(:open_chat, :upload_max_bytes)
    Application.put_env(:open_chat, :upload_max_bytes, 5)

    path = "large_file.txt"
    File.write!(path, "too large")

    upload = %Plug.Upload{
      path: path,
      filename: "large.txt",
      content_type: "text/plain"
    }

    {:error, error} = Media.persist_upload(upload)
    assert error["code"] == "ERR_UPLOAD_TOO_LARGE"
    assert error["details"]["maxBytes"] == 5

    File.rm!(path)
    Application.put_env(:open_chat, :upload_max_bytes, old_max)
  end

  test "persist_upload rejects invalid mime types" do
    old_allowed = Application.get_env(:open_chat, :upload_allowed_mime_types)
    Application.put_env(:open_chat, :upload_allowed_mime_types, ["image/png"])

    path = "test.txt"
    File.write!(path, "test")

    upload = %Plug.Upload{
      path: path,
      filename: "test.txt",
      content_type: "text/plain"
    }

    {:error, error} = Media.persist_upload(upload)
    assert error["code"] == "ERR_UPLOAD_TYPE_NOT_ALLOWED"

    File.rm!(path)
    Application.put_env(:open_chat, :upload_allowed_mime_types, old_allowed)
  end

  test "media_url formats correctly" do
    assert Media.media_url("test.jpg") == "/media/test.jpg"
    assert Media.media_url("space test.jpg") == "/media/space%20test.jpg"

    old_base = Application.get_env(:open_chat, :public_media_base_url)
    Application.put_env(:open_chat, :public_media_base_url, "https://cdn.example.com")
    assert Media.media_url("test.jpg") == "https://cdn.example.com/media/test.jpg"

    Application.put_env(:open_chat, :public_media_base_url, "https://cdn.example.com/")
    assert Media.media_url("test.jpg") == "https://cdn.example.com/media/test.jpg"

    Application.put_env(:open_chat, :public_media_base_url, old_base)
  end

  test "stored_name? regex" do
    assert Media.stored_name?("abc123456-file.txt")
    assert Media.stored_name?("ABCdef-ghi-jkl.png")
    refute Media.stored_name?("short-f.txt")
    refute Media.stored_name?("no_dash.txt")
  end
end
