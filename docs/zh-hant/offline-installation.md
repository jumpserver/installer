# 離線安裝

[English](../offline-installation.md) · [简体中文](../zh-hans/offline-installation.md) · [繁體中文](offline-installation.md)

離線安裝使用預先匯出的鏡像，而不是從鏡像倉庫拉取。

## 鏡像包配置

將匯出的鏡像及其鏡像 ID 驗證檔案放入 `scripts/images/`。該目錄至少包含一個 `.zst` 檔案時，`install` 和 `upgrade` 會從中載入鏡像；否則安裝器從鏡像倉庫拉取。`./jmsctl.sh load_image` 可明確載入該目錄。

每個鏡像需要兩個檔案：

```text
scripts/images/
├── core_dev-ce.zst          # docker 鏡像封存檔
└── core:dev-ce.sha256       # 預期的鏡像 ID，用於跳過或驗證載入
```

封存檔名稱為鏡像最後一段路徑加 `.zst`。載入器接受原始形式（`core:dev-ce.zst`）或常見的將 `:` 替換為 `_` 的形式（`core_dev-ce.zst`）。驗證檔案保留原始 basename 並包含鏡像 ID。本機已存在相同 ID 的鏡像會跳過。

離線包還必須提供所選資料庫鏡像。

## 鏡像選擇清單

`scripts/gists/image.sh` 是離線鏡像選擇和重新標記規則的唯一來源。`get_offline_image_manifest` 會逐行輸出以 Tab 分隔的來源鏡像和離線包目標鏡像：

```text
redis:8.10.3-trixie	redis:8.10.3-trixie
registry.example.com/jumpserver/core:VERSION	jumpserver/core:VERSION
```

安裝器的鏡像拉取流程和外部 CI 打包流程都應消費該清單，不應分別維護 Redis、PostgreSQL、Ansible Executor、OpenBao 或 JDMC 的鏡像清單。

CI 可以透過 `OFFLINE_IMAGE_SERVICES` 傳入逗號或空格分隔的服務範圍；未設定時，清單使用安裝器目前設定所啟用的服務。自訂清單在部署執行器時必須包含 `ansible-executor`。

## 鏡像來源

`IMAGE_PULL_PREFIX` 只決定 JumpServer 自有鏡像的拉取來源。`NAMESPACE` 只決定這些鏡像拉取後的本機執行名稱。

Redis、資料庫和 OpenBao 等基礎鏡像保留自己的 registry 和 namespace，不使用 `NAMESPACE`；OpenBao 固定使用 `openbao/openbao:2.6.0`。

`IMAGE_PULL_SCOPE` 預設為 `jumpserver`。設定為 `all` 時，基礎鏡像也從 `IMAGE_PULL_PREFIX` 拉取，但拉取後仍恢復成各自的固定執行名稱。

`DOCKER_IMAGE_MIRROR=1` 是啟用 `https://download.jumpserver.org` 鏡像的舊選項。設定 `IMAGE_PULL_PREFIX` 時優先使用它。
