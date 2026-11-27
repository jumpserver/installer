<div align="center">

# JumpServer Installer

使用 Docker Compose 部署與管理 [JumpServer](https://www.jumpserver.com/)。

[![Release](https://img.shields.io/github/v/release/jumpserver/installer?label=release)](https://github.com/jumpserver/installer/releases)
[![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](../LICENSE)
[![Docs](https://img.shields.io/badge/docs-jumpserver.com-2f6feb.svg)](https://www.jumpserver.com/docs)
[![Quality](https://github.com/jumpserver/installer/actions/workflows/quality.yml/badge.svg)](https://github.com/jumpserver/installer/actions/workflows/quality.yml)

[English](../README.md) · [简体中文](README.zh-hans.md) · [繁體中文](README.zh-hant.md)

</div>

## 概覽

JumpServer 是開源的堡壘機與特權存取管理（PAM）平台，為 SSH、RDP、Kubernetes、資料庫、Web 站點、RemoteApp 和 VirtualApp 等資產提供帶稽核的、基於角色的存取控制。

本儲存庫是 JumpServer 官方安裝器。它負責準備主機環境、在需要時安裝 Docker 與 Docker Compose、產生 Compose 編排、載入鏡像、遷移資料庫結構，並透過 `jmsctl.sh` 管理部署的日常維運。

- 應用程式原始碼：[jumpserver/jumpserver](https://github.com/jumpserver/jumpserver)
- 官方文件：[jumpserver.com/docs](https://www.jumpserver.com/docs)
- 設定參數說明：[環境變數](https://docs.jumpserver.org/zh/v3/guide/env/)

## 目錄

- [環境要求](#環境要求)
- [快速開始](#快速開始)
- [連接埠](#連接埠)
- [管理命令](#管理命令)
- [設定](#設定)
- [升級](#升級)
- [離線安裝](#離線安裝)
- [企業版 JDMC](#企業版-jdmc)
- [SSH Ansible 執行器](#ssh-ansible-執行器)
- [儲存庫結構](#儲存庫結構)
- [開發](#開發)
- [社群](#社群)
- [授權條款](#授權條款)

## 環境要求

| 項目 | 要求 |
| --- | --- |
| 作業系統 | 使用 systemd 的 Linux |
| 架構 | `x86_64` 或 `aarch64` |
| 核心 | 4.0 及以上 |
| 權限 | `root` 或具有 `sudo` 權限的使用者 |
| 資源 | 小型生產部署建議從 4 vCPU、8 GiB 記憶體、100 GiB 磁碟起步 |
| 網路 | 可存取鏡像倉庫，或準備離線鏡像包 |
| 時間 | 建議啟用 NTP 時間同步 |

`./jmsctl.sh install` 會在缺少時安裝 Docker 29.10.1 和 Docker Compose v2.40.3。如果主機無法使用 systemd，請先自行安裝 Docker 與 Compose 外掛，並在執行安裝器時設定 `UNCHECK_DEPENDENCIES=1`。

## 快速開始

### 從 Release 壓縮包安裝（建議）

```bash
# 將 vX.Y.Z 替換為 https://github.com/jumpserver/installer/releases 中的最新版本
VERSION=vX.Y.Z
curl -fLO "https://github.com/jumpserver/installer/releases/download/${VERSION}/jumpserver-installer-${VERSION}.tar.gz"
curl -fLO "https://github.com/jumpserver/installer/releases/download/${VERSION}/jumpserver-installer-${VERSION}.tar.gz.sha256"
sha256sum -c "jumpserver-installer-${VERSION}.tar.gz.sha256"
tar -xzf "jumpserver-installer-${VERSION}.tar.gz"
cd "jumpserver-installer-${VERSION}"

sudo ./jmsctl.sh install
sudo ./jmsctl.sh start
```

`install` 會完成首次安裝：

1. 在缺少時安裝並設定 Docker 和 Docker Compose。
2. 收集設定並寫入 `/opt/jumpserver/config/config.txt`。
3. 載入鏡像，初始化或遷移資料庫結構。
4. 在企業版中安裝 JDMC。

`start` 完成後開啟 `http://<主機位址>/`，設定了 TLS 時開啟 HTTPS 位址。預設使用者名稱為 `admin`，初始密碼會在安裝結束時輸出，請在首次登入後立即變更。

### 從原始碼安裝

```bash
git clone https://github.com/jumpserver/installer.git
cd installer
git checkout <tag>

sudo ./jmsctl.sh install
sudo ./jmsctl.sh start
```

> [!NOTE]
> 離線主機請先依[離線安裝](#離線安裝)準備鏡像包，再執行 `install`。

## 連接埠

| 連接埠 | 預設用途 | 服務 | 說明 |
| --- | --- | --- | --- |
| `80` | HTTP | Web 控制台和 API | 設定 `HTTP_PORT=0` 可關閉 |
| `443` | HTTPS | Web 控制台和 API | 設定 `HTTPS_PORT` 和憑證後使用 |
| `2222` | TCP | KoKo SSH | 連線資產的 SSH 與 SFTP 工作階段 |
| `5001` | TCP | KoKo Web 代理 | 會發布到主機，可透過 `WEB_PROXY_ALLOWED_HOSTS` 限制來源 |
| `3389` | TCP | Razor RDP | 企業版 |
| `3390` | TCP | XRDP | 企業版，預設關閉 |
| `5525` | TCP | Magnus | 企業版資料庫代理 |
| `15900` | TCP | NEC | 企業版 VNC |

Docker 網路 `DOCKER_SUBNET`（預設 `192.168.250.0/24`）和 `DOCKER_EXECUTOR_SUBNET`（預設 `192.168.252.0/24`）不能與主機、資產、VPN 或其他 Docker 網段衝突。

## 管理命令

在安裝器目錄中執行 `sudo ./jmsctl.sh <命令>`。單獨管理 JDMC 可使用 `start jdmc`、`stop jdmc`、`restart jdmc`、`status jdmc` 或 `tail jdmc`。

| 命令 | 說明 |
| --- | --- |
| `install` | 首次安裝：設定 Docker、寫入設定、載入鏡像、初始化資料庫；企業版還會安裝 JDMC |
| `upgrade [版本]` | 升級到指定版本，或升級到安裝器內建的版本 |
| `check_update` | 檢查是否有新版本 |
| `config [ntp\|init\|port\|ssl\|env]` | 調整 NTP、設定、服務連接埠、TLS 或環境設定 |
| `start` | 啟動所有已啟用的服務 |
| `stop [服務]` | 停止並移除容器，`VOLUME_DIR` 中的資料會保留 |
| `restart [服務]` | 重啟全部服務或單一服務 |
| `status` | 查看容器狀態；企業版同時顯示 JDMC 狀態 |
| `close [服務]` | 停止應用程式容器，但保留資料庫容器執行 |
| `down [服務]` | 停止並移除全部容器，或移除單一服務 |
| `prepare [服務 ...]` | 只準備目錄、權限和金鑰，不啟動服務 |
| `prepare --containers <容器名稱 ...>` | 使用已安裝的鏡像準備已停止的容器 |
| `load_image` | 從離線鏡像目錄載入鏡像 |
| `backup_db` | 備份資料庫 |
| `backup_no_audit` | 備份資料庫但不包含稽核表 |
| `backup_audit` | 僅備份稽核表 |
| `restore_db [檔案]` | 從備份檔案還原資料庫 |
| `tail [服務]` | 查看全部服務或單一服務的日誌 |
| `raw <compose 參數...>` | 直接執行安裝器產生的 `docker compose` 命令 |
| `video-worker <start\|stop\|restart\|status>` | 管理企業版 video-worker |
| `uninstall` | 移除容器和網路，並可選清理檔案、鏡像和 Docker 程式；破壞性步驟會先確認 |
| `version` | 顯示目前安裝版本 |

執行 `./jmsctl.sh --help` 可查看完整命令摘要。

## 設定

安裝完成後，設定位於 `/opt/jumpserver/config`：

```text
/opt/jumpserver/config/
├── config.txt          # 主設定，會掛載到各個容器
├── nginx/
│   ├── cert/
│   │   ├── server.crt
│   │   └── server.key
│   ├── lb_http_server.conf
│   └── lb_ssh_server.conf
├── mysql/
│   └── my.cnf
├── mariadb/
│   └── mariadb.cnf
└── redis/
    └── redis.conf
```

`config.txt` 是所有容器共用的環境變數檔案，因此 KoKo、Core 等元件不需要個別的設定檔。安裝器還會產生受限的 `config_safe.txt`，只向需要的元件傳遞設定值。帶註解的完整範例見 `config-example.txt`。

### 常用設定項

| 設定項 | 預設值 | 作用 |
| --- | --- | --- |
| `VOLUME_DIR` | `/data/jumpserver` | 持久化資料、錄影、任務日誌和備份 |
| `SECRET_KEY`、`BOOTSTRAP_TOKEN` | 自動產生 | 遷移環境時必須保留的金鑰 |
| `HTTP_PORT`、`HTTPS_PORT` | `80`、`443` | Web 連接埠，設為 `0` 可關閉 |
| `SERVER_NAME`、`SSL_CERTIFICATE`、`SSL_CERTIFICATE_KEY` | 空 | 啟用 HTTPS |
| `DB_ENGINE` | `postgresql` | 內建資料庫類型 |
| `DB_HOST` | `postgresql` | 內建資料庫使用 `postgresql` 或 `mysql`，也可填寫外置資料庫位址 |
| `DB_IMAGE` | 隨版本而定 | 覆寫內建資料庫鏡像，例如 `mysql:8.0` |
| `REDIS_HOST`、`REDIS_PORT`、`REDIS_PASSWORD` | `redis`、`6379` | 內建 Redis 連線 |
| `DOCKER_SUBNET`、`DOCKER_EXECUTOR_SUBNET` | `192.168.250.0/24`、`192.168.252.0/24` | 容器網段 |
| `TZ` | `Asia/Shanghai` | 容器時區 |
| `IMAGE_PULL_PREFIX`、`NAMESPACE`、`IMAGE_PULL_SCOPE`、`IMAGE_PULL_POLICY` | 空、`jumpserver`、`jumpserver`、`Always` | 鏡像來源與本機命名 |
| `USE_XPACK` | `0` | 部署 JDMC 等企業版元件 |
| `KOKO_SSH_PORT`、`RAZOR_RDP_PORT`、`MAGNUS_PORT`、`NEC_VNC_PORT` | `2222`、`3389`、`5525`、`15900` | 元件連接埠 |
| `ANSIBLE_EXECUTOR_*`、`CELERY_PRIVILEGED` | 內建預設值 | 執行器部署與 Celery 隔離 |
| `*_ENABLED` | `1` | 設為 `0` 可關閉對應服務 |

### 內建資料庫

新安裝預設使用 PostgreSQL 18.7。如需使用內建 MySQL 8.0，請設定 `DB_ENGINE=mysql`、`DB_HOST=mysql` 和 `DB_IMAGE=mysql:8.0`；互動式安裝也會詢問內建資料庫鏡像。未設定 `DB_IMAGE` 時，新安裝使用 MariaDB 10.6。

既有的 `VOLUME_DIR/mysql/data` 或 `VOLUME_DIR/mariadb/data` 決定繼續使用原資料庫。修改 `DB_IMAGE` 不會遷移既有資料。離線安裝需要自行提供所選資料庫鏡像。

## 升級

```bash
sudo ./jmsctl.sh upgrade
```

線上升級會拉取所需鏡像，離線升級會從本機鏡像包載入。升級前請備份環境，並保留 `VOLUME_DIR`、`SECRET_KEY` 和 `BOOTSTRAP_TOKEN`。

自 v5.3.0 起，KoKo 統一提供 Chen、Kael 和 Lion 的功能。升級前請結束進行中的 Chen 工作階段，等舊服務上傳完待傳的稽核紀錄與錄影。透過 jmsctl 啟動或重新啟動 KoKo 時，會先停止舊的獨立容器並關閉其自動重啟。執行 `jmsctl stop` 或 `jmsctl stop koko` 時，會在讀取 Compose 設定前直接透過 Docker 停用這些舊容器。即使 Compose 無法使用，也可以按名稱個別停用，例如 `jmsctl stop chen`。執行升級時，這一步會在資料庫遷移前完成。升級成功後會刪除這些容器，保留掛載的資料。KoKo 直接沿用 `${VOLUME_DIR}/kael/data`，預設將新的 Chen 狀態寫入 `${VOLUME_DIR}/koko/data/chen`。舊 Chen 資料目錄會保留。原先獨立部署 Chen、Kael 或 Lion 的節點，如需在本機繼續提供這些功能，請啟用 KoKo。新版工作台隨 `KOKO_ENABLED` 啟停，舊設定 `CHEN_ENABLED=0` 只適用於獨立服務。

企業版的 Razor 映像檔同時提供 RDP、Magnus 資料庫代理和 NEC VNC 服務。先前僅部署 Magnus 或 NEC 的節點需要啟用 Razor。`RAZOR_ENABLED` 統一控制容器及三個監聽連接埠。升級沿用原有連接埠、資料目錄及憑證，並清理舊的獨立容器。

### 升級時的資料庫備份

使用外置 MySQL 或 PostgreSQL 且未啟用 `HA_MODE=1` 時，備份客戶端鏡像缺少、載入或拉取失敗只會輸出警告，升級會繼續到備份步驟。本機沒有可用的客戶端鏡像時跳過備份；鏡像可用時正常嘗試備份。內建資料庫和應用程式必需鏡像仍必須準備成功。

所有資料庫備份都失敗時，安裝器會提示：

```text
Failed to backup the database. Continue to upgrade? [Y/n] (Timeout: 30s, default: y):
```

輸入 `y`（不分大小寫）或直接按 Enter 繼續，輸入 `n` 中止。30 秒沒有輸入時提示逾時並繼續。其他輸入或輸入流關閉會中止升級。逾時僅用於此備份失敗確認，其他確認保持原有行為；`AUTO_INSTALL=1` 依既有自動安裝規則採用預設值 `y`。

繼續升級表示接受本次安裝器沒有成功備份資料庫，請確保 DBA 或雲端資料庫提供了可還原的備份。

如已自行完成備份，也可以明確跳過備份及備份客戶端鏡像準備：

```bash
SKIP_BACKUP_DB=1 ./jmsctl.sh upgrade
```

資料表結構遷移仍由 Core 連線資料庫執行。單獨執行 `backup_db` 失敗仍傳回非零狀態，不會觸發升級確認。此流程不改變備份客戶端版本，PostgreSQL 客戶端與伺服器版本不相容時仍可能備份失敗。`SKIP_BACKUP_DB` 透過命令環境傳入，不是 `config.txt` 設定項。

內建 PostgreSQL 10 到 17 會在同一次維護中遷移到 PostgreSQL 18。遷移流程、空間需求、自訂設定和 JDMC 主備協調見 [PostgreSQL 18 遷移](../docs/zh-hant/postgresql-18-upgrade.md)。

安裝或升級不再建立 `/opt/jumpserver/data` 到主機資料目錄的符號連結；既有連結、目錄和備份保持原狀。設定檔、歷史資料遷移及目前安裝器路徑使用的其他符號連結會保留。

## 離線安裝

離線安裝從 `scripts/images/` 載入鏡像，而不是從鏡像倉庫拉取。該目錄中的每個鏡像都需要一個 `.zst` 封存檔和一個記錄鏡像 ID 的 `.sha256` 檔案。

```bash
# 將離線鏡像包複製到安裝器目錄後執行
sudo ./jmsctl.sh install
sudo ./jmsctl.sh load_image
```

`install` 和 `upgrade` 會自動辨識鏡像包，`load_image` 可明確載入。檔案配置、鏡像清單與倉庫前綴設定見[離線安裝](../docs/zh-hant/offline-installation.md)。

## 企業版 JDMC

設定 `USE_XPACK=1` 的企業版節點透過獨立的 Compose 專案執行 JDMC。社群版略過 JDMC。連線方式、資料目錄及主機版遷移步驟見[企業版 JDMC](../docs/zh-hant/jdmc.md)。

## SSH Ansible 執行器

安裝器會為 CE 和 EE 部署 `jumpserver/ansible-executor`。Core 和 Celery 重用 `ANSIBLE_DOCKER_ENABLED` 開關：開啟時透過 SSH 使用常駐執行器，關閉時在本機執行。

執行器在獨立的 `executor` 網路中監聽 2222，不發布主機連接埠，也不掛載 Core 資料或 Docker socket。首次啟動會為每套安裝產生金鑰，重啟和升級會保留金鑰；請備份 `${CONFIG_DIR}/ansible-executor`。

網路、隔離、資源限制、外部執行器和 `CELERY_PRIVILEGED` 的取捨見 [SSH Ansible 執行器](../docs/zh-hant/ansible-executor.md)。

## 儲存庫結構

| 路徑 | 內容 |
| --- | --- |
| `jmsctl.sh` | 命令列入口 |
| `scripts/` | 按步驟拆分的安裝、升級、備份、解除安裝腳本與共用函式 |
| `scripts/gists/` | 鏡像、服務、資料庫和 PostgreSQL 遷移輔助模組 |
| `compose/` | 按服務拆分的 Docker Compose 片段 |
| `config-example.txt` | 帶註解的設定參考 |
| `config_init/` | MySQL、MariaDB、Redis、OpenBao、Loki 和執行器的初始設定範本 |
| `locale/` | `en`、`zh_CN` 和 `zh_Hant` 命令列翻譯 |
| `tests/` | Bash 回歸測試 |
| `docs/` | 英文、簡體中文和繁體中文的專題文件 |
| `.github/workflows/` | 品質檢查、OSS 鏡像同步和 Release 草稿 |

## 開發

提交變更前請執行 Shell 語法檢查和回歸測試：

```bash
find . -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do
  bash -n "${file}"
done

bash tests/run.sh
```

Docker 與 Compose 二進位鏡像的維護說明見 [Docker 與 Compose 鏡像同步](../docs/zh-hant/docker-mirror.md)。

## 社群

- 文件：<https://www.jumpserver.com/docs>
- Releases：<https://github.com/jumpserver/installer/releases>
- Issues：<https://github.com/jumpserver/jumpserver/issues>
- Discord：<https://discord.gg/jumpserver>

## 許可證

Copyright (c) 2014-2026 FIT2CLOUD, All rights reserved.

本項目基於 GNU General Public License version 3（GPLv3）許可，與 [JumpServer 主倉庫](https://github.com/jumpserver/jumpserver)一致。完整許可文本請參閱 [LICENSE](../LICENSE)。
