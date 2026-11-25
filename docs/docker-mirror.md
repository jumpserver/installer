# Docker and Compose mirror synchronization

[English](docker-mirror.md) · [简体中文](zh-hans/docker-mirror.md) · [繁體中文](zh-hant/docker-mirror.md)

This page is for maintainers of the installer repository.

## Download sources

Download URLs and SHA-256 checksums are configured in `scripts/const.sh`. Set `DOCKER_IMAGE_MIRROR=1` to use the `https://download.jumpserver.org` mirror, or set `DOCKER_BIN_HOST` separately.

## OSS synchronization

Configure `OSS_ACCESS_KEY_ID` and `OSS_ACCESS_KEY_SECRET` in the repository's Actions secrets. The **Sync Docker Binaries to OSS** workflow synchronizes both `x86_64` and `aarch64` while preserving the official subpaths:

```text
oss://jms-pkg/linux/static/stable/<arch>/docker-<version>.tgz
oss://jms-pkg/docker/compose/releases/download/<version>/docker-compose-linux-<arch>
```

Synchronization runs automatically when the version configuration changes. It can also be started manually with **Run workflow**, selecting a branch and providing `docker_version` and `docker_compose_version` (with or without a leading `v`). Empty values keep the current versions.

New versions get SHA-256 and MD5 checksums computed automatically; existing versions continue to verify against their pinned SHA-256. After a successful OSS upload, the workflow commits the version and SHA-256 changes in `const.sh` to a `pr@<selected-branch>@docker-versions-…` branch and opens a pull request targeting the selected branch.

When every parameter is empty or the file content is unchanged, the workflow only synchronizes and does not create a pull request. Historical OSS files are retained.

Pull request creation uses `PRIVATE_TOKEN`, falling back to `GITHUB_TOKEN`. The token needs permission to push the new branch and create pull requests. The automatic commit uses the `[docker-mirror-synced]` marker to avoid repeated synchronization.
