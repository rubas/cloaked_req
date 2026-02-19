# cloaked_req

`cloaked_req` is a Req adapter backed by Rust [`wreq`](https://docs.rs/wreq/latest/wreq/), focused on browser impersonation.

## Goal

Keep Req ergonomics while swapping transport to Rust `wreq` for impersonation and fingerprint-sensitive requests.

## Installation

```elixir
def deps do
  [
    {:cloaked_req, "~> 0.1.0"}
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

## Safety Model

- Input validation happens in Elixir before the NIF call.
- Native boundary uses explicit JSON contracts.
- Rust NIF panics are caught via `catch_unwind` and converted to `{:error, %CloakedReq.Error{type: :nif_panic}}` — the BEAM VM stays up.
- Rustler's built-in panic wrapper provides a second catch layer, rescued as `ErlangError` on the Elixir side.
- Native failures are returned to Req as `CloakedReq.AdapterError`.
- Network I/O runs via Rustler dirty scheduler NIF.
- TLS verification stays enabled by default. `:insecure_skip_verify` is opt-in.
