---
name: release
description: |
  Covers: Version bump workflow, GitHub tagging, release assets, checksum refresh, Hex publishing, and docs publishing.
  Consult when: Cutting a new cloaked_req release, bumping @version, or recovering a failed release.
  Not covered: Day-to-day development (see README.md), CI implementation details (see .github/workflows/*.yml).
---

# Release

`cloaked_req` releases have two parts:

1. GitHub release assets for the precompiled NIFs
2. Hex publication for the Elixir package and docs

## Quick Reference

| Step | Trigger | Output |
| --- | --- | --- |
| Bump `@version` in `mix.exs` | PR to `main` | Release candidate commit |
| Merge version bump to `main` | `tag-on-version-bump` | `vX.Y.Z` tag if version changed |
| Tag pushed | `release.yml` | GitHub release with NIF tarballs |
| Release published | `checksum.yml` | Updated `checksum-Elixir.CloakedReq.Native.exs` committed to `main` |
| Publish package | `mix hex.publish` | Hex package |
| Publish docs | `mix hex.publish docs` | HexDocs docs |

## Version Bump Rules

- Bump [mix.exs](mix.exs) `@version` only when that merge should create a release.
- Update [CHANGELOG.md](CHANGELOG.md) in the same PR.
- Keep [native/cloaked_req_native/Cargo.toml](native/cloaked_req_native/Cargo.toml) in sync with the release version when you want Rust metadata to match the Elixir package.
- No version change means no tag and no GitHub release.

## Automated GitHub Release

After the version-bump PR is merged to `main`:

1. `.github/workflows/tag-on-version-bump.yml` compares the current `mix.exs` version with `HEAD^`.
2. If the version changed and `vX.Y.Z` does not already exist, the workflow creates and pushes that tag.
3. The tag triggers `.github/workflows/release.yml`.
4. `release.yml` builds the precompiled NIF archives and publishes the GitHub release for `vX.Y.Z`.
5. The published release triggers `.github/workflows/checksum.yml`, which updates `checksum-Elixir.CloakedReq.Native.exs` on `main`.

## Exact Hex Release Steps

Run these steps only after the GitHub release for the same version exists, all NIF archives are attached, and the checksum update commit has landed on `main`.

### 1. Refresh local checkout after the checksum workflow commits back to `main`

```bash
jj git fetch
jj rebase -o main
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
mix hex.publish docs
```

## Gotchas

- Do not publish to Hex before the GitHub release exists. `RustlerPrecompiled` loads assets from the GitHub release URL derived from `@version`.
- Do not reuse versions. Hex versions are immutable.
- If the version bump merged but the GitHub release failed, fix the release workflow first. Do not publish Hex against missing or partial NIF assets.
- Do not publish from a tree that still has the previous version in `checksum-Elixir.CloakedReq.Native.exs`.
