# Docker 与 Compose 镜像同步

[English](../docker-mirror.md) · [简体中文](docker-mirror.md) · [繁體中文](../zh-hant/docker-mirror.md)

本页面向安装器仓库的维护者。

## 下载源

下载地址和 SHA-256 在 `scripts/const.sh` 中配置。设置 `DOCKER_IMAGE_MIRROR=1` 启用 `https://download.jumpserver.org` 加速，也可单独设置 `DOCKER_BIN_HOST`。

## OSS 同步

在仓库 Actions Secrets 中配置 `OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`。**Sync Docker Binaries to OSS** 会同步 `x86_64`、`aarch64` 两种架构，保留官方子路径：

```text
oss://jms-pkg/linux/static/stable/<arch>/docker-<version>.tgz
oss://jms-pkg/docker/compose/releases/download/<version>/docker-compose-linux-<arch>
```

版本配置变更时自动同步，也可手动 **Run workflow**，选择分支并填写 `docker_version`、`docker_compose_version`（可带 `v`），留空沿用当前版本。

新版本自动计算 SHA-256 和 MD5，原版本仍校验固定 SHA-256。OSS 上传成功后，将 `const.sh` 的版本和 SHA-256 提交到 `pr@所选分支@docker-versions-…` 分支，并创建以所选分支为目标的 PR。

参数全部留空或文件内容不变时只同步，不创建 PR。历史 OSS 文件保留。

创建 PR 使用 `PRIVATE_TOKEN`，未配置时使用 `GITHUB_TOKEN`，需有权推送新分支和创建 PR。自动提交通过 `[docker-mirror-synced]` 标记避免重复同步。
