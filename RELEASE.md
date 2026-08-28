---
name: release
description: |
  Covers: Version bump workflow, GitHub tagging, release assets, checksum refresh, and Hex publishing.
  Consult when: Cutting a new cloaked_req release, bumping @version, or recovering a failed release.
  Not covered: Day-to-day development (see README.md), CI implementation details (see .github/workflows/*.yml).
---

# Release

`cloaked_req` releases have two parts:

1. GitHub release assets for the precompiled NIFs
2. Hex publication for the Elixir package, with docs published automatically

## Quick Reference

| Step                         | Trigger           | Output                                            |
| ---------------------------- | ----------------- | ------------------------------------------------- |
| Bump `@version` in `mix.exs` | PR to `main`      | Release candidate commit                          |
| Merge version bump to `main` | `release.yml`     | `vX.Y.Z` tag and GitHub release                   |
| Refresh the checksum file    | PR to `main`      | `checksum-Elixir.CloakedReq.Native.exs`           |
| Publish package              | `mix hex.publish` | Hex package and HexDocs docs                      |

## Version Bump Rules

- Bump [mix.exs](mix.exs) `@version` only when that merge should create a release.
- Update [CHANGELOG.md](CHANGELOG.md) in the same PR.
- Keep [native/cloaked_req_native/Cargo.toml](native/cloaked_req_native/Cargo.toml) in sync with the release version when you want Rust metadata to match the Elixir package.
- Keep [README.md](README.md) current: the install snippet's `~> X.Y` constraint must cover `@version`, and when `wreq-util` is bumped, refresh the version reference and the impersonation-profile list against the new `Profile` enum.
- No version change means no tag and no GitHub release.

## Automated GitHub Release

After the version-bump PR is merged to `main`:

1. `.github/workflows/release.yml` compares the current `mix.exs` version with `HEAD^`.
2. If the version changed, the workflow ensures `vX.Y.Z` exists.
3. The same workflow builds the precompiled NIF archives and publishes the GitHub release for `vX.Y.Z`.
4. The workflow stops there. It does not touch `checksum-Elixir.CloakedReq.Native.exs`.

`main` is a protected branch. It needs signed commits and a pull request. A
workflow cannot push to it. Thus you refresh the checksum file by hand, with a
pull request. The other NIF repositories do the same.

Use the workflow's manual dispatch only to re-run a release for the current version tag after fixing workflow issues.

## Exact Hex Release Steps

Run these steps only after the GitHub release for the same version exists, and all NIF archives are attached.

### 1. Refresh the checksum file and merge it to `main`

```bash
jj git fetch
jj new main@origin
mix rustler_precompiled.download CloakedReq.Native --all --no-config --ignore-unavailable --print
```

The task downloads each asset from the GitHub release and verifies it. Commit
the new `checksum-Elixir.CloakedReq.Native.exs`, open a pull request, and merge
it. Then move your checkout to the new `main`:

```bash
jj git fetch
jj new main@origin
```

### 2. Confirm the checksum file references the release you are about to publish

```bash
rg 'v0\\.3\\.1' checksum-Elixir.CloakedReq.Native.exs
```

Replace `0.3.1` with the version you are releasing. The checksum file must reference the same GitHub release assets as `@version`.

### 3. Verify the package from the exact publishing tree

```bash
mix hex.build
mix docs
```

### 4. Publish the package

```bash
mix hex.publish
```

## Gotchas

- Do not publish to Hex before the GitHub release exists. `RustlerPrecompiled` loads assets from the GitHub release URL derived from `@version`.
- Do not reuse versions. Hex versions are immutable.
- `mix hex.publish` publishes documentation automatically. Use `mix hex.publish package` only if you intentionally want to skip docs.
- If the version bump merged but the GitHub release failed, fix the release workflow first. Do not publish Hex against missing or partial NIF assets.
- Do not publish from a tree that still has the previous version in `checksum-Elixir.CloakedReq.Native.exs`.
