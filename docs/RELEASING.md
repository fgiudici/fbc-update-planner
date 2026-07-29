# Releasing

This document describes how to create a new release of `plcc2fbc`.

## Prerequisites

- Push access to the repository
- Permission to create tags

## Release workflow

### 1. Bump the version

Update the `VERSION` file at the repository root:

```sh
echo "X.Y.Z" > VERSION
```

### 2. Update the Dockerfile

Update the default `VERSION` ARG in the `Dockerfile` to match:

```dockerfile
ARG VERSION=X.Y.Z
```

This keeps local Docker builds (without `--build-arg`) in sync with the release.

### 3. Commit the version bump

```sh
git add VERSION Dockerfile
git commit -m "release: vX.Y.Z"
```

### 4. Tag the release

```sh
git tag vX.Y.Z
```

### 5. Push

```sh
git push origin main --tags
```

Pushing the tag triggers the **Release** GitHub Actions workflow
(`.github/workflows/release.yaml`), which runs GoReleaser to build
cross-platform binaries and create a GitHub Release.

> [!WARNING]
> Do not create releases through the GitHub "Create a new release" UI.
> The UI creates a Release object itself, and GoReleaser will fail when it
> tries to create a second one for the same tag. Always push the tag via
> `git push` and let GoReleaser handle release creation.

## What GoReleaser produces

The release workflow publishes the following binaries:

- `plcc2fbc-linux-amd64`
- `plcc2fbc-linux-arm64`
- `plcc2fbc-darwin-arm64`

A `checksums.txt` file with SHA-256 hashes is included in the release assets.

## Version injection

The binary version is injected at build time via `-ldflags`:

```
-X main.version=<version> -X main.commit=<short-commit>
```

The Makefile uses a fallback chain to determine the version:

1. `git describe --tags --abbrev=0` (latest tag)
2. Contents of the `VERSION` file
3. `0.0.0` (hardcoded default)

GoReleaser uses the Git tag directly (`{{ .Version }}`), which is
consistent with the first step of the Makefile fallback chain.

## Verifying a release

After the workflow completes, check the
[Releases page](https://github.com/release-engineering/fbc-update-planner/releases) to confirm:

- The release was created with the correct tag
- All three platform binaries are attached
- The checksums file is present
- The changelog is populated
