# cloaked_req

`cloaked_req` is a Req adapter backed by Rust [`wreq`](https://docs.rs/wreq/latest/wreq/), focused on browser impersonation and performance.

## Goal

Keep Req ergonomics while swapping transport to Rust `wreq` for impersonation and fingerprint-sensitive requests.

## Installation

```elixir
def deps do
  [
    {:cloaked_req, "~> 0.3.0"}
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

| Option                  | Type                        | Default | Description                                  |
| ----------------------- | --------------------------- | ------- | -------------------------------------------- |
| `:impersonate`          | atom                        | `nil`   | Browser profile (e.g. `:chrome_136`)         |
| `:cookie_jar`           | `CookieJar.t()`             | `nil`   | Automatic cookie persistence across requests |
| `:insecure_skip_verify` | boolean                     | `false` | Skip TLS certificate verification            |
| `:max_body_size`        | pos_integer \| `:unlimited` | 10 MB   | Max response body size                       |

Req's `:receive_timeout` (default 15s) is also respected.

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

## Impersonation Profiles

Profiles based on `wreq-util 3.0.0-rc.10`.

### Chrome

`:chrome_100`, `:chrome_101`, `:chrome_104`, `:chrome_105`, `:chrome_106`, `:chrome_107`, `:chrome_108`, `:chrome_109`, `:chrome_110`, `:chrome_114`, `:chrome_116`, `:chrome_117`, `:chrome_118`, `:chrome_119`, `:chrome_120`, `:chrome_123`, `:chrome_124`, `:chrome_126`, `:chrome_127`, `:chrome_128`, `:chrome_129`, `:chrome_130`, `:chrome_131`, `:chrome_132`, `:chrome_133`, `:chrome_134`, `:chrome_135`, `:chrome_136`, `:chrome_137`, `:chrome_138`, `:chrome_139`, `:chrome_140`, `:chrome_141`, `:chrome_142`, `:chrome_143`, `:chrome_144`, `:chrome_145`

### Edge

`:edge_101`, `:edge_122`, `:edge_127`, `:edge_131`, `:edge_134`, `:edge_135`, `:edge_136`, `:edge_137`, `:edge_138`, `:edge_139`, `:edge_140`, `:edge_141`, `:edge_142`, `:edge_143`, `:edge_144`, `:edge_145`

### Opera

`:opera_116`, `:opera_117`, `:opera_118`, `:opera_119`

### Firefox

`:firefox_109`, `:firefox_117`, `:firefox_128`, `:firefox_133`, `:firefox_135`, `:firefox_private_135`, `:firefox_android_135`, `:firefox_136`, `:firefox_private_136`, `:firefox_139`, `:firefox_142`, `:firefox_143`, `:firefox_144`, `:firefox_145`, `:firefox_146`, `:firefox_147`

### Safari

`:safari_16`, `:safari_18`, `:safari_ipad_18`, `:safari_26`, `:safari_ipad_26`, `:safari_ios_26`

### OkHttp

`:okhttp_5`

## Limitations

- **No HTTP/3 / QUIC** — wreq supports HTTP/1.1 and HTTP/2 only. QUIC transport fingerprinting (JA4QUIC) is not available. If HTTP/3 fingerprinting is critical for your use case, consider a Go-based alternative like [surf](https://github.com/enetx/surf) which supports HTTP/3 with full QUIC fingerprinting — though it would require a different integration approach (sidecar/Port rather than NIF).

## Benchmark

50 sequential GET requests to a local HTTP server, 3 warmup rounds. Measures pure adapter overhead without network variance.

```bash
CLOAKED_REQ_BUILD=1 mix run bench/adapter_perf.exs
```

### Run 1

| Adapter               | min     | median  | mean    | p99     | max     |
| --------------------- | ------- | ------- | ------- | ------- | ------- |
| Req (Finch)           | 0.13 ms | 0.14 ms | 0.15 ms | 0.34 ms | 0.34 ms |
| CloakedReq (wreq NIF) | 0.05 ms | 0.06 ms | 0.07 ms | 0.17 ms | 0.17 ms |

CloakedReq median is 54.7 % faster than Req.

### Run 2

| Adapter               | min     | median  | mean    | p99     | max     |
| --------------------- | ------- | ------- | ------- | ------- | ------- |
| Req (Finch)           | 0.11 ms | 0.15 ms | 0.16 ms | 0.36 ms | 0.36 ms |
| CloakedReq (wreq NIF) | 0.07 ms | 0.08 ms | 0.09 ms | 0.24 ms | 0.24 ms |

CloakedReq median is 43.5 % faster than Req.

### Run 3

| Adapter               | min     | median  | mean    | p99     | max     |
| --------------------- | ------- | ------- | ------- | ------- | ------- |
| Req (Finch)           | 0.12 ms | 0.14 ms | 0.16 ms | 0.35 ms | 0.35 ms |
| CloakedReq (wreq NIF) | 0.07 ms | 0.09 ms | 0.09 ms | 0.25 ms | 0.25 ms |

CloakedReq median is 41.0 % faster than Req.
