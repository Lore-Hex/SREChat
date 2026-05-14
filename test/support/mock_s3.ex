defmodule OpenChat.MockS3 do
  @moduledoc false

  @table :open_chat_mock_s3

  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ok
  end

  def put_object(bucket, key, path, content_type) do
    ensure_table()

    with {:ok, body} <- File.read(path) do
      :ets.insert(@table, {{bucket, key}, %{body: body, content_type: content_type}})
      {:ok, %{bucket: bucket, key: key}}
    end
  end

  def get_object(bucket, key) do
    ensure_table()

    case :ets.lookup(@table, {bucket, key}) do
      [{{^bucket, ^key}, object}] -> {:ok, object}
      [] -> {:error, :not_found}
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _table -> @table
    end
  end
end
