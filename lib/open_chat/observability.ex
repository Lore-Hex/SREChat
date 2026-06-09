defmodule OpenChat.Observability do
  @moduledoc false
  use GenServer

  @name __MODULE__
  @buckets_ms [10, 50, 100, 250, 500, 1_000, 2_500, 5_000]

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def reset! do
    if running?(), do: GenServer.call(@name, :reset), else: :ok
  end

  def snapshot do
    if running?(), do: GenServer.call(@name, :snapshot), else: empty_snapshot()
  end

  def increment(metric, tags \\ %{}, count \\ 1) do
    if running?(), do: GenServer.cast(@name, {:increment, to_s(metric), tags, count})
    :ok
  end

  def gauge(metric, value, tags \\ %{}) do
    if running?(), do: GenServer.cast(@name, {:gauge, to_s(metric), tags, value})
    :ok
  end

  def add_gauge(metric, delta, tags \\ %{}) do
    if running?(), do: GenServer.cast(@name, {:add_gauge, to_s(metric), tags, delta})
    :ok
  end

  def observe(metric, value, tags \\ %{}) do
    if running?(), do: GenServer.cast(@name, {:observe, to_s(metric), tags, to_number(value)})
    :ok
  end

  def duration_ms(start_native) do
    System.monotonic_time()
    |> Kernel.-(start_native)
    |> System.convert_time_unit(:native, :millisecond)
  end

  def record_http(method, path, status, duration_ms) do
    tags = %{
      "method" => to_s(method),
      "path" => path_template(path),
      "status" => status_class(status)
    }

    increment("http.requests", tags)
    observe("http.duration_ms", duration_ms, tags)
  end

  def record_store_call(request, mutating?, duration_ms, outcome, extra_tags \\ %{}) do
    tags =
      %{
        "request" => request,
        "mutating" => to_s(mutating?),
        "outcome" => outcome
      }
      |> Map.merge(stringify_tags(extra_tags))

    increment("store.calls", tags)
    observe("store.duration_ms", duration_ms, tags)
  end

  def record_api_error(method, path, status, error) do
    tags = %{
      "method" => to_s(method),
      "path" => path_template(path),
      "status" => status_class(status),
      "code" => error_code(error)
    }

    increment("http.errors", tags)
  end

  def record_auth_attempt(surface, outcome, token_present?) do
    increment("auth.attempts", %{
      "surface" => surface,
      "outcome" => outcome,
      "token_present" => to_s(token_present?)
    })
  end

  def record_redis_lock(scopes, outcome, wait_ms) do
    tags = %{
      "scopes" => lock_scope_label(scopes),
      "outcome" => outcome
    }

    increment("redis.lock.attempts", tags)
    observe("redis.lock.wait_ms", wait_ms, tags)
  end

  def record_ws(event, tags \\ %{}) do
    increment("ws.events", Map.put(stringify_tags(tags), "event", to_s(event)))
  end

  @impl true
  def init(_opts), do: {:ok, initial_state()}

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, initial_state()}

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_cast({:increment, metric, tags, count}, state) do
    {:noreply, update_in(state, [:counters], &increment_metric(&1, metric, tags, count))}
  end

  def handle_cast({:gauge, metric, tags, value}, state) do
    {:noreply, update_in(state, [:gauges], &Map.put(&1, metric_key(metric, tags), value))}
  end

  def handle_cast({:add_gauge, metric, tags, delta}, state) do
    key = metric_key(metric, tags)

    {:noreply,
     update_in(state, [:gauges], fn gauges ->
       Map.update(gauges, key, delta, &max(0, &1 + delta))
     end)}
  end

  def handle_cast({:observe, metric, tags, value}, state) do
    {:noreply, update_in(state, [:histograms], &observe_metric(&1, metric, tags, value))}
  end

  defp initial_state do
    %{
      started_at: DateTime.utc_now(),
      counters: %{},
      gauges: %{},
      histograms: %{}
    }
  end

  defp snapshot(state) do
    %{
      "service" => %{
        "name" => "openchat",
        "version" => OpenChat.Config.version(),
        "host" => OpenChat.Config.host(),
        "startedAt" => DateTime.to_iso8601(state.started_at),
        "uptimeSeconds" => DateTime.diff(DateTime.utc_now(), state.started_at, :second),
        "redisConfigured" => OpenChat.Store.RedisPersistence.configured?(),
        "redisEnabled" => OpenChat.Store.RedisPersistence.enabled?(),
        "redisBootMode" => OpenChat.Config.redis_boot_mode()
      },
      "counters" => sort_map(state.counters),
      "gauges" => sort_map(state.gauges),
      "histograms" => sort_map(state.histograms)
    }
  end

  defp empty_snapshot do
    %{
      "service" => %{"name" => "openchat", "version" => OpenChat.Config.version()},
      "counters" => %{},
      "gauges" => %{},
      "histograms" => %{}
    }
  end

  defp increment_metric(counters, metric, tags, count) do
    Map.update(counters, metric_key(metric, tags), count, &(&1 + count))
  end

  defp observe_metric(histograms, metric, tags, value) do
    Map.update(histograms, metric_key(metric, tags), new_histogram(value), &add_sample(&1, value))
  end

  defp new_histogram(value) do
    %{
      "count" => 1,
      "sum" => value,
      "min" => value,
      "max" => value,
      "buckets" => bucket_counts(value)
    }
  end

  defp add_sample(histogram, value) do
    histogram
    |> Map.update!("count", &(&1 + 1))
    |> Map.update!("sum", &(&1 + value))
    |> Map.update!("min", &min(&1, value))
    |> Map.update!("max", &max(&1, value))
    |> update_in(["buckets"], &merge_bucket_counts(&1, bucket_counts(value)))
  end

  defp bucket_counts(value) do
    bucket = Enum.find(@buckets_ms, &(value <= &1))
    key = if bucket, do: "<=#{bucket}", else: "+Inf"
    %{key => 1}
  end

  defp merge_bucket_counts(left, right) do
    Map.merge(left || %{}, right, fn _key, a, b -> a + b end)
  end

  defp metric_key(metric, tags) do
    tags = stringify_tags(tags)

    case Enum.sort(tags) do
      [] ->
        metric

      pairs ->
        suffix =
          pairs
          |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
          |> Enum.join(",")

        "#{metric}|#{suffix}"
    end
  end

  defp stringify_tags(tags) when is_map(tags) do
    Map.new(tags, fn {key, value} -> {to_s(key), tag_value(value)} end)
  end

  defp stringify_tags(_tags), do: %{}

  defp tag_value(value) when value in [nil, ""], do: "unknown"
  defp tag_value(value) when is_boolean(value), do: to_string(value)
  defp tag_value(value), do: value |> to_s() |> String.slice(0, 80)

  defp error_code(%{"code" => code}), do: tag_value(code)
  defp error_code(%{code: code}), do: tag_value(code)
  defp error_code(_error), do: "unknown"

  defp status_class(status) when is_integer(status), do: "#{div(status, 100)}xx"
  defp status_class(status), do: status |> to_s() |> status_class_from_string()
  defp status_class_from_string(<<digit::binary-size(1), _rest::binary>>), do: "#{digit}xx"
  defp status_class_from_string(_status), do: "unknown"

  defp path_template(path) do
    path
    |> to_s()
    |> String.split("?", parts: 2)
    |> List.first()
    |> String.split("/", trim: true)
    |> sanitize_segments()
    |> then(&("/" <> Enum.join(&1, "/")))
  end

  defp sanitize_segments(segments) do
    segments
    |> Enum.with_index()
    |> Enum.map(fn {segment, index} ->
      previous = if index > 0, do: Enum.at(segments, index - 1), else: nil

      cond do
        previous in ["users", "groups", "messages", "conversations", "members", "bannedusers"] ->
          ":id"

        id_like?(segment) ->
          ":id"

        true ->
          segment
      end
    end)
  end

  defp id_like?(segment) do
    String.match?(segment, ~r/^\d+$/) or
      (String.contains?(segment, "-") and String.length(segment) > 12)
  end

  defp lock_scope_label(scopes) do
    scopes
    |> List.wrap()
    |> Enum.map(fn
      :global -> "global"
      {scope, _id} -> to_s(scope)
      {scope, _id, _extra} -> to_s(scope)
      [scope | _rest] -> to_s(scope)
      other -> to_s(other)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join("+")
    |> case do
      "" -> "none"
      value -> value
    end
  end

  defp sort_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  defp running?, do: Process.whereis(@name) != nil

  defp to_number(value) when is_integer(value) or is_float(value), do: value

  defp to_number(value) do
    case Float.parse(to_s(value)) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value) when is_atom(value), do: Atom.to_string(value)
  defp to_s(value), do: to_string(value)
end
