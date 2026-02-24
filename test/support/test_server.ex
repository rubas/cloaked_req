defmodule CloakedReq.TestServer do
  @moduledoc false

  @spec start(keyword()) :: {String.t(), pid()}
  def start(opts) when is_list(opts) do
    response = Keyword.fetch!(opts, :response)
    delay_ms = Keyword.get(opts, :delay_ms, 0)
    caller = self()

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        {:ok, {peer_ip, _peer_port}} = :inet.peername(socket)
        send(caller, {:test_server_peer, self(), peer_ip})
        request_data = read_request(socket)
        send(caller, {:test_server_request, self(), request_data})

        if delay_ms > 0, do: Process.sleep(delay_ms)

        _ = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)

    {"http://127.0.0.1:#{port}/", pid}
  end

  @spec get_request(pid(), timeout()) :: binary()
  def get_request(pid, timeout \\ 5_000) do
    receive do
      {:test_server_request, ^pid, data} -> data
    after
      timeout -> raise "TestServer: timed out waiting for captured request"
    end
  end

  @spec get_peer_address(pid(), timeout()) :: :inet.ip_address()
  def get_peer_address(pid, timeout \\ 5_000) do
    receive do
      {:test_server_peer, ^pid, ip} -> ip
    after
      timeout -> raise "TestServer: timed out waiting for peer address"
    end
  end

  @spec build_response(pos_integer(), [{String.t(), String.t()}], binary()) :: iodata()
  def build_response(status, headers, body) when is_integer(status) and is_list(headers) and is_binary(body) do
    reason = status_reason(status)

    all_headers = [
      {"content-length", Integer.to_string(byte_size(body))},
      {"connection", "close"}
      | headers
    ]

    header_lines =
      Enum.map_join(all_headers, "\r\n", fn {name, value} -> "#{name}: #{value}" end)

    ["HTTP/1.1 ", Integer.to_string(status), " ", reason, "\r\n", header_lines, "\r\n\r\n", body]
  end

  # --- Private helpers ---

  defp read_request(socket) do
    raw = read_until_headers_complete(socket, <<>>)

    case :binary.split(raw, "\r\n\r\n") do
      [headers_part, partial_body] ->
        content_length = parse_content_length(headers_part)
        remaining = content_length - byte_size(partial_body)

        if remaining > 0 do
          {:ok, rest} = :gen_tcp.recv(socket, remaining, 5_000)
          <<raw::binary, rest::binary>>
        else
          raw
        end

      [_headers_only] ->
        raw
    end
  end

  defp read_until_headers_complete(socket, acc) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
    data = <<acc::binary, chunk::binary>>

    if :binary.match(data, "\r\n\r\n") == :nomatch do
      read_until_headers_complete(socket, data)
    else
      data
    end
  end

  defp parse_content_length(headers_part) do
    headers_part
    |> :binary.split("\r\n", [:global])
    |> Enum.find_value(0, fn line ->
      case :binary.split(line, ":") do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length" do
            value |> String.trim() |> String.to_integer()
          end

        _ ->
          nil
      end
    end)
  end

  defp status_reason(200), do: "OK"
  defp status_reason(201), do: "Created"
  defp status_reason(302), do: "Found"
  defp status_reason(303), do: "See Other"
  defp status_reason(404), do: "Not Found"
  defp status_reason(500), do: "Internal Server Error"
  defp status_reason(_), do: "Unknown"
end
