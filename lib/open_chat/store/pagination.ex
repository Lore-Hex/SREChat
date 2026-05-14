defmodule OpenChat.Store.Pagination do
  @moduledoc false

  def page(rows, params, default_limit, max_limit) do
    params = stringify_keys(params)
    limit = limit(params, default_limit, max_limit)
    page = page_number(params)

    rows
    |> Enum.drop((page - 1) * limit)
    |> Enum.take(limit)
  end

  def page_with_meta(rows, params, default_limit, max_limit) do
    params = stringify_keys(params)
    limit = limit(params, default_limit, max_limit)
    page = page_number(params)
    total = length(rows)
    page_rows = rows |> Enum.drop((page - 1) * limit) |> Enum.take(limit)
    total_pages = if total == 0, do: 0, else: ceil(total / limit)

    meta = %{
      "pagination" => %{
        "total" => total,
        "count" => length(page_rows),
        "per_page" => limit,
        "current_page" => page,
        "total_pages" => total_pages
      },
      "cursor" => %{}
    }

    {page_rows, meta}
  end

  defp limit(params, default_limit, max_limit) do
    params["per_page"]
    |> Kernel.||(params["limit"])
    |> Kernel.||(default_limit)
    |> to_int()
    |> clamp(1, max_limit)
  end

  defp page_number(params), do: max(to_int(params["page"] || 1), 1)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_s(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp clamp(value, lo, hi), do: value |> Kernel.max(lo) |> Kernel.min(hi)

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(value), do: value |> to_s() |> to_int()
end
