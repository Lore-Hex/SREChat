defmodule OpenChat.StoreMessageDataTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store.MessageData

  test "infer_type follows custom, upload, url, and text precedence" do
    assert MessageData.infer_type(%{"category" => "custom"}, []) == "custom"
    assert MessageData.infer_type(%{"category" => "custom", "type" => "poll"}, []) == "poll"
    assert MessageData.infer_type(%{"data" => ~s({"customData":{"kind":"poll"}})}, []) == "custom"
    assert MessageData.infer_type(%{"data" => %{"url" => "/media/a.png"}}, []) == "image"

    assert MessageData.infer_type(%{"data" => %{"url" => "https://cdn.example/a.gif"}}, []) ==
             "image"

    assert MessageData.infer_type(
             %{"data" => %{"url" => "https://cdn.example/a.gif?signature=123"}},
             []
           ) == "image"

    assert MessageData.infer_type(
             %{
               "data" => %{
                 "url" => "https://cdn.example/a",
                 "metadata" => %{"chatMessage" => %{"media" => %{"type" => "gif"}}}
               }
             },
             []
           ) == "image"

    assert MessageData.infer_type(%{"data" => %{"url" => "https://cdn.example/doc.pdf"}}, []) ==
             "file"

    assert MessageData.infer_type(%{"type" => "image"}, [%{}]) == "image"

    assert MessageData.infer_type(%{}, [
             %Plug.Upload{path: "/tmp/a", filename: "reaction.gif", content_type: "image/gif"}
           ]) == "image"

    assert MessageData.infer_type(%{"data" => %{"text" => "hi"}}, []) == "text"
  end

  test "normalise merges top-level compatibility fields without replacing explicit data" do
    assert {:ok, data} =
             MessageData.normalise(
               %{
                 "data" => %{
                   text: "from data",
                   metadata: %{existing: true}
                 },
                 "text" => "from top",
                 "caption" => "caption",
                 "metadata" => ~s({"from":"top"}),
                 "customData" => %{kind: "notice"}
               },
               []
             )

    assert data["text"] == "from data"
    assert data["metadata"] == %{"existing" => true}
    assert data["customData"] == %{"kind" => "notice"}
  end

  test "normalise uses caption and metadata aliases when data omits them" do
    assert {:ok, data} =
             MessageData.normalise(
               %{
                 "data" => %{},
                 "caption" => "photo caption",
                 "metadata" => ~s({"album":"summer"})
               },
               []
             )

    assert data == %{"text" => "photo caption", "metadata" => %{"album" => "summer"}}
  end

  test "normalise mirrors media captions and keeps attachment URL out of message text fields" do
    previous_upload_dir = Application.get_env(:open_chat, :upload_dir)
    upload_dir = Path.join(System.tmp_dir!(), "openchat-message-data-#{System.unique_integer()}")
    source = Path.join(System.tmp_dir!(), "openchat-source-#{System.unique_integer()}.png")

    File.write!(source, "hello")
    Application.put_env(:open_chat, :upload_dir, upload_dir)

    try do
      assert {:ok, data} =
               MessageData.normalise(
                 %{"data" => %{}, "caption" => "with upload"},
                 [
                   %Plug.Upload{
                     path: source,
                     filename: "photo.png",
                     content_type: "image/png"
                   }
                 ]
               )

      assert data["text"] == "with upload"
      assert data["caption"] == "with upload"
      assert [%{"url" => url}] = data["attachments"]
      refute Map.has_key?(data, "url")
      assert File.exists?(Path.join(upload_dir, Path.basename(url)))
    after
      if previous_upload_dir,
        do: Application.put_env(:open_chat, :upload_dir, previous_upload_dir),
        else: Application.delete_env(:open_chat, :upload_dir)

      File.rm_rf(upload_dir)
      File.rm(source)
    end
  end

  test "normalise persists uploads and returns stable attachment fields" do
    previous_upload_dir = Application.get_env(:open_chat, :upload_dir)
    upload_dir = Path.join(System.tmp_dir!(), "openchat-message-data-#{System.unique_integer()}")
    source = Path.join(System.tmp_dir!(), "openchat-source-#{System.unique_integer()}.txt")

    File.write!(source, "hello")
    Application.put_env(:open_chat, :upload_dir, upload_dir)

    try do
      assert {:ok, data} =
               MessageData.normalise(
                 %{"data" => %{}, "text" => "with upload"},
                 [
                   %Plug.Upload{
                     path: source,
                     filename: "../unsafe file.txt",
                     content_type: "text/plain; charset=utf-8"
                   }
                 ]
               )

      assert data["text"] == "with upload"

      assert [%{"name" => "unsafe_file.txt", "mimeType" => "text/plain"} = attachment] =
               data["attachments"]

      refute Map.has_key?(data, "url")
      assert data["caption"] == "with upload"
      assert File.exists?(Path.join(upload_dir, Path.basename(attachment["url"])))
    after
      if previous_upload_dir,
        do: Application.put_env(:open_chat, :upload_dir, previous_upload_dir),
        else: Application.delete_env(:open_chat, :upload_dir)

      File.rm_rf(upload_dir)
      File.rm(source)
    end
  end

  test "normalise returns upload validation errors" do
    assert {:error, %{"code" => "INVALID_FILE"}} =
             MessageData.normalise(%{"data" => %{}}, [%{"not" => "an upload"}])
  end

  test "merge accepts nested data wrappers, bare maps, and scalar no-ops" do
    old = %{"text" => "old", "metadata" => %{"a" => 1}}

    assert MessageData.merge(old, %{"data" => %{text: "new"}}) == %{
             "text" => "new",
             "metadata" => %{"a" => 1}
           }

    assert MessageData.merge(old, %{metadata: %{b: 2}}) == %{
             "text" => "old",
             "metadata" => %{"b" => 2}
           }

    assert MessageData.merge(old, "ignore") == old
  end

  test "put_entity adds and updates entity slots without dropping existing entries" do
    data =
      %{"entities" => %{"sender" => %{"entityType" => "user", "entity" => %{"uid" => "alice"}}}}
      |> MessageData.put_entity("receiver", "group", %{"guid" => "room"})
      |> MessageData.put_entity("sender", "user", %{"uid" => "bob"})

    assert data["entities"] == %{
             "sender" => %{"entityType" => "user", "entity" => %{"uid" => "bob"}},
             "receiver" => %{"entityType" => "group", "entity" => %{"guid" => "room"}}
           }
  end

  test "ensure_media_wire_shape restores attachment data from legacy URL media" do
    message =
      MessageData.ensure_media_wire_shape(%{
        "type" => "image",
        "data" => %{
          "url" => "https://cdn.example.com/media/photo.png",
          "metadata" => %{
            "chatMessage" => %{
              "media" => %{"name" => "photo.png", "type" => "image/png"}
            }
          }
        }
      })

    assert [%{"url" => "https://cdn.example.com/media/photo.png", "name" => "photo.png"}] =
             get_in(message, ["data", "attachments"])
  end

  test "ensure_media_wire_shape downgrades unrecoverable legacy media so SDK history cannot throw" do
    message =
      MessageData.ensure_media_wire_shape(%{
        "type" => "image",
        "data" => %{
          "metadata" => %{
            "chatMessage" => %{
              "message" => "",
              "media" => %{"name" => "missing.png", "type" => "image/png"}
            }
          }
        }
      })

    assert message["type"] == "text"
    assert get_in(message, ["data", "text"]) == "missing.png"
    refute Map.has_key?(message["data"], "attachments")
    refute Map.has_key?(message["data"], "url")
  end

  test "ensure_media_wire_shapes recursively sanitizes response envelopes" do
    body =
      MessageData.ensure_media_wire_shapes(%{
        "data" => [
          %{
            "type" => "image",
            "data" => %{
              "metadata" => %{
                "chatMessage" => %{
                  "media" => %{"name" => "missing.png", "type" => "image/png"}
                }
              }
            }
          }
        ]
      })

    [message] = body["data"]
    assert message["type"] == "text"
    assert get_in(message, ["data", "text"]) == "missing.png"
  end
end
