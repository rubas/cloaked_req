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

| Step                         | Trigger       | Output                                  |
| ---------------------------- | ------------- | --------------------------------------- |
| Bump `@version` in `mix.exs` | PR to `main`  | Release candidate commit                |
| Merge version bump to `main` | `release.yml` | `vX.Y.Z` tag and GitHub release         |
| Refresh the checksum file    | PR to `main`  | `checksum-Elixir.CloakedReq.Native.exs` |
| Merge the checksum PR        | `release.yml` | Hex package and HexDocs docs            |

## Version Bump Rules

- Bump [mix.exs](mix.exs) `@version` only when that merge should create a release.
- Update [CHANGELOG.md](CHANGELOG.md) in the same PR.
- Set `version` in [native/cloaked_req_native/Cargo.toml](native/cloaked_req_native/Cargo.toml) to the new `@version`.
- Keep [README.md](README.md) current: the install snippet's `~> X.Y` constraint must cover `@version`, and when `wreq-util` is bumped, refresh the version reference and the impersonation-profile list against the new `Profile` enum.
- A version that already has a tag gets no new tag and no GitHub release.

## Automated GitHub Release

After the version-bump PR is merged to `main`:

1. `.github/workflows/release.yml` reads the `mix.exs` version and looks for the tag `vX.Y.Z`.
2. If the tag exists, the workflow stops.
3. The workflow builds the precompiled NIF archives. A build fails when its NIF needs a symbol that no library defines, because the BEAM could not load it.
4. When all builds pass, the workflow creates the tag and publishes the GitHub release for `vX.Y.Z`.
5. The workflow stops there. It does not touch `checksum-Elixir.CloakedReq.Native.exs`.

A failed build leaves no tag, so the version stays free. When the cause was outside the code, re-run the failed jobs.
After a fix in the code, the next push to `main` that changes `mix.exs` releases the same version.

`main` is a protected branch. It needs signed commits and a pull request. A
workflow cannot push to it. Thus you refresh the checksum file by hand, with a
pull request.

Use the workflow's manual dispatch only to re-run a release for the current version tag after fixing workflow issues. The dispatch builds the code at that tag and fails when the tag does not exist.

## Hex Release

Start only after the GitHub release for the same version exists, and all NIF archives are attached.

### 1. Refresh the checksum file

```bash
git fetch origin
git switch -c checksum-vX.Y.Z origin/main
task checksum:download
```

The task builds the NIF of the new `@version` from source first, because
`mix rustler_precompiled.download` reads the version and the targets from the
metadata of the last compile. The task keeps that metadata in `_build`, where a
compile in another checkout cannot change it. Then it downloads each asset from
the GitHub release, and verifies it. It fails when an asset is missing. Commit
the new `checksum-Elixir.CloakedReq.Native.exs`, and open a pull request.

### 2. Merge the checksum PR

The merge publishes. A push to `main` that changes the checksum file, for a
version that has its tag, starts the `Publish to Hex` job of
`.github/workflows/release.yml`. The job publishes the sources of the tag
`vX.Y.Z`, which the NIF archives were built from, with the checksum file of the
merge:

1. It compares the checksum file with the `SHA256SUMS` of the GitHub release, and stops when they differ.
2. It downloads the NIF of its runner, checks it against the checksum file, and loads it, as a consumer's build does.
3. It runs `mix hex.publish --yes`, which uploads the package and its docs, and fails when the log says `Publishing failed` or `Publishing docs failed`.

The job stores no Hex key. It runs in the GitHub environment `hex`, which only
`main` can use, and Hex exchanges the job's OIDC token for a token that can
only publish `cloaked_req`. For that, the package has a workload identity on
hex.pm, in its tab "Workload identities": repository owner `rubas`, repository
`cloaked_req`, workflow `release.yml`, environment `hex`. Only a full owner of
the package can add or change it.

The package has staged publishing on. Hex holds each release from the job, and
the job ends with `Package staged for approval at <url>`. A package owner
approves it on hex.pm with their 2FA, within 7 days. The job does not wait for
that approval: a GitHub job stops after 6 hours.

When the job fails for a cause outside the repo, such as hex.pm or the workload
identity, fix it and re-run the job. It publishes the same tag. A cause in the
tag needs a new patch version. A re-run keeps the workflow file of its run, so
after a fix of the job itself, release a new patch version, or a package owner
runs `mix hex.publish` from the tag with the checksum file of the merge.

## Gotchas

- Do not reuse versions. Hex versions are immutable.
- A change that merges between the version bump and the checksum PR ships only with the next version.
- If the version bump merged but the GitHub release failed, fix the release workflow first. Open no checksum PR against missing or partial NIF assets.
- The tag `vX.Y.Z` points at the version bump, so its checksum file is still the one of the release before. A git dependency on the tag needs `CLOAKED_REQ_BUILD=1`.
