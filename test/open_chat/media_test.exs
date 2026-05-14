defmodule OpenChat.MediaTest do
  use ExUnit.Case, async: false

  alias OpenChat.Media
  alias OpenChat.Config

  setup do
    upload_dir = "priv/static/test_uploads"
    File.mkdir_p!(upload_dir)
    old_upload_dir = Application.get_env(:open_chat, :upload_dir)
    old_media_storage = Application.get_env(:open_chat, :media_storage)
    old_s3_bucket = Application.get_env(:open_chat, :s3_bucket)
    old_s3_client = Application.get_env(:open_chat, :s3_client)
    old_s3_ttl = Application.get_env(:open_chat, :s3_presigned_url_ttl_seconds)
    old_public_media_base_url = Application.get_env(:open_chat, :public_media_base_url)
    Application.put_env(:open_chat, :upload_dir, upload_dir)
    Application.put_env(:open_chat, :media_storage, "local")
    OpenChat.MockS3.reset()

    on_exit(fn ->
      File.rm_rf!(upload_dir)
      Application.put_env(:open_chat, :upload_dir, old_upload_dir)
      Application.put_env(:open_chat, :media_storage, old_media_storage)
      Application.put_env(:open_chat, :s3_bucket, old_s3_bucket)
      Application.put_env(:open_chat, :s3_client, old_s3_client)
      Application.put_env(:open_chat, :s3_presigned_url_ttl_seconds, old_s3_ttl)
      Application.put_env(:open_chat, :public_media_base_url, old_public_media_base_url)
      OpenChat.MockS3.reset()
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
    assert {:ok, %{path: stored_path, content_type: "text/plain"}} = Media.fetch(stored_name)
    assert File.read!(stored_path) == "hello world"

    File.rm!(path)
    Application.put_env(:open_chat, :upload_max_bytes, old_max)
  end

  test "persist_upload stores media in S3 when configured" do
    Application.put_env(:open_chat, :media_storage, "s3")
    Application.put_env(:open_chat, :s3_bucket, "openchat-test-uploads")
    Application.put_env(:open_chat, :s3_client, OpenChat.MockS3)
    Application.put_env(:open_chat, :public_media_base_url, "https://openchat.example")

    path = "s3_file.png"
    File.write!(path, "png bytes")

    upload = %Plug.Upload{
      path: path,
      filename: "sample image.png",
      content_type: "image/png"
    }

    {:ok, result} = Media.persist_upload(upload)

    assert result["name"] == "sample_image.png"
    assert result["mimeType"] == "image/png"
    assert result["size"] == 9
    assert result["url"] =~ ~r(^https://openchat.example/media/[A-Za-z0-9_-]+-sample_image\.png$)

    stored_name =
      result["url"] |> String.replace("https://openchat.example/media/", "") |> URI.decode()

    assert {:ok, %{body: "png bytes", content_type: "image/png"}} = Media.fetch(stored_name)
    refute File.exists?(Path.join(Config.upload_dir(), stored_name))

    File.rm!(path)
  end

  test "sign_urls returns fresh signed S3 URLs for stored media references" do
    Application.put_env(:open_chat, :media_storage, "s3")
    Application.put_env(:open_chat, :s3_bucket, "openchat-test-uploads")
    Application.put_env(:open_chat, :s3_client, OpenChat.MockS3)
    Application.put_env(:open_chat, :s3_presigned_url_ttl_seconds, 900)
    Application.put_env(:open_chat, :public_media_base_url, "https://openchat.example")

    data = %{
      "data" => %{
        "url" => "https://openchat.example/media/abc123456-photo.png",
        "attachments" => [
          %{"url" => "https://openchat.example/media/abc123456-photo.png"}
        ]
      }
    }

    signed = Media.sign_urls(data)

    attachment_url =
      signed |> get_in(["data", "attachments"]) |> List.first() |> Map.fetch!("url")

    refute Map.has_key?(signed["data"], "url")
    assert attachment_url =~ "https://openchat-test-uploads.s3.test/abc123456-photo.png?"
    assert attachment_url =~ "X-Amz-Expires=900"
    assert attachment_url =~ "X-Amz-Signature=mock"
  end

  test "sign_urls strips stale media references from deleted messages" do
    Application.put_env(:open_chat, :media_storage, "s3")
    Application.put_env(:open_chat, :s3_bucket, "openchat-test-uploads")
    Application.put_env(:open_chat, :s3_client, OpenChat.MockS3)
    Application.put_env(:open_chat, :public_media_base_url, "https://openchat.example")

    signed =
      Media.sign_urls(%{
        "deletedAt" => 1_778_788_710,
        "data" => %{
          "text" => "deleted caption",
          "url" => "https://openchat.example/media/missing123-photo.png",
          "attachments" => [
            %{"url" => "https://openchat.example/media/missing123-photo.png"}
          ]
        }
      })

    assert signed["data"] == %{"text" => "deleted caption"}
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
