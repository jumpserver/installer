# Docker 與 Compose 鏡像同步

[English](../docker-mirror.md) · [简体中文](../zh-hans/docker-mirror.md) · [繁體中文](docker-mirror.md)

本頁面對象為安裝器儲存庫的維護者。

## 下載來源

下載位址和 SHA-256 在 `scripts/const.sh` 中設定。設定 `DOCKER_IMAGE_MIRROR=1` 啟用 `https://download.jumpserver.org` 加速，也可單獨設定 `DOCKER_BIN_HOST`。

## OSS 同步

在儲存庫 Actions Secrets 中設定 `OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`。**Sync Docker Binaries to OSS** 會同步 `x86_64`、`aarch64` 兩種架構，保留官方子路徑：

```text
oss://jms-pkg/linux/static/stable/<arch>/docker-<version>.tgz
oss://jms-pkg/docker/compose/releases/download/<version>/docker-compose-linux-<arch>
```

版本設定變更時自動同步，也可手動 **Run workflow**，選擇分支並填寫 `docker_version`、`docker_compose_version`（可帶 `v`），留空沿用目前版本。

新版本自動計算 SHA-256 和 MD5，原版本仍驗證固定 SHA-256。OSS 上傳成功後，將 `const.sh` 的版本和 SHA-256 提交到 `pr@所選分支@docker-versions-…` 分支，並建立以所選分支為目標的 PR。

參數全部留空或檔案內容不變時只同步，不建立 PR。歷史 OSS 檔案保留。

建立 PR 使用 `PRIVATE_TOKEN`，未設定時使用 `GITHUB_TOKEN`，需有權推送新分支和建立 PR。自動提交透過 `[docker-mirror-synced]` 標記避免重複同步。
