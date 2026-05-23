# Benchmark high-concurrency request throughput against a delayed local server.
#
# Usage:
#   CLOAKED_REQ_BUILD=1 mix run bench/concurrent_throughput.exs
#   CLOAKED_REQ_BUILD=1 mix run bench/concurrent_throughput.exs 500 100 50
#
# Args:
#   total_requests max_concurrency response_delay_ms

defmodule Bench.ConcurrentServer do
  @moduledoc false

  @body "ok"
  @response [
    "HTTP/1.1 200 OK\r\n",
    "content-type: text/plain\r\n",
    "content-length: #{byte_size(@body)}\r\n",
    "connection: close\r\n",
    "\r\n",
    @body
  ]

  @spec start(non_neg_integer()) :: {non_neg_integer(), pid()}
  def start(delay_ms) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        backlog: 4096
      ])

    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> accept_loop(listen, delay_ms) end)
    {port, pid}
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp accept_loop(listen, delay_ms) do
    case :gen_tcp.accept(listen, 1_000) do
      {:ok, socket} ->
        spawn(fn -> handle(socket, delay_ms) end)
        accept_loop(listen, delay_ms)

      {:error, :timeout} ->
        accept_loop(listen, delay_ms)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle(socket, delay_ms) do
    read_until_headers(socket, <<>>)
    Process.sleep(delay_ms)
    _ = :gen_tcp.send(socket, @response)
    :gen_tcp.close(socket)
  end

  defp read_until_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} ->
        data = <<acc::binary, chunk::binary>>

        if :binary.match(data, "\r\n\r\n") == :nomatch do
          read_until_headers(socket, data)
        else
          :ok
        end

      {:error, _reason} ->
        :ok
    end
  end
end

defmodule Bench.Concurrent do
  @moduledoc false

  @spec run(String.t(), pos_integer(), pos_integer(), (-> term())) :: map()
  def run(label, total, concurrency, fun) do
    started_at = System.monotonic_time()

    completed =
      1..total
      |> Task.async_stream(
        fn _i ->
          fun.()
          :ok
        end,
        max_concurrency: concurrency,
        timeout: 60_000
      )
      |> Enum.count(&match?({:ok, :ok}, &1))

    elapsed_ms =
      System.monotonic_time()
      |> Kernel.-(started_at)
      |> System.convert_time_unit(:native, :millisecond)

    rps = completed / max(elapsed_ms, 1) * 1_000

    %{
      label: label,
      completed: completed,
      elapsed_ms: elapsed_ms,
      rps: rps
    }
  end

  @spec print(map()) :: :ok
  def print(stats) do
    IO.puts("  #{stats.label}")
    IO.puts("    completed: #{stats.completed}")
    IO.puts("    elapsed:   #{stats.elapsed_ms} ms")
    IO.puts("    rate:      #{:erlang.float_to_binary(stats.rps, decimals: 1)} req/s")
  end
end

{total, concurrency, delay_ms} =
  case System.argv() do
    [] -> {300, 100, 50}
    [total] -> {String.to_integer(total), 100, 50}
    [total, concurrency] -> {String.to_integer(total), String.to_integer(concurrency), 50}
    [total, concurrency, delay_ms | _] -> {String.to_integer(total), String.to_integer(concurrency), String.to_integer(delay_ms)}
  end

{port, server_pid} = Bench.ConcurrentServer.start(delay_ms)
url = "http://127.0.0.1:#{port}/throughput"

IO.puts("Concurrent throughput benchmark")
IO.puts("  url:         #{url}")
IO.puts("  requests:    #{total}")
IO.puts("  concurrency: #{concurrency}")
IO.puts("  delay:       #{delay_ms} ms")
IO.puts("")

plain_req = fn -> Req.get!(url, retry: false) end
cloaked_req = fn -> [url: url, retry: false] |> Req.new() |> CloakedReq.attach(impersonate: :chrome_136) |> Req.request!() end

plain_req.()
cloaked_req.()

req_stats = Bench.Concurrent.run("Req (Finch)", total, concurrency, plain_req)
cloaked_stats = Bench.Concurrent.run("CloakedReq (wreq NIF)", total, concurrency, cloaked_req)

Bench.ConcurrentServer.stop(server_pid)

IO.puts("Results:")
IO.puts("")
Bench.Concurrent.print(req_stats)
IO.puts("")
Bench.Concurrent.print(cloaked_stats)
IO.puts("")

ratio = cloaked_stats.rps / req_stats.rps

cond do
  ratio > 1.0 ->
    IO.puts("CloakedReq throughput is #{:erlang.float_to_binary((ratio - 1.0) * 100, decimals: 1)} % higher than Req")

  ratio < 1.0 ->
    IO.puts("CloakedReq throughput is #{:erlang.float_to_binary((1.0 - ratio) * 100, decimals: 1)} % lower than Req")

  true ->
    IO.puts("CloakedReq throughput is equal to Req")
end
