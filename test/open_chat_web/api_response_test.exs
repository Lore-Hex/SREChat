defmodule OpenChatWeb.ApiResponseTest do
  use OpenChat.HttpCase, async: false

  alias OpenChatWeb.ApiResponse

  test "messages response preserves CometChat fetch-previous order and cursor metadata" do
    messages = [
      %{"id" => 1, "sentAt" => 100, "data" => %{}},
      %{"id" => 2, "sentAt" => 200, "data" => %{}}
    ]

    response = conn(:get, "/") |> ApiResponse.messages(messages, %{}) |> json()

    assert Enum.map(response["data"], & &1["id"]) == [2, 1]
    assert response["meta"]["cursor"] == %{"id" => 2, "sentAt" => 200, "affix" => "prepend"}

    append_response =
      conn(:get, "/")
      |> ApiResponse.messages(messages, %{"cursorAffix" => "append"})
      |> json()

    assert Enum.map(append_response["data"], & &1["id"]) == [1, 2]

    assert append_response["meta"]["cursor"] == %{
             "id" => 2,
             "sentAt" => 200,
             "affix" => "append"
           }
  end

  test "reactions response sorts and emits cursor metadata" do
    reactions = [
      %{"id" => 1, "reactedAt" => 100},
      %{"id" => 2, "reactedAt" => 200},
      %{"id" => 3, "reactedAt" => 300}
    ]

    response =
      conn(:get, "/")
      |> ApiResponse.reactions({:ok, reactions}, %{"limit" => "2"})
      |> json()

    assert Enum.map(response["data"], & &1["id"]) == [3, 2]
    assert response["meta"]["pagination"]["count"] == 2
    assert response["meta"]["previous"]["cursorField"] == "id"
    assert response["meta"]["previous"]["cursorValue"] == 2
    assert response["meta"]["previous"]["cursorId"] == 2
  end

  test "pagination meta keeps cursor-style optimistic totals" do
    assert ApiResponse.pagination_meta([], %{"page" => "3"}) == %{
             "pagination" => %{
               "total" => 0,
               "count" => 0,
               "per_page" => 30,
               "current_page" => 3,
               "total_pages" => 3
             }
           }

    assert get_in(ApiResponse.pagination_meta([1, 2], %{"limit" => "2"}), [
             "pagination",
             "total_pages"
           ]) == 2
  end
end
