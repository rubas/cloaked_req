# cloaked_req

## Goal

A `Req` adapter that sends every request through a Rust NIF around
[`wreq`](https://docs.rs/wreq), so callers keep `Req` ergonomics and gain browser TLS and HTTP/2
impersonation. Shipped on Hex with precompiled NIFs, so most users never build the crate.

## Gates

`task check` is the full gate: `task test` (`mix format` and `cargo fmt` checks, `credo --strict`,
clippy, dialyzer, ExUnit, `cargo test`) plus `task security` (`mix deps.audit`, sobelow). CI runs
the same checks.

- Tests tagged `:external` reach live third-party endpoints and are excluded by default. CI never
  runs them. Run `task test:external` yourself before a release.
- `task test:zizmor` needs the `zizmor` binary on PATH. CI installs its own copy.
- dprint formats Markdown, JSON, and TOML. No gate checks it, so run `dprint fmt` after you edit
  those files.

## Layout

- `native/cloaked_req_native/` holds the Rust crate. It performs the network transport. The option
  rules stay in Elixir: `lib/cloaked_req/request.ex` validates the adapter options and sets the
  body-size, receive-timeout, and connect-timeout defaults. The native task replies on every path
  except an abort after the caller died, so `lib/cloaked_req/native.ex` waits for the reply with no
  timeout.
- `checksum-Elixir.CloakedReq.Native.exs` is written by `.github/workflows/release.yml`. Never edit
  it by hand.
- `test/support/test_server.ex` is the local HTTP server the unit tests hit.
- `bench/*.exs` run as `CLOAKED_REQ_BUILD=1 mix run bench/adapter_perf.exs`.
- [RELEASE.md](RELEASE.md) is the release and Hex publishing runbook.

## House decisions

- `Taskfile.yml` exports `CLOAKED_REQ_BUILD=true`, so every task builds the NIF from source. A bare
  `mix compile` downloads the precompiled NIF from the GitHub release instead and ignores your Rust
  changes.
- `mix format` runs the Styler plugin, which rewrites code. Read the diff it produces.
- Credo runs `.credo.exs`, which adds the ExSlop check set on top of the defaults.
- The crate sets `unsafe_code = "forbid"`.
- The package is LGPL-3.0-or-later. A new dependency has to be compatible with it.

## Pitfalls

- Bumping `@version` in `mix.exs` and merging to `main` tags the version and builds the release
  assets. Bump it only in a release PR; [RELEASE.md](RELEASE.md) has the rest.
- A new build target needs the same entry in the `targets:` list of `lib/cloaked_req/native.ex` and
  in the build matrix of `.github/workflows/release.yml`. One without the other publishes a release
  that cannot load on that platform.
- README promises glibc 2.34 for the Linux NIFs. The glibc check in `.github/workflows/release.yml`
  holds that floor, not the runner image: Ubuntu 22.04 ships glibc 2.35. The check fails the release
  when a NIF requires a glibc version newer than 2.34 or `GLIBC_ABI_DT_RELR`. A newer runner links
  newer glibc versions and fails the check.
- Bumping `wreq-util` changes the set of impersonation profiles. Regenerate the profile list in
  README.md from the crate's `Profile` enum.
- `native/cloaked_req_native/Cargo.toml` keeps its own version. Move it with `@version`.
