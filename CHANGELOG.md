# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## Unreleased

### Changed

- `release.yml` no longer writes and pushes `checksum-Elixir.CloakedReq.Native.exs`.
  `main` is protected. It needs signed commits and a pull request, thus the push
  always failed. The workflow now stops after the GitHub release. `RELEASE.md`
  gives the manual step, the same as the other NIF repositories.

## [0.6.0] - 28.08.2026

### Fixed

- Impersonated requests sent `user-agent: req/<version>`. The profile user-agent did not go on the wire. Req's `put_user_agent` step set the header, and a per-request header wins over the client defaults. Thus `req/<version>` went out next to the profile `sec-ch-ua`. A detector can find this pair. `attach/2` and `impersonate/2` now remove that default, and the profile sets the user-agent. An explicit `user-agent` header or `:user_agent` option still wins.
- Impersonated requests sent `accept-encoding: zstd,gzip,deflate,br`. This was not the profile value. The `wreq-util` build did not use the `emulation-compression` feature, so wreq set its own value and order. The feature is now on. Chrome now sends `gzip, deflate, br, zstd`, the same as the real browser, and the header is in the browser position. Responses still decode.

### Changed

- Require Req 0.7 (`~> 0.7`, was `~> 0.5 or ~> 0.6`). Req 0.7 makes function adapters obsolete. `attach/2` and `impersonate/2` now set `adapter: CloakedReq`. Change a check of `is_function(req.adapter, 1)` to `req.adapter == CloakedReq`. Req 0.5 and Req 0.6 cannot call a module adapter, thus they are not supported.
- Move the Rust NIF to the stable `wreq` line: `wreq` 6.0.0-rc.29 to 0.16.1, and `wreq-util` 3.0.0-rc.14 to 0.2.0. Upstream reset the version numbers on 2026-08-22. It is the same project with new numbers, but the jump also includes rc.30, rc.31 and the two 0.16 releases. The bullets below give the changes that you can see.
- Impersonation headers are different for each profile. There are still 133 profiles, and no profile was added or removed. The header set and the header order changed. Chrome now also sends `upgrade-insecure-requests: 1` and `sec-fetch-user: ?1`, and its `sec-fetch-*` block is now after `accept`. Firefox carries `te: trailers` on the profile. Opera has the `sec-fetch-*` group, and its `accept` changes `signed-exchange;v=b3` from `q=0.9` to `q=0.7`. Test again each profile that you tuned for a detector.
- Cookies: a host-only cookie no longer goes to subdomains. A host-only cookie has no `Domain` attribute. The old jar matched the suffix, thus a cookie for `example.com` also went to `sub.example.com`. A session that needs this now fails, and there is no error message.
- Cookies: `Max-Age` now expires a cookie. The old jar read only `Expires`, thus a live `Max-Age` cookie stayed forever.
- Cookies: the `cookie` header now has a stable order: longest path first, then creation order. The old jar used a hash map, thus the order changed between requests.
- Cookies: an `http://` origin can no longer set a `Secure` cookie or replace one. The old jar stored these cookies and filtered them only at send time.
- Range requests: a request with a `Range` header now sends `accept-encoding: identity`. This replaces your value.
- Errors: a DNS failure now gives `dns resolution error: ...` in the `:reason` field of `CloakedReq.AdapterError`. No Elixir code matches this text.
- The crate `rust-version` is now 1.98, because `wreq` 0.16 and `wreq-util` 0.2.0 need it. This applies only if you build the NIF from source with `CLOAKED_REQ_BUILD`. The precompiled NIFs do not change.
- Update the other Rust dependencies: `http` 1.4.2 to 1.5.0, `psl` 2.1.219 to 2.1.226, `lru` 0.18.1 to 0.18.3, `flate2` 1.1.9 to 1.1.10, and transitive patch releases. Update the Elixir dev tools: `styler`, `sobelow`, `ex_slop`.

## [0.5.1] - 27.06.2026

### Added

- `:chrome_149` impersonation profile, picked up from the `wreq-util` 3.0.0-rc.13 update.

### Changed

- Update the Rust NIF dependencies (`wreq-util` to 3.0.0-rc.13, plus `http` and `psl` patch releases) and refresh Elixir dependencies (`req` to 0.6.2 and the dev tooling) to latest. The `wreq-util` bump is additive: it adds the Chrome 149 profile and changes nothing for existing profiles.

## [0.5.0] - 27.06.2026

### Added

- `CloakedReq.Pool` (`new/1`, `new!/1`) and a `:pool` attach option for a dedicated, isolated client and connection pool. By default requests share a bounded client cache; a pool gives one caller its own client whose connections, TLS session cache, and HTTP/2 multiplexing are never shared with another identity. The pool fixes the fingerprint at build time (per-request `:impersonate` and `:insecure_skip_verify` are ignored when a pool is set), and the BEAM garbage-collects the client when the pool struct is no longer referenced, so a crashing worker cannot leak it. Proposed by @notmyactual in #32, with a reference implementation on their fork that informed this design.

## [0.4.2] - 11.06.2026

### Added

- Support Req 0.6: the version constraint is relaxed to `~> 0.5 or ~> 0.6`. Req 0.6's changes are confined to its request/response step pipeline (multipart escaping, decoder defaults, opt-in decompression), none of which touch the adapter contract; the full suite passes against Req 0.6.1.

### Fixed

- A malicious `Content-Length` response header can no longer abort the BEAM VM. The response buffer is no longer pre-allocated from the raw header value, which was only reachable under `max_body_size: :unlimited`.
- A crafted `Set-Cookie` `Domain` attribute containing a multibyte character no longer fails cookie-jar requests; the attribute is now parsed on a character boundary.
- A native request that never delivers a reply now returns a `:transport_error` after a deadline instead of blocking the calling process indefinitely.

### Changed

- The native client cache no longer grows without bound under proxy, source-IP, or connect-timeout rotation. Proxy and source IP are applied per request (wreq's connection pool already isolates connections by both), the remaining cache is LRU-bounded, and clients are built outside the cache lock.
- Request bodies are copied on the Tokio worker thread instead of the calling BEAM scheduler, keeping scheduler work constant for any body size.
- Update the Rust NIF to rustler 0.38 (a clean drop-in: no source or API changes, no new warnings).

### Documentation

- Document that `max_body_size` caps both the request and the response body.
- Update the install snippet to `~> 0.4.0` and regenerate the impersonation-profile list against `wreq-util 3.0.0-rc.12`.

## [0.4.0] - 23.05.2026

### Changed

- Run native HTTP requests asynchronously on the shared Tokio runtime instead of blocking DirtyIo NIF calls, improving high-concurrency throughput.
- Abort in-flight native requests when the BEAM caller exits before the response is delivered.

### Fixed

- Respect Req `connect_options` for proxy configuration, proxy headers, and connect timeout in the native `wreq` adapter.
- Reject unsupported `connect_options` with clear adapter errors instead of silently ignoring them.

## [0.3.2] - 07.03.2026

### Added

- Ship `usage-rules.md` with the Hex package so consumers and LLM tooling can discover the canonical adapter usage and options.

### Changed

- Add a `HexDocs` package link in Hex metadata and a docs link near the top of the README.
- Update dev dependencies: `credo`, `styler`, and `usage_rules`.

## [0.3.1] - 07.03.2026

### Fixed

- Redirect cookies are now stored against the actual response host, so cookie jars behave correctly across host-changing redirects.
- CI again tests the minimum advertised Elixir version (`~> 1.19`).

### Changed

- Releases are now tagged automatically when a version bump lands on `main`, and the release flow is documented in `RELEASE.md`.

## [0.3.0] - 24.02.2026

### Added

- `:local_address` option for outbound source IP binding (IPv4/IPv6 tuples and strings).
- Local address is included in the client cache key to prevent IP leakage through connection pooling.

## [0.2.0] - 23.02.2026

### Changed

- Upgraded NIF version to 2.17.

### Fixed

- Release workflow now creates GitHub releases on `workflow_dispatch` runs.
- Release tarball naming aligned with rustler_precompiled expectations.

## [0.1.0] - 20.02.2026

### Added

- Req adapter with `CloakedReq.attach/2` and `CloakedReq.impersonate/2`.
- Browser emulation wiring and structured response/error mapping.
- Cookie jar support (`CloakedReq.CookieJar`) with PSL-based domain validation.
- Client pooling with TLS session resumption and HTTP keep-alive.
- Configurable `max_body_size` option (default 10 MB).
- Explicit `:insecure_skip_verify` option (default `false`) for constrained external test environments.
