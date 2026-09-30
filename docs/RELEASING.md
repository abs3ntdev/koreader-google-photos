# Releasing

## Workflows

- `.github/workflows/ci.yml` runs on pushes to `main`, `v*` tags, PRs to `main`, and manual dispatch.
  - `check`: Node 24, `npm ci --prefix service`, LuaJIT, then `make package` (which runs `make check`). Uploads the plugin zip as an artifact.
  - `docker-build` (PRs only, needs `check`): builds `service/` for `linux/amd64` with `contents: read` only. No login, no push, no package permissions.
  - `docker-publish` (non-PR only, needs `check`): the only job with `packages: write`. Pushes to `main` and tags publish `linux/amd64,linux/arm64` to `ghcr.io/abs3ntdev/koreader-google-photos`.
- `.github/workflows/release.yml` runs on `v*` tags: re-runs `make package`, writes `SHA256SUMS.txt`, and creates a GitHub release with `gh release create --verify-tag --generate-notes`. `v0.*` and `-suffixed` tags are marked prerelease. Notes flag the release as an MVP with live Google and device behaviour unverified.

Only `GITHUB_TOKEN` is used. No personal or Google credentials are stored in CI. PR workflows use `pull_request` (not `pull_request_target`) with read-only permissions.

## Image tags

| Event | Tags |
| --- | --- |
| push to `main` | `latest`, `edge`, `sha-<short>` |
| tag `vX.Y.Z` | `X.Y.Z`, `X.Y`, `sha-<short>` (`X.Y` only for non-prerelease) |

## Cutting a release

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

## GHCR visibility

The first push creates a private package. Make it public once: GitHub profile > Packages > `koreader-google-photos` > Package settings > Change visibility > Public. Also confirm the package is linked to this repository (the OCI source label set by `docker/metadata-action` normally does this).

## Updating pinned actions

Actions are pinned to full commit SHAs with the tag in a comment. Resolve a new SHA with `gh api repos/<owner>/<repo>/commits/<tag> -q .sha`.

`latest` tracks the default branch `main`, so Unraid users on `:latest` follow main. Pin `:0.1.0` for a fixed version. The image carries `org.opencontainers.image.source=https://github.com/abs3ntdev/koreader-google-photos` (set by `docker/metadata-action`), which links the GHCR package to the repository.
