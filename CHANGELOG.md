# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

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
