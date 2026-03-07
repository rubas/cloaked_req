# Using CloakedReq

`CloakedReq` is a `Req` adapter backed by Rust `wreq`. Use it when you want to keep
`Req` ergonomics but send requests through `wreq` with browser impersonation support.

## Canonical Usage

Attach `CloakedReq` to a `Req.Request` before calling `Req.get!/1`, `Req.post!/1`,
or another `Req` request function.

```elixir
request =
  Req.new(url: "https://tls.peet.ws/api/all")
  |> CloakedReq.attach(impersonate: :chrome_136)

response = Req.get!(request)
```

You can also set the browser profile directly:

```elixir
request =
  Req.new(url: "https://example.com")
  |> CloakedReq.impersonate(:firefox_136)

response = Req.get!(request)
```

## Cookie Jar

Use `CloakedReq.CookieJar.new/0` when cookies should persist across multiple requests.

```elixir
jar = CloakedReq.CookieJar.new()

Req.new(url: "https://example.com/login")
|> CloakedReq.attach(impersonate: :chrome_136, cookie_jar: jar)
|> Req.post!(body: "user=admin&pass=secret")

Req.new(url: "https://example.com/dashboard")
|> CloakedReq.attach(impersonate: :chrome_136, cookie_jar: jar)
|> Req.get!()
```

## Adapter Options

Pass these options to `CloakedReq.attach/2`:

- `:impersonate` - browser profile atom like `:chrome_136`
- `:cookie_jar` - `%CloakedReq.CookieJar{}` for automatic cookie persistence
- `:insecure_skip_verify` - boolean to disable TLS certificate verification
- `:local_address` - outbound source IP as a string or IP tuple
- `:max_body_size` - positive integer byte limit or `:unlimited`

## Req Options Still Used

`CloakedReq` still reads the normal `Req.Request` values for:

- `url`
- `method`
- `headers`
- `body`
- `receive_timeout`

## Usage Notes

- `CloakedReq` is a `Req` adapter, not a standalone HTTP client.
- Streaming with `Req.Request.into` is not supported by this adapter.
- Request bodies must be binary or iodata.
