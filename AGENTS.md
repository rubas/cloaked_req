# cloaked_req

The README describes the adapter and its options. It ships on Hex with precompiled NIFs, so most users never build the
crate.

## Checks

- Tests tagged `:external` reach live third-party endpoints. The default run and CI exclude them. Run
  `task test:external` yourself before a release.
- `task test:zizmor` needs `zizmor` on `PATH`. CI installs its own copy.
- dprint formats Markdown, JSON, and TOML, but no check runs it. Run `dprint fmt` after you edit those files.

## Layout

- `native/cloaked_req_native/` holds the Rust crate, which does the network transport. The option rules stay in Elixir:
  `lib/cloaked_req/request.ex` validates the adapter options and sets the body-size, receive-timeout, and
  connect-timeout defaults.
- The native task replies on every path except an abort after the caller died, so `lib/cloaked_req/native.ex` waits for
  the reply with no timeout.
- `.github/workflows/release.yml` writes `checksum-Elixir.CloakedReq.Native.exs`. Never edit it by hand.

## Rules

- `Taskfile.yml` exports `CLOAKED_REQ_BUILD=true`, so every task builds the NIF from source. A bare `mix compile`
  downloads the precompiled NIF from the GitHub release and ignores your Rust changes.
- `mix format` runs Styler, which rewrites code. Read its diff.
- The crate sets `unsafe_code = "forbid"`.
- The package is LGPL-3.0-or-later. A new dependency must be compatible with it.

## Pitfalls

- A merge to `main` that bumps `@version` in `mix.exs` tags the version and builds the release assets. Bump it only in
  a release PR; [RELEASE.md](RELEASE.md) has the rest.
- `native/cloaked_req_native/Cargo.toml` has its own version. Move it with `@version`.
- A new build target goes into both the `targets:` list in `lib/cloaked_req/native.ex` and the build matrix in
  `.github/workflows/release.yml`. With only one of them, the release cannot load on that platform.
- The README promises glibc 2.34 for the Linux NIFs. The glibc check in `.github/workflows/release.yml` holds that
  floor, not the runner image (Ubuntu 22.04 ships glibc 2.35). The check fails when a NIF needs a newer glibc symbol or
  `GLIBC_ABI_DT_RELR`, so a newer runner image fails it.
- A `wreq-util` bump changes the impersonation profiles. Regenerate the list in the README from the crate's `Profile`
  enum.
