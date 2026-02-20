# Benchmark: Plain Req (Finch) vs CloakedReq (wreq NIF)
#
# Usage:
#   CLOAKED_REQ_BUILD=1 mix run bench/adapter_perf.exs
#   CLOAKED_REQ_BUILD=1 mix run bench/adapter_perf.exs https://example.com 100

defmodule Bench.Server do
  @moduledoc false

  @body Jason.encode!(%{
          url: "http://127.0.0.1/get",
          headers: %{
            "Accept" => "*/*",
            "Accept-Encoding" => "gzip, deflate, br",
            "Accept-Language" => "en-US,en;q=0.9",
            "Cache-Control" => "no-cache",
            "Connection" => "keep-alive",
            "Host" => "127.0.0.1",
            "Pragma" => "no-cache",
            "Sec-Fetch-Dest" => "empty",
            "Sec-Fetch-Mode" => "cors",
            "Sec-Fetch-Site" => "same-origin",
            "User-Agent" =>
              "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"
          },
          origin: "127.0.0.1"
        })

  @response [
    "HTTP/1.1 200 OK\r\n",
    "content-type: application/json\r\n",
    "content-length: #{byte_size(@body)}\r\n",
    "server: bench\r\n",
    "date: Thu, 01 Jan 2026 00:00:00 GMT\r\n",
    "access-control-allow-origin: *\r\n",
    "access-control-allow-credentials: true\r\n",
    "x-request-id: bench-00000000\r\n",
    "connection: close\r\n",
    "\r\n",
    @body
  ]

  @spec start() :: {non_neg_integer(), pid()}
  def start do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    {pid, ref} =
      spawn_monitor(fn ->
        accept_loop(listen)
      end)

    # Verify the server is alive before returning
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise "Bench.Server crashed on start: #{inspect(reason)}"
    after
      0 -> :ok
    end

    {port, pid}
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen, 1_000) do
      {:ok, socket} ->
        read_until_headers(socket, <<>>)
        _ = :gen_tcp.send(socket, @response)
        :gen_tcp.close(socket)
        accept_loop(listen)

      {:error, :timeout} ->
        accept_loop(listen)

      {:error, :closed} ->
        :ok
    end
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

      {:error, _} ->
        :ok
    end
  end
end

defmodule Bench.Stats do
  @moduledoc false

  @spec collect(pos_integer(), (-> :ok | {:error, term()})) :: [float()]
  def collect(n, fun) do
    1..n
    |> Enum.reduce([], fn _i, acc ->
      {us, _} = :timer.tc(fun)
      [us / 1_000 | acc]
    end)
    |> Enum.reverse()
  end

  @spec summary([float()]) :: map()
  def summary(timings) do
    sorted = Enum.sort(timings)
    len = length(sorted)

    %{
      min: List.first(sorted),
      max: List.last(sorted),
      mean: Enum.sum(sorted) / len,
      median: percentile(sorted, len, 50),
      p99: percentile(sorted, len, 99)
    }
  end

  @spec print(String.t(), map()) :: :ok
  def print(label, stats) do
    IO.puts("  #{label}")
    IO.puts("    min:    #{format(stats.min)}")
    IO.puts("    median: #{format(stats.median)}")
    IO.puts("    mean:   #{format(stats.mean)}")
    IO.puts("    p99:    #{format(stats.p99)}")
    IO.puts("    max:    #{format(stats.max)}")
  end

  defp percentile(sorted, len, p) do
    idx = max(0, ceil(len * p / 100) - 1)
    Enum.at(sorted, idx)
  end

  defp format(ms), do: :erlang.float_to_binary(ms, decimals: 2) <> " ms"
end

# -- Config ------------------------------------------------------------------

{url, count_str, local_server?} =
  case System.argv() do
    [] -> {nil, "50", true}
    [u] -> {u, "50", false}
    [u, c | _] -> {u, c, false}
  end

{url, server_pid} =
  if local_server? do
    {port, pid} = Bench.Server.start()
    {"http://127.0.0.1:#{port}/get", pid}
  else
    {url, nil}
  end

count = String.to_integer(count_str)
warmup = 3

IO.puts("Benchmark: Req (Finch) vs CloakedReq (wreq NIF)")
IO.puts("  url:        #{url}")
IO.puts("  iterations: #{count}")
IO.puts("  warmup:     #{warmup}")
IO.puts("")

# -- Scenarios ---------------------------------------------------------------

plain_req = fn -> Req.get!(url) end
cloaked_req = fn -> [url: url] |> Req.new() |> CloakedReq.attach(impersonate: :chrome_136) |> Req.request!() end

# -- Warmup ------------------------------------------------------------------

IO.write("Warming up Req (Finch)...")

for _ <- 1..warmup do
  plain_req.()
  IO.write(".")
end

IO.puts(" done")

IO.write("Warming up CloakedReq...")

for _ <- 1..warmup do
  cloaked_req.()
  IO.write(".")
end

IO.puts(" done")
IO.puts("")

# -- Timed runs --------------------------------------------------------------

IO.puts("Running #{count} sequential requests per adapter...")
IO.puts("")

req_timings = Bench.Stats.collect(count, plain_req)
req_stats = Bench.Stats.summary(req_timings)

cloaked_timings = Bench.Stats.collect(count, cloaked_req)
cloaked_stats = Bench.Stats.summary(cloaked_timings)

# -- Cleanup -----------------------------------------------------------------

if server_pid, do: Bench.Server.stop(server_pid)

# -- Results -----------------------------------------------------------------

IO.puts("Results:")
IO.puts("")
Bench.Stats.print("Req (Finch)", req_stats)
IO.puts("")
Bench.Stats.print("CloakedReq (wreq NIF)", cloaked_stats)
IO.puts("")

format_pct = fn frac -> :erlang.float_to_binary(frac * 100, decimals: 1) <> " %" end

ratio = cloaked_stats.median / req_stats.median

cond do
  ratio < 1.0 ->
    IO.puts("CloakedReq median is #{format_pct.(1.0 - ratio)} faster than Req")

  ratio > 1.0 ->
    IO.puts("CloakedReq median is #{format_pct.(ratio - 1.0)} slower than Req")

  true ->
    IO.puts("CloakedReq median is equal to Req")
end
