defmodule OpenChat.StorePaginationTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.Pagination

  test "page accepts atom or string params and clamps limits" do
    rows = Enum.to_list(1..20)

    assert Pagination.page(rows, %{per_page: "4", page: "2"}, 10, 50) == [5, 6, 7, 8]
    assert Pagination.page(rows, %{"limit" => "99"}, 10, 5) == [1, 2, 3, 4, 5]
    assert Pagination.page(rows, %{"limit" => "0"}, 10, 50) == [1]
    assert Pagination.page(rows, %{"limit" => "bad"}, 10, 50) == [1]
    assert Pagination.page(rows, %{"page" => "-3"}, 3, 50) == [1, 2, 3]
  end

  test "page_with_meta reports count total and total pages" do
    {rows, meta} =
      Pagination.page_with_meta(Enum.to_list(1..11), %{"limit" => "5", "page" => 3}, 10, 50)

    assert rows == [11]

    assert meta["pagination"] == %{
             "total" => 11,
             "count" => 1,
             "per_page" => 5,
             "current_page" => 3,
             "total_pages" => 3
           }

    assert meta["cursor"] == %{}
  end

  test "page_with_meta handles empty result sets without inventing a page" do
    assert {[], %{"pagination" => %{"total" => 0, "count" => 0, "total_pages" => 0}}} =
             Pagination.page_with_meta([], %{"limit" => 10}, 30, 100)
  end
end
