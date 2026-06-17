# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## Unreleased

## [0.5.0] - 27.06.2026

### Added

- `CloakedReq.Pool` (`new/1`, `new!/1`) and a `:pool` attach option for a dedicated, isolated client and connection pool. By default requests share a bounded client cache; a pool gives one caller its own client whose connections, TLS session cache, and HTTP/2 multiplexing are never shared with another identity. The pool fixes the fingerprint at build time (per-request `:impersonate` and `:insecure_skip_verify` are ignored when a pool is set), and the BEAM garbage-collects the client when the pool struct is no longer referenced, so a crashing worker cannot leak it. Requested in #32 by @notmyactual.

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
