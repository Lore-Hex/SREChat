defmodule SREChat.Time do
  @moduledoc false
  def now, do: System.system_time(:second)
  def now_ms, do: System.system_time(:millisecond)
end
