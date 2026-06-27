# cloaked_req

`cloaked_req` is a Req adapter backed by Rust [`wreq`](https://docs.rs/wreq/latest/wreq/), focused on browser impersonation and performance.

Docs: <https://hexdocs.pm/cloaked_req>

## Goal

Keep Req ergonomics while swapping transport to Rust `wreq` for impersonation and fingerprint-sensitive requests.

## Installation

```elixir
def deps do
  [
    {:cloaked_req, "~> 0.5.0"}
  ]
end
```

## Usage

Use as a Req adapter:

```elixir
request =
  Req.new(url: "https://tls.peet.ws/api/all")
  |> CloakedReq.attach(impersonate: :chrome_136)

response = Req.get!(request)
```

Set impersonation later on an existing request:

```elixir
request =
  Req.new(url: "https://example.com")
  |> CloakedReq.impersonate(:firefox_136)
```

## Adapter Options

| Option                  | Type                        | Default | Description                                    |
| ----------------------- | --------------------------- | ------- | ---------------------------------------------- |
| `:impersonate`          | atom                        | `nil`   | Browser profile (e.g. `:chrome_136`)           |
| `:cookie_jar`           | `CookieJar.t()`             | `nil`   | Automatic cookie persistence across requests   |
| `:insecure_skip_verify` | boolean                     | `false` | Skip TLS certificate verification              |
| `:local_address`        | IP string or IP tuple       | `nil`   | Bind outbound requests to a specific source IP |
| `:max_body_size`        | pos_integer \| `:unlimited` | 10 MB   | Max request and response body size             |
| `:pool`                 | `Pool.t()`                  | `nil`   | Dedicated, isolated client and connection pool |

`:max_body_size` caps both directions: a request body larger than the limit is rejected before sending, and a response body is truncated to an error once it exceeds the limit. Req's `:receive_timeout` (default 15s) is also respected.

### Req Connect Options

`CloakedReq` respects these Req `:connect_options`:

- `:timeout` - socket connect timeout in milliseconds, default 30s
- `:proxy` - `{:http | :https, host, port, []}` proxy tuple
- `:proxy_headers` - proxy headers, commonly used for proxy authentication

Unsupported connection options fail with an adapter error instead of being silently ignored.

```elixir
Req.new(
  url: "https://example.com",
  connect_options: [
    timeout: 5_000,
    proxy: {:http, "proxy.example.com", 8888, []},
    proxy_headers: [{"proxy-authorization", "Basic " <> Base.encode64("user:pass")}]
  ]
)
|> CloakedReq.attach(impersonate: :chrome_136)
|> Req.get!()
```

```elixir
Req.new(url: "https://example.com")
|> CloakedReq.attach(local_address: {127, 0, 0, 1})
```

### Cookie Jar

Cookies are automatically stored from `set-cookie` response headers and sent with subsequent requests sharing the same jar. The jar uses PSL-based domain validation — it rejects cookies set on public suffixes and cross-origin domains.

```elixir
jar = CloakedReq.CookieJar.new()

# Login — server sets session cookie
Req.new(url: "https://example.com/login")
|> CloakedReq.attach(impersonate: :chrome_136, cookie_jar: jar)
|> Req.post!(body: "user=admin&pass=secret")

# Dashboard — session cookie sent automatically
Req.new(url: "https://example.com/dashboard")
|> CloakedReq.attach(impersonate: :chrome_136, cookie_jar: jar)
|> Req.get!()
```

### Connection pooling

By default every request goes through a shared, bounded client cache: requests with the same impersonation profile, TLS verification, and connect timeout reuse one client and its connection pool. That keeps connection reuse high for most callers without any setup.

For per-identity isolation, build a `CloakedReq.Pool`. A pool is a dedicated client with its own connections, TLS session cache, and HTTP/2 multiplexing, never shared with another identity. Build one per identity (per account, per proxy persona, per crawl) so a connection opened for one is never reused for another. Hold the pool in a worker's state and pass it to every request that worker makes.

```elixir
pool = CloakedReq.Pool.new!(impersonate: :chrome_136)

Req.new(url: "https://example.com")
|> CloakedReq.attach(pool: pool)
|> Req.get!()
```

The pool fixes the client at build time, so when a request runs through a pool, the pool's client governs the impersonation profile, TLS verification, and connect timeout; per-request `:impersonate`, `:insecure_skip_verify`, and the `:connect_options` connect timeout are ignored (still validated if given). Per-request proxy, source address, headers, body, cookie jar, and the receive timeout still apply. Each pool keeps up to 20 idle connections per host.

The client is garbage-collected by the BEAM when the pool struct is no longer referenced, so its idle connections close on their own. A worker that crashes without an explicit teardown cannot leak the pool. To rotate a pool's identity — for example after its upstream proxy exit changes — build a new pool and drop the old struct. Pass `:pool_idle_timeout` (milliseconds) to bound how long an idle connection is kept before it closes; the default uses wreq's own.

## Impersonation Profiles

Profiles based on `wreq-util 3.0.0-rc.13`. Profile atoms with a dot must be quoted, e.g. `:"safari_17.4.1"`.

### Chrome

`:chrome_100`, `:chrome_101`, `:chrome_104`, `:chrome_105`, `:chrome_106`, `:chrome_107`, `:chrome_108`, `:chrome_109`, `:chrome_110`, `:chrome_114`, `:chrome_116`, `:chrome_117`, `:chrome_118`, `:chrome_119`, `:chrome_120`, `:chrome_123`, `:chrome_124`, `:chrome_126`, `:chrome_127`, `:chrome_128`, `:chrome_129`, `:chrome_130`, `:chrome_131`, `:chrome_132`, `:chrome_133`, `:chrome_134`, `:chrome_135`, `:chrome_136`, `:chrome_137`, `:chrome_138`, `:chrome_139`, `:chrome_140`, `:chrome_141`, `:chrome_142`, `:chrome_143`, `:chrome_144`, `:chrome_145`, `:chrome_146`, `:chrome_147`, `:chrome_148`, `:chrome_149`

### Edge

`:edge_101`, `:edge_122`, `:edge_127`, `:edge_131`, `:edge_134`, `:edge_135`, `:edge_136`, `:edge_137`, `:edge_138`, `:edge_139`, `:edge_140`, `:edge_141`, `:edge_142`, `:edge_143`, `:edge_144`, `:edge_145`, `:edge_146`, `:edge_147`, `:edge_148`

### Opera

`:opera_116`, `:opera_117`, `:opera_118`, `:opera_119`, `:opera_120`, `:opera_121`, `:opera_122`, `:opera_123`, `:opera_124`, `:opera_125`, `:opera_126`, `:opera_127`, `:opera_128`, `:opera_129`, `:opera_130`, `:opera_131`

### Firefox

`:firefox_109`, `:firefox_117`, `:firefox_128`, `:firefox_133`, `:firefox_135`, `:firefox_private_135`, `:firefox_android_135`, `:firefox_136`, `:firefox_private_136`, `:firefox_139`, `:firefox_142`, `:firefox_143`, `:firefox_144`, `:firefox_145`, `:firefox_146`, `:firefox_147`, `:firefox_148`, `:firefox_149`, `:firefox_150`, `:firefox_151`

### Safari

`:"safari_15.3"`, `:"safari_15.5"`, `:"safari_15.6.1"`, `:safari_16`, `:"safari_16.5"`, `:"safari_17.0"`, `:"safari_17.2.1"`, `:"safari_17.4.1"`, `:"safari_17.5"`, `:"safari_17.6"`, `:safari_18`, `:"safari_18.2"`, `:"safari_18.3"`, `:"safari_18.3.1"`, `:"safari_18.5"`, `:safari_26`, `:"safari_26.1"`, `:"safari_26.2"`, `:"safari_26.3"`, `:"safari_26.4"`, `:safari_ipad_18`, `:"safari_ipad_26"`, `:"safari_ipad_26.2"`, `:"safari_ios_16.5"`, `:"safari_ios_17.2"`, `:"safari_ios_17.4.1"`, `:"safari_ios_18.1.1"`, `:safari_ios_26`, `:"safari_ios_26.2"`

### OkHttp

`:"okhttp_3.9"`, `:"okhttp_3.11"`, `:"okhttp_3.13"`, `:"okhttp_3.14"`, `:"okhttp_4.9"`, `:"okhttp_4.10"`, `:"okhttp_4.12"`, `:okhttp_5`

## Limitations

- **No HTTP/3 / QUIC** — wreq supports HTTP/1.1 and HTTP/2 only. QUIC transport fingerprinting (JA4QUIC) is not available. If HTTP/3 fingerprinting is critical for your use case, consider a Go-based alternative like [surf](https://github.com/enetx/surf) which supports HTTP/3 with full QUIC fingerprinting — though it would require a different integration approach (sidecar/Port rather than NIF).
