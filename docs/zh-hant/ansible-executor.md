# SSH Ansible 執行器

[English](../ansible-executor.md) · [简体中文](../zh-hans/ansible-executor.md) · [繁體中文](ansible-executor.md)

安裝器部署 `jumpserver/ansible-executor:<版本或分支>`。標籤取自 `VERSION` 並移除結尾的 `-ce` / `-ee`（例如 `v5.1.0-ce` → `v5.1.0`，`dev-ce` → `dev`）。

Core/Celery 重用原有 `ANSIBLE_DOCKER_ENABLED` 開關：開啟時透過 SSH 使用常駐執行器，關閉時在本機執行。頁面已儲存的開關值繼續生效，安裝器不再強制指定執行後端；需搭配支援此行為的 Core 版本（見 [Core 適配 PR](https://github.com/jumpserver/jumpserver/pull/17797)）。

線上升級時重新拉取對應標籤。離線包依鏡像 ID 載入更新，執行時不存取鏡像倉庫。CE 和 EE 共用同一執行器標籤，離線包包含執行器。`ansible-executor:latest` 保留給舊版，新安裝器不會使用它。CI 從已驗證的 digest 打包鏡像，發版只映射版本標籤，不重新建置鏡像。自訂 `OFFLINE_IMAGE_SERVICES` 時應包含 `ansible-executor`。

執行器位址、連接埠和憑證路徑統一使用 Core 預設值。自訂值寫入安裝器設定檔，由現有 `env_file` 傳入 Core/Celery。Compose 僅分別指定兩者的網域通道位址。

## 金鑰與啟動

`./jmsctl.sh start` 使用執行器鏡像中的 `ssh-keygen` 初始化每套安裝獨立的金鑰，等待執行器健康後再啟動 Core/Celery。重啟、升級保留現有金鑰；金鑰損壞或只有公鑰而缺少私鑰時啟動失敗，不自動輪換身分。

請備份 `${CONFIG_DIR}/ansible-executor`：

- `client/`：服務私鑰和固定伺服器 host key 的 `known_hosts`，僅唯讀掛載給 Core/Celery。
- `public/`：服務公鑰，唯讀掛載給執行器。
- `server/`：執行器 SSH host key，持久化並僅掛載給執行器。

## 網路與隔離

執行器只接獨立的 `executor` bridge 網路，在內網監聽 2222，不發布主機連接埠，也不掛載 Core 資料或 Docker socket。Core/Celery 同時接入業務網 `net` 和執行網 `executor`，Redis、資料庫和其他元件只接業務網。

業務網保留原有 `DOCKER_SUBNET` 設定。執行網使用 `DOCKER_EXECUTOR_SUBNET`，預設 `192.168.252.0/24`，須避開業務、資產、VPN 和其他 Docker 網段。Docker 的 `bip` 只設定預設橋接網路，不控制執行網。既有執行網修改子網後，需先停止並移除連接它的容器，刪除舊執行網，再透過安裝器重新啟動；請先等待執行中的任務完成。

`USE_IPV6=1` 時兩個網路均啟用 IPv6，執行網 IPv6 位址由 Docker 自動分配。Core/Celery 的預設對外連線由 Docker 自動選擇，業務網和執行網均保留對外連線能力。自訂對外防火牆規則時，需允許實際使用的網路對外連線。

Core/Celery 不掛載 Docker socket。Celery 恢復 `CELERY_PRIVILEGED` 設定，預設 `true`，以便關閉 Ansible Docker 隔離時，一般 Playbook 仍能在 Celery 內透過 `bwrap` 建立隔離命名空間。Core 和 SSH 執行器不啟用 privileged。只使用 SSH 執行器的部署可設定 `CELERY_PRIVILEGED=false`；修改後需要重建 Celery 容器，單純重啟程序不會改變容器權限。privileged 會擴大 Celery 容器的主機權限，`bwrap` 隔離不能消除這項部署風險。

關閉 Ansible Docker 隔離不會停止常駐執行器，便於從頁面重新開啟；本機執行不享有執行器提供的任務 UID 和檔案隔離。`ANSIBLE_EXECUTOR_ENABLED=0` 僅控制是否部署本機執行器容器，與功能開關獨立。

預設整體資源上限為 4 GiB 記憶體、2 CPU、1024 PID，可透過設定範例中的選項調整。任務目錄使用 `exec,nosuid,nodev` tmpfs，以支援上傳的 SSH 包裝腳本。

## 位址與維運

資產位址須可從執行器存取，`127.0.0.1` 表示執行器自身。執行網保留存取外部資產的對外連線，不設為 `internal` 網路。一般自動化由 Celery 執行，但資產頁即時帳號發現和風險偵測由 Core 同步執行，因此兩者都需要連接執行器。

網域通道必須返回建立它的容器：Celery 預設使用 `celery`，Core 預設使用 `core`。多節點部署分別設定 `ANSIBLE_EXECUTOR_GATEWAY_HOST`（Celery）和 `ANSIBLE_EXECUTOR_CORE_GATEWAY_HOST`（Core），使執行器能存取實際執行節點及其動態通道連接埠。

使用外部執行器時設定 `ANSIBLE_EXECUTOR_ENABLED=0` 和實際 HOST/PORT，並自行在 `client/` 提供私鑰 `client` 及對應位址的可信 `known_hosts`。不得將服務私鑰放入任務目錄。任務仍透過不同 Linux UID 隔離，共用執行器核心和網路。

分網阻止預設 bridge 之間直接互通，不能取代對外防火牆；主機發布的連接埠、外部服務、Core/Celery 在執行網上監聽的服務仍可能可達，應保留驗證並依部署環境限制存取。
