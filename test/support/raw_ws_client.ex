defmodule OpenChat.RawWsClient do
  @moduledoc """
  A deliberately dumb RFC 6455 client over :gen_tcp for transport-layer
  tests. The mocked handler tests can't answer questions like "does the
  server's heartbeat actually hold an idle connection open through
  cowboy's idle_timeout" — only a real socket can, and a real socket that
  we fully control (it sends NOTHING unless told to, exactly like a
  browser tab in the background).

  Auto-answers protocol pings with pongs, exactly as every browser's
  native WebSocket does — that part of the stack is not under test and
  cannot be disabled in a browser either.
  """

  @doc "The port the app's cowboy listener actually bound (not config)."
  def listener_port do
    :ranch.info()
    |> Enum.find_value(fn {_ref, info} -> info[:port] end)
  end

  def connect(port, path \\ "/ws") do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true], 5_000)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    handshake = [
      "GET #{path} HTTP/1.1\r\n",
      "Host: 127.0.0.1:#{port}\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Key: #{key}\r\n",
      "Sec-WebSocket-Version: 13\r\n",
      "Origin: http://localhost\r\n",
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, handshake)
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)

    if response =~ "101" do
      {:ok, socket}
    else
      {:error, {:handshake, response}}
    end
  end

  def send_text(socket, payload) do
    :gen_tcp.send(socket, frame(0x1, payload))
  end

  @doc """
  Sit on the socket for `duration_ms`, decoding frames. Auto-pongs pings.
  Returns `{:alive, events}` if the connection survived the whole window,
  `{:closed, events}` if the server closed it (close frame or TCP close).
  Events are `{ms_offset, kind}` tuples for diagnosing WHEN things happen.
  """
  def observe(socket, duration_ms) do
    started = System.monotonic_time(:millisecond)
    observe_loop(socket, started, duration_ms, <<>>, [])
  end

  defp observe_loop(socket, started, duration_ms, buffer, events) do
    elapsed = System.monotonic_time(:millisecond) - started
    remaining = duration_ms - elapsed

    if remaining <= 0 do
      {:alive, Enum.reverse(events)}
    else
      case :gen_tcp.recv(socket, 0, min(remaining, 1_000)) do
        {:ok, data} ->
          {frames, buffer} = decode_frames(buffer <> data)

          case handle_frames(socket, frames, elapsed, events) do
            {:closed, events} -> {:closed, Enum.reverse(events)}
            {:ok, events} -> observe_loop(socket, started, duration_ms, buffer, events)
          end

        {:error, :timeout} ->
          observe_loop(socket, started, duration_ms, buffer, events)

        {:error, :closed} ->
          {:closed, Enum.reverse([{elapsed, :tcp_closed} | events])}
      end
    end
  end

  defp handle_frames(_socket, [], _elapsed, events), do: {:ok, events}

  defp handle_frames(socket, [{opcode, payload} | rest], elapsed, events) do
    case opcode do
      0x9 ->
        # Ping: answer like a browser would.
        :gen_tcp.send(socket, frame(0xA, payload))
        handle_frames(socket, rest, elapsed, [{elapsed, :server_ping} | events])

      0x8 ->
        {:closed, [{elapsed, {:close_frame, close_code(payload)}} | events]}

      0x1 ->
        handle_frames(socket, rest, elapsed, [{elapsed, {:text, payload}} | events])

      _other ->
        handle_frames(socket, rest, elapsed, [{elapsed, {:frame, opcode}} | events])
    end
  end

  defp close_code(<<code::16, _rest::binary>>), do: code
  defp close_code(_payload), do: nil

  # Client frames must be masked (RFC 6455 §5.3).
  defp frame(opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    masked = mask_payload(payload, mask)
    length = byte_size(payload)

    header =
      cond do
        length < 126 -> <<1::1, 0::3, opcode::4, 1::1, length::7>>
        length < 65_536 -> <<1::1, 0::3, opcode::4, 1::1, 126::7, length::16>>
        true -> <<1::1, 0::3, opcode::4, 1::1, 127::7, length::64>>
      end

    [header, mask, masked]
  end

  defp mask_payload(payload, mask) do
    mask_stream = mask |> :binary.bin_to_list() |> Stream.cycle()

    payload
    |> :binary.bin_to_list()
    |> Enum.zip(mask_stream)
    |> Enum.map(fn {byte, m} -> Bitwise.bxor(byte, m) end)
    |> :binary.list_to_bin()
  end

  defp decode_frames(buffer, frames \\ [])

  defp decode_frames(<<_fin::1, _rsv::3, opcode::4, 0::1, len::7, rest::binary>> = buffer, frames) do
    case extended_length(len, rest) do
      {:ok, length, payload_and_rest} when byte_size(payload_and_rest) >= length ->
        <<payload::binary-size(^length), remaining::binary>> = payload_and_rest
        decode_frames(remaining, [{opcode, payload} | frames])

      _incomplete ->
        {Enum.reverse(frames), buffer}
    end
  end

  defp decode_frames(buffer, frames), do: {Enum.reverse(frames), buffer}

  defp extended_length(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp extended_length(127, <<length::64, rest::binary>>), do: {:ok, length, rest}
  defp extended_length(len, rest) when len < 126, do: {:ok, len, rest}
  defp extended_length(_len, _rest), do: :incomplete
end
