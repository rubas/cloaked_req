# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [0.1.0] - 19.02.2026

### Added

- Adapter-first architecture around `Req` (`CloakedReq.attach/2`, `CloakedReq.impersonate/2`).
- Rustler native crate bridge (`native/cloaked_req_native`) using `wreq`.
- Browser emulation wiring and structured response/error mapping.
- Rust-side `catch_unwind` panic protection — NIF panics become `{:error, %CloakedReq.Error{type: :nif_panic}}` instead of crashing the BEAM.
- Elixir-side `ErlangError` rescue as second catch layer for Rustler's built-in panic wrapper.
- Explicit `:insecure_skip_verify` option (default `false`) for constrained external test environments.
- External JA4 smoke test against `https://tls.peet.ws/api/all`.
- Quality tooling and checks: formatter, Credo, Sobelow, dprint, and `Taskfile.yml`.
