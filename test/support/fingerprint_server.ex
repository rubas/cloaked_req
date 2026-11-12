defmodule CloakedReq.FingerprintServer do
  @moduledoc false

  # Local stand-ins for a fingerprint echo site. `start_h2/0` serves HTTP/2
  # over TLS and reports each request with the HTTP/2 fingerprint of its
  # connection. `client_hello/1` reads the TLS ClientHello a request opens with.
  #
  # HPAX decodes the request headers. It is Mint's HPACK library and comes with
  # Req, so this module needs no dependency of its own.

  import Bitwise

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  @settings 4
  @headers 1
  @window_update 8

  @type h2_request :: %{
          connection: pid(),
          headers: [{String.t(), String.t()}],
          settings: [{non_neg_integer(), non_neg_integer()}],
          window_update: non_neg_integer() | nil,
          priority: {boolean(), non_neg_integer(), non_neg_integer()} | nil
        }

  @doc """
  Starts the HTTP/2 server. It answers every request with an empty 200 and
  sends the caller `{:h2_request, request}`.
  """
  @spec start_h2() :: String.t()
  def start_h2 do
    caller = self()
    tls = :public_key.pkix_test_data(chain())

    {:ok, listen} =
      :ssl.listen(
        0,
        [mode: :binary, active: false, reuseaddr: true, alpn_preferred_protocols: ["h2"]] ++ tls
      )

    {:ok, {_ip, port}} = :ssl.sockname(listen)
    spawn_link(fn -> accept_h2(listen, caller) end)

    "https://127.0.0.1:#{port}/"
  end

  @spec next_h2_request(timeout()) :: h2_request()
  def next_h2_request(timeout \\ 5_000) do
    receive do
      {:h2_request, request} -> request
    after
      timeout -> raise "FingerprintServer: no HTTP/2 request arrived"
    end
  end

  @doc """
  Returns the parts of the TLS ClientHello that make up the profile's TLS
  fingerprint, without the values a client randomizes on every connection
  (GREASE, the extension order, and key material). `send_request` gets the
  `https` URL to open.
  """
  @spec client_hello((String.t() -> term())) :: map()
  def client_hello(send_request) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    task = Task.async(fn -> read_client_hello(listen) end)

    send_request.("https://127.0.0.1:#{port}/")

    task |> Task.await() |> parse_client_hello()
  end

  # --- HTTP/2 ---

  # The default test certificate is not one a Chrome profile accepts.
  defp chain do
    options = [digest: :sha256, key: {:namedCurve, :secp256r1}]
    %{root: options, peer: options}
  end

  defp accept_h2(listen, caller) do
    {:ok, socket} = :ssl.transport_accept(listen)
    connection = spawn_link(fn -> serve_h2(caller) end)
    :ok = :ssl.controlling_process(socket, connection)
    send(connection, {:socket, socket})
    accept_h2(listen, caller)
  end

  defp serve_h2(caller) do
    socket =
      receive do
        {:socket, socket} -> socket
      end

    {:ok, socket} = :ssl.handshake(socket, 5_000)
    {:ok, @preface} = :ssl.recv(socket, byte_size(@preface), 5_000)
    :ok = :ssl.send(socket, frame(@settings, 0, 0, <<>>))

    state = %{caller: caller, hpack: HPAX.new(4096), settings: [], window_update: nil}
    h2_loop(socket, state)
  end

  defp h2_loop(socket, state) do
    case :ssl.recv(socket, 9, 30_000) do
      {:ok, <<length::24, type, flags, _reserved::1, stream::31>>} ->
        {:ok, payload} = if length == 0, do: {:ok, <<>>}, else: :ssl.recv(socket, length, 5_000)
        h2_loop(socket, handle_frame(socket, state, type, flags, stream, payload))

      {:error, _closed} ->
        :ok
    end
  end

  defp handle_frame(socket, state, @settings, flags, 0, payload) when (flags &&& 0x1) == 0 do
    :ok = :ssl.send(socket, frame(@settings, 0x1, 0, <<>>))
    %{state | settings: for(<<id::16, value::32 <- payload>>, do: {id, value})}
  end

  defp handle_frame(_socket, state, @window_update, _flags, 0, <<_reserved::1, increment::31>>) do
    %{state | window_update: increment}
  end

  defp handle_frame(socket, state, @headers, flags, stream, payload) do
    # A request with more headers than one frame holds would need CONTINUATION.
    true = (flags &&& 0x4) != 0
    {priority, block} = split_priority(flags, payload)
    {:ok, headers, hpack} = HPAX.decode(block, state.hpack)

    send(
      state.caller,
      {:h2_request,
       %{
         connection: self(),
         headers: headers,
         settings: state.settings,
         window_update: state.window_update,
         priority: priority
       }}
    )

    # END_STREAM and END_HEADERS, with `:status: 200` from the static table.
    :ok = :ssl.send(socket, frame(@headers, 0x5, stream, <<0x88>>))
    %{state | hpack: hpack}
  end

  defp handle_frame(_socket, state, _type, _flags, _stream, _payload), do: state

  defp split_priority(flags, <<exclusive::1, dependency::31, weight, block::binary>>) when (flags &&& 0x20) != 0 do
    {{exclusive == 1, dependency, weight}, block}
  end

  defp split_priority(_flags, block), do: {nil, block}

  defp frame(type, flags, stream, payload) do
    <<byte_size(payload)::24, type, flags, 0::1, stream::31, payload::binary>>
  end

  # --- TLS ClientHello ---

  defp read_client_hello(listen) do
    {:ok, socket} = :gen_tcp.accept(listen, 5_000)
    {:ok, <<22, _version::16, length::16>>} = :gen_tcp.recv(socket, 5, 5_000)
    {:ok, handshake} = :gen_tcp.recv(socket, length, 5_000)
    :gen_tcp.close(socket)
    :gen_tcp.close(listen)
    handshake
  end

  defp parse_client_hello(
         <<1, _length::24, _version::16, _random::binary-32, session_id_length,
           _session_id::binary-size(session_id_length), ciphers_length::16, ciphers::binary-size(ciphers_length),
           compression_length, _compression::binary-size(compression_length), extensions_length::16,
           extensions::binary-size(extensions_length)>>
       ) do
    extensions = for <<type::16, length::16, data::binary-size(length) <- extensions>>, do: {type, data}

    %{
      ciphers: ciphers |> u16_list() |> reject_grease(),
      extensions: extensions |> Enum.map(&elem(&1, 0)) |> reject_grease() |> Enum.sort(),
      groups: extensions |> u16_vector(10) |> reject_grease(),
      signature_algorithms: u16_vector(extensions, 13),
      alpn: alpn(extensions),
      versions: extensions |> supported_versions() |> reject_grease(),
      key_shares: extensions |> key_shares() |> reject_grease()
    }
  end

  defp u16_list(binary), do: for(<<value::16 <- binary>>, do: value)

  defp u16_vector(extensions, type) do
    {^type, <<length::16, list::binary-size(length)>>} = List.keyfind(extensions, type, 0)
    u16_list(list)
  end

  defp alpn(extensions) do
    {16, <<length::16, list::binary-size(length)>>} = List.keyfind(extensions, 16, 0)
    for <<size, protocol::binary-size(size) <- list>>, do: protocol
  end

  defp supported_versions(extensions) do
    {43, <<length, list::binary-size(length)>>} = List.keyfind(extensions, 43, 0)
    u16_list(list)
  end

  defp key_shares(extensions) do
    {51, <<length::16, list::binary-size(length)>>} = List.keyfind(extensions, 51, 0)
    for <<group::16, size::16, _key::binary-size(size) <- list>>, do: group
  end

  # RFC 8701: a GREASE value is 0x0A0A, 0x1A1A, and so on up to 0xFAFA.
  defp reject_grease(values) do
    Enum.reject(values, fn value -> (value &&& 0x0F0F) == 0x0A0A and value >>> 8 == (value &&& 0xFF) end)
  end
end
