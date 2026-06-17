defmodule CloakedReq.Pool do
  @moduledoc """
  Reference to a dedicated Rust-side HTTP client with its own connection pool.

  By default `CloakedReq` routes every request through a shared, bounded client
  cache: requests with the same impersonation profile, TLS verification, and
  connect timeout reuse one client and its connection pool. A `Pool` gives a
  caller its own isolated client instead — its connections, TLS session cache,
  and HTTP/2 multiplexing are never shared with any other identity. Build one
  per identity (per account, per proxy persona, per crawl) so a connection
  opened for one is never reused for another.

  The pool fixes the client at build time: when a request runs through a pool,
  the pool's client governs the impersonation profile, TLS verification, and
  connect timeout, so per-request `:impersonate`, `:insecure_skip_verify`, and
  the `:connect_options` connect timeout do not change the client (they are
  still validated if given, but ignored). Per-request proxy, source address,
  headers, body, cookie jar, and the receive timeout still apply. Each pool
  keeps up to 20 idle connections per host.

  The client is garbage-collected by the BEAM when the `Pool` struct is no
  longer referenced, so its idle connections close on their own — a worker that
  crashes without an explicit teardown cannot leak the pool. To rotate a pool's
  identity (for example after its upstream proxy exit changes), build a new pool
  and drop the old struct; the old client's connections close once it is
  unreferenced.

  ## Options

  - `:impersonate` - profile atom (e.g. `:chrome_136`); `nil` for none
  - `:insecure_skip_verify` - boolean, default `false`
  - `:connect_timeout` - socket connect timeout in milliseconds, default 30_000
  - `:pool_idle_timeout` - how long an idle connection is kept before it is
    closed, in milliseconds; `nil` (the default) uses wreq's own default

  ## Example

  Hold one pool per worker so every request that worker makes reuses its
  connections and presents one consistent identity:

      defmodule Scraper.Worker do
        use GenServer

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

        @impl true
        def init(opts) do
          pool = CloakedReq.Pool.new!(impersonate: Keyword.fetch!(opts, :profile))
          {:ok, %{pool: pool}}
        end

        @impl true
        def handle_call({:get, url}, _from, %{pool: pool} = state) do
          response =
            Req.new(url: url)
            |> CloakedReq.attach(pool: pool)
            |> Req.get!()

          {:reply, response, state}
        end
      end
  """

  alias CloakedReq.Error
  alias CloakedReq.Native
  alias CloakedReq.Request

  @default_connect_timeout 30_000

  @enforce_keys [:ref, :connect_timeout]
  defstruct [:ref, :connect_timeout]

  @type t :: %__MODULE__{ref: reference(), connect_timeout: pos_integer()}

  @doc """
  Builds a pool with its own connection pool, or returns `{:error, %CloakedReq.Error{}}`.

  ## Examples

      iex> {:ok, pool} = CloakedReq.Pool.new(impersonate: :chrome_136)
      iex> is_reference(pool.ref)
      true
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options \\ []) when is_list(options) do
    impersonate = Keyword.get(options, :impersonate)
    insecure_opt = Keyword.get(options, :insecure_skip_verify, false)
    connect_timeout_opt = Keyword.get(options, :connect_timeout, @default_connect_timeout)
    idle_opt = Keyword.get(options, :pool_idle_timeout)

    with {:ok, emulation} <- Request.normalize_impersonate(impersonate),
         {:ok, insecure_skip_verify} <- Request.normalize_insecure_skip_verify(insecure_opt),
         {:ok, connect_timeout} <- Request.normalize_connect_timeout(connect_timeout_opt, "connect_timeout"),
         {:ok, pool_idle_timeout} <- normalize_pool_idle_timeout(idle_opt),
         {:ok, ref} <-
           Native.new_pool(%{
             emulation: emulation,
             insecure_skip_verify: insecure_skip_verify,
             connect_timeout_ms: connect_timeout,
             pool_idle_timeout_ms: pool_idle_timeout
           }) do
      {:ok, %__MODULE__{ref: ref, connect_timeout: connect_timeout}}
    end
  end

  @doc """
  Builds a pool, raising `ArgumentError` on invalid options.

  ## Examples

      iex> pool = CloakedReq.Pool.new!(impersonate: :chrome_136)
      iex> %CloakedReq.Pool{} = pool
      iex> is_reference(pool.ref)
      true
  """
  @spec new!(keyword()) :: t()
  def new!(options \\ []) when is_list(options) do
    case new(options) do
      {:ok, pool} -> pool
      {:error, error} -> raise ArgumentError, Error.format(error)
    end
  end

  @spec normalize_pool_idle_timeout(term()) :: {:ok, nil | pos_integer()} | {:error, Error.t()}
  defp normalize_pool_idle_timeout(nil), do: {:ok, nil}
  defp normalize_pool_idle_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_pool_idle_timeout(_value) do
    {:error, Error.new(:invalid_request, "pool_idle_timeout must be a positive integer or nil")}
  end
end
